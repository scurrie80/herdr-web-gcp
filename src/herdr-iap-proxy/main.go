// herdr-iap-proxy: a stateless reverse proxy for herdr-web-ui.
//
// It runs on Cloud Run behind Google IAP, joins your tailnet as an ephemeral
// tagged node with tsnet, and forwards every request (including the terminal
// WebSockets) to the Tailscale Serve endpoint that fronts herdr-web-ui on the
// dev box. Nothing is stored: the herdr session lives on the dev box, the
// tsnet state lives in /tmp.
//
// Configuration is entirely from the environment; see loadConfig.
package main

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"net"
	"net/http"
	"net/http/httputil"
	"net/url"
	"os"
	"os/signal"
	"strconv"
	"strings"
	"sync/atomic"
	"syscall"
	"time"

	"google.golang.org/api/idtoken"
	"tailscale.com/client/local"
	"tailscale.com/tsnet"
	"tailscale.com/types/logger"
)

const (
	iapIssuer    = "https://cloud.google.com/iap"
	iapJWTHeader = "X-Goog-Iap-Jwt-Assertion"
)

type config struct {
	authKey       string   // TS_AUTHKEY: Tailscale OAuth client secret (tskey-client-...)
	upstream      *url.URL // UPSTREAM: https://<devbox>.<tailnet>.ts.net
	dialAddr      string   // UPSTREAM_DIAL_ADDR: optional host:port to dial instead of upstream's
	port          string   // PORT: set by Cloud Run
	hostname      string   // TS_HOSTNAME: tailnet hostname of this node
	tags          []string // TS_TAGS: tags to advertise (must match the OAuth client's tags)
	iapAudience   string   // IAP_AUDIENCE: enables JWT verification when set
	allowedEmails []string // IAP_ALLOWED_EMAILS: optional, pins the verified email claim
	rewriteOrigin bool     // REWRITE_ORIGIN: rewrite the Origin header to the upstream host
	debug         bool     // TS_DEBUG: verbose tsnet logs
	upTimeout     time.Duration
}

func loadConfig() (*config, error) {
	c := &config{
		authKey:   os.Getenv("TS_AUTHKEY"),
		dialAddr:  os.Getenv("UPSTREAM_DIAL_ADDR"),
		port:      envOr("PORT", "8080"),
		hostname:  envOr("TS_HOSTNAME", "herdr-proxy"),
		upTimeout: 60 * time.Second,
	}
	if c.authKey == "" {
		return nil, errors.New("TS_AUTHKEY is required")
	}
	raw := os.Getenv("UPSTREAM")
	if raw == "" {
		return nil, errors.New("UPSTREAM is required (e.g. https://devbox.example.ts.net)")
	}
	u, err := url.Parse(raw)
	if err != nil || u.Host == "" || (u.Scheme != "http" && u.Scheme != "https") {
		return nil, fmt.Errorf("UPSTREAM must be an http(s) URL with a host, got %q", raw)
	}
	c.upstream = u
	c.tags = splitList(envOr("TS_TAGS", "tag:herdr-proxy"))
	c.iapAudience = os.Getenv("IAP_AUDIENCE")
	c.allowedEmails = splitList(os.Getenv("IAP_ALLOWED_EMAILS"))
	c.rewriteOrigin = envBool("REWRITE_ORIGIN", true)
	c.debug = envBool("TS_DEBUG", false)
	if v := os.Getenv("TS_UP_TIMEOUT"); v != "" {
		d, err := time.ParseDuration(v)
		if err != nil {
			return nil, fmt.Errorf("TS_UP_TIMEOUT: %w", err)
		}
		c.upTimeout = d
	}
	return c, nil
}

func envOr(k, def string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return def
}

func envBool(k string, def bool) bool {
	v := os.Getenv(k)
	if v == "" {
		return def
	}
	b, err := strconv.ParseBool(v)
	if err != nil {
		return def
	}
	return b
}

func splitList(s string) []string {
	var out []string
	for _, p := range strings.Split(s, ",") {
		if p = strings.TrimSpace(p); p != "" {
			out = append(out, p)
		}
	}
	return out
}

// newLogger emits JSON lines that Cloud Logging parses natively: "severity"
// instead of "level" and "message" instead of "msg".
func newLogger() *slog.Logger {
	h := slog.NewJSONHandler(os.Stdout, &slog.HandlerOptions{
		ReplaceAttr: func(_ []string, a slog.Attr) slog.Attr {
			switch a.Key {
			case slog.LevelKey:
				lvl := a.Value.Any().(slog.Level)
				sev := lvl.String()
				if lvl == slog.LevelWarn {
					sev = "WARNING"
				}
				return slog.String("severity", sev)
			case slog.MessageKey:
				a.Key = "message"
			case slog.TimeKey:
				a.Key = "time"
			}
			return a
		},
	})
	return slog.New(h)
}

// health reports whether the tsnet backend is Running. Cloud Run's startup
// probe gates traffic on it; the liveness probe restarts the container (and
// so registers a fresh ephemeral node) if the backend ever leaves Running.
type health struct {
	ready atomic.Bool
	lc    atomic.Pointer[local.Client]
}

func (h *health) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Cache-Control", "no-store")
	if !h.ready.Load() {
		http.Error(w, "tailnet not up", http.StatusServiceUnavailable)
		return
	}
	lc := h.lc.Load()
	if lc == nil {
		http.Error(w, "tailnet not up", http.StatusServiceUnavailable)
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), 3*time.Second)
	defer cancel()
	st, err := lc.Status(ctx)
	if err != nil || st == nil || st.BackendState != "Running" {
		state := "unknown"
		if st != nil {
			state = st.BackendState
		}
		http.Error(w, "tailnet backend "+state, http.StatusServiceUnavailable)
		return
	}
	w.WriteHeader(http.StatusOK)
	_, _ = w.Write([]byte("ok\n"))
}

// stripPrefixes lists inbound header prefixes that must never reach the
// upstream: IAP's own headers (the JWT, the unsigned identity headers),
// Cloud Run's service-to-service auth, Tailscale identity headers (Serve sets
// its own; a client must not be able to spoof the owner login) and any
// forwarding headers (Serve supplies X-Forwarded-For/Proto itself).
var stripPrefixes = []string{"x-goog-", "x-serverless-", "tailscale-", "x-forwarded-"}

var stripExact = map[string]bool{"forwarded": true, "authorization": true}

type inboundHostKey struct{}

// newProxy builds the reverse proxy. dial is injected so tests can bypass tsnet.
func newProxy(cfg *config, dial func(ctx context.Context, network, addr string) (net.Conn, error), log *slog.Logger) *httputil.ReverseProxy {
	upstream := cfg.upstream
	transport := &http.Transport{
		DialContext: func(ctx context.Context, network, addr string) (net.Conn, error) {
			if cfg.dialAddr != "" {
				addr = cfg.dialAddr // SNI still comes from URL.Host
			}
			return dial(ctx, network, addr)
		},
		// Custom DialContext keeps the transport on HTTP/1.1, which the
		// WebSocket 101 upgrade path needs. Do not set ForceAttemptHTTP2.
		TLSHandshakeTimeout:   10 * time.Second,
		ResponseHeaderTimeout: 30 * time.Second,
		IdleConnTimeout:       90 * time.Second,
		MaxIdleConns:          16,
	}
	originValue := upstream.Scheme + "://" + upstream.Host

	return &httputil.ReverseProxy{
		Transport:     transport,
		FlushInterval: -1, // terminal output must not be buffered
		Rewrite: func(r *httputil.ProxyRequest) {
			r.SetURL(upstream) // sets URL.Scheme/Host and the Host header
			r.Out = r.Out.WithContext(context.WithValue(r.Out.Context(), inboundHostKey{}, r.In.Host))
			h := r.Out.Header
			for k := range h {
				kl := strings.ToLower(k)
				if stripExact[kl] {
					h.Del(k)
					continue
				}
				for _, p := range stripPrefixes {
					if strings.HasPrefix(kl, p) {
						h.Del(k)
						break
					}
				}
			}
			if cfg.rewriteOrigin && h.Get("Origin") != "" {
				h.Set("Origin", originValue)
			}
		},
		ModifyResponse: func(resp *http.Response) error {
			// Absolute redirects to the upstream name would leave the proxy;
			// point them back at the host the browser used.
			loc := resp.Header.Get("Location")
			if loc == "" {
				return nil
			}
			lu, err := url.Parse(loc)
			if err != nil || !strings.EqualFold(lu.Host, upstream.Host) {
				return nil
			}
			if in, ok := resp.Request.Context().Value(inboundHostKey{}).(string); ok && in != "" {
				lu.Scheme = "https"
				lu.Host = in
				resp.Header.Set("Location", lu.String())
			}
			return nil
		},
		ErrorHandler: func(w http.ResponseWriter, r *http.Request, err error) {
			log.Error("upstream error", "path", r.URL.Path, "err", err.Error())
			http.Error(w, "upstream unavailable", http.StatusBadGateway)
		},
	}
}

// iapGuard verifies the IAP-signed JWT on every request. IAP sits in front of
// the service, so this is defence in depth against anything that reaches the
// container without passing through IAP.
func iapGuard(audience string, allowedEmails []string, log *slog.Logger, next http.Handler) http.Handler {
	allowed := map[string]bool{}
	for _, e := range allowedEmails {
		allowed[strings.ToLower(e)] = true
	}
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		token := r.Header.Get(iapJWTHeader)
		if token == "" {
			http.Error(w, "missing IAP assertion", http.StatusUnauthorized)
			return
		}
		ctx, cancel := context.WithTimeout(r.Context(), 10*time.Second)
		defer cancel()
		payload, err := idtoken.Validate(ctx, token, audience)
		if err != nil {
			log.Warn("iap jwt rejected", "reason", "invalid")
			http.Error(w, "invalid IAP assertion", http.StatusUnauthorized)
			return
		}
		if payload.Issuer != iapIssuer {
			log.Warn("iap jwt rejected", "reason", "issuer")
			http.Error(w, "invalid IAP assertion", http.StatusUnauthorized)
			return
		}
		email, _ := payload.Claims["email"].(string)
		if len(allowed) > 0 && !allowed[strings.ToLower(email)] {
			log.Warn("iap jwt rejected", "reason", "email not allowed")
			http.Error(w, "forbidden", http.StatusForbidden)
			return
		}
		next.ServeHTTP(w, r)
	})
}

// statusWriter records the status code while staying hijackable/flushable
// (ReverseProxy uses http.ResponseController, which unwraps).
type statusWriter struct {
	http.ResponseWriter
	status int
}

func (s *statusWriter) WriteHeader(code int) {
	if s.status == 0 {
		s.status = code
	}
	s.ResponseWriter.WriteHeader(code)
}

func (s *statusWriter) Write(b []byte) (int, error) {
	if s.status == 0 {
		s.status = http.StatusOK
	}
	return s.ResponseWriter.Write(b)
}

func (s *statusWriter) Flush() {
	if f, ok := s.ResponseWriter.(http.Flusher); ok {
		f.Flush()
	}
}

func (s *statusWriter) Unwrap() http.ResponseWriter { return s.ResponseWriter }

func requestLog(log *slog.Logger, next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		sw := &statusWriter{ResponseWriter: w}
		next.ServeHTTP(sw, r)
		status := sw.status
		if status == 0 {
			status = http.StatusOK
		}
		log.Info("request",
			"method", r.Method,
			"path", r.URL.Path,
			"status", status,
			"duration_ms", time.Since(start).Milliseconds(),
			"upgrade", strings.EqualFold(r.Header.Get("Upgrade"), "websocket"),
		)
	})
}

func newHandler(cfg *config, h *health, proxy http.Handler, log *slog.Logger) http.Handler {
	app := proxy
	if cfg.iapAudience != "" {
		app = iapGuard(cfg.iapAudience, cfg.allowedEmails, log, app)
	}
	mux := http.NewServeMux()
	mux.Handle("/healthz", h) // never proxied, never behind the JWT check
	mux.Handle("/", requestLog(log, app))
	return mux
}

func main() {
	log := newLogger()
	cfg, err := loadConfig()
	if err != nil {
		log.Error("config", "err", err.Error())
		os.Exit(2)
	}

	ts := &tsnet.Server{
		Dir:           "/tmp/tsnet",
		Hostname:      cfg.hostname,
		Ephemeral:     true,
		AuthKey:       cfg.authKey + "?ephemeral=true&preauthorized=true",
		AdvertiseTags: cfg.tags,
		Logf:          logger.Discard,
		UserLogf: func(format string, args ...any) {
			log.Info(fmt.Sprintf(format, args...), "component", "tsnet")
		},
	}
	if cfg.debug {
		ts.Logf = func(format string, args ...any) {
			log.Debug(fmt.Sprintf(format, args...), "component", "tsnet")
		}
	}

	h := &health{}
	proxy := newProxy(cfg, ts.Dial, log)
	srv := &http.Server{
		Addr:              ":" + cfg.port,
		Handler:           newHandler(cfg, h, proxy, log),
		ReadHeaderTimeout: 15 * time.Second,
		// No WriteTimeout/IdleTimeout: hijacked WebSocket connections live
		// for up to Cloud Run's request timeout (60 min).
	}

	// Listen first so Cloud Run's startup probe can poll /healthz (503 until
	// the tailnet is up), then bring the node up in the background.
	ln, err := net.Listen("tcp", srv.Addr)
	if err != nil {
		log.Error("listen", "err", err.Error())
		os.Exit(1)
	}
	go func() {
		if err := srv.Serve(ln); err != nil && !errors.Is(err, http.ErrServerClosed) {
			log.Error("serve", "err", err.Error())
			os.Exit(1)
		}
	}()

	go func() {
		ctx, cancel := context.WithTimeout(context.Background(), cfg.upTimeout)
		defer cancel()
		started := time.Now()
		st, err := ts.Up(ctx)
		if err != nil {
			// Bad key, tag not in tagOwners, control unreachable: make it a
			// visible crash so Cloud Run restarts us and the log says why.
			log.Error("tsnet up failed", "err", err.Error(), "after_ms", time.Since(started).Milliseconds())
			_ = ts.Close()
			os.Exit(1)
		}
		lc, err := ts.LocalClient()
		if err != nil {
			log.Error("tsnet local client", "err", err.Error())
			os.Exit(1)
		}
		h.lc.Store(lc)
		h.ready.Store(true)
		ips := make([]string, 0, len(st.TailscaleIPs))
		for _, ip := range st.TailscaleIPs {
			ips = append(ips, ip.String())
		}
		log.Info("tailnet up",
			"hostname", cfg.hostname,
			"ips", strings.Join(ips, ","),
			"upstream", cfg.upstream.Host,
			"after_ms", time.Since(started).Milliseconds(),
		)
	}()
	log.Info("listening", "port", cfg.port, "iap_jwt_check", cfg.iapAudience != "", "rewrite_origin", cfg.rewriteOrigin)

	sig := make(chan os.Signal, 1)
	signal.Notify(sig, syscall.SIGTERM, syscall.SIGINT)
	s := <-sig
	log.Info("shutting down", "signal", s.String())
	h.ready.Store(false)

	ctx, cancel := context.WithTimeout(context.Background(), 8*time.Second)
	defer cancel()
	_ = srv.Shutdown(ctx)
	// Logout deletes the ephemeral node from the tailnet promptly; Close alone
	// leaves it to be garbage-collected later.
	if lc := h.lc.Load(); lc != nil {
		lctx, lcancel := context.WithTimeout(context.Background(), 3*time.Second)
		if err := lc.Logout(lctx); err != nil {
			log.Warn("tsnet logout", "err", err.Error())
		}
		lcancel()
	}
	_ = ts.Close()
	log.Info("stopped")
}
