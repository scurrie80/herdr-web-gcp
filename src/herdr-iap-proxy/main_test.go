package main

import (
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"io"
	"log/slog"
	"net"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"testing"
	"time"
)

func testLogger() *slog.Logger {
	return slog.New(slog.NewTextHandler(io.Discard, nil))
}

// upstreamRecorder captures what the proxy sends upstream.
type upstreamRecorder struct {
	host   string
	header http.Header
}

func newTestStack(t *testing.T, cfg *config) (*httptest.Server, *upstreamRecorder, *health) {
	t.Helper()
	rec := &upstreamRecorder{}
	up := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		rec.host = r.Host
		rec.header = r.Header.Clone()
		if r.URL.Path == "/redirect" {
			http.Redirect(w, r, "http://"+r.Host+"/landed", http.StatusFound)
			return
		}
		_, _ = w.Write([]byte("upstream ok"))
	}))
	t.Cleanup(up.Close)
	u, _ := url.Parse(up.URL)
	cfg.upstream = u
	if cfg.port == "" {
		cfg.port = "0"
	}
	dial := func(ctx context.Context, network, addr string) (net.Conn, error) {
		var d net.Dialer
		return d.DialContext(ctx, network, addr)
	}
	h := &health{}
	proxy := newProxy(cfg, dial, testLogger())
	front := httptest.NewServer(newHandler(cfg, h, proxy, testLogger()))
	t.Cleanup(front.Close)
	return front, rec, h
}

func get(t *testing.T, srv *httptest.Server, path string, hdr map[string]string) *http.Response {
	t.Helper()
	req, _ := http.NewRequest(http.MethodGet, srv.URL+path, nil)
	for k, v := range hdr {
		req.Header.Set(k, v)
	}
	c := &http.Client{CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}
	resp, err := c.Do(req)
	if err != nil {
		t.Fatalf("request: %v", err)
	}
	t.Cleanup(func() { resp.Body.Close() })
	return resp
}

func TestHeadersStrippedAndRewritten(t *testing.T) {
	cfg := &config{rewriteOrigin: true}
	front, rec, _ := newTestStack(t, cfg)

	resp := get(t, front, "/ws", map[string]string{
		"X-Goog-Iap-Jwt-Assertion":        "secret",
		"X-Goog-Authenticated-User-Email": "accounts.google.com:x@y",
		"X-Serverless-Authorization":      "Bearer z",
		"Tailscale-User-Login":            "user@example.com",
		"X-Forwarded-Proto":               "http",
		"Authorization":                   "Bearer abc",
		"Origin":                          "https://proxy.run.app",
		"X-Cloud-Trace-Context":           "keep-me",
	})
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("status %d", resp.StatusCode)
	}
	for _, k := range []string{"X-Goog-Iap-Jwt-Assertion", "X-Goog-Authenticated-User-Email", "X-Serverless-Authorization", "Tailscale-User-Login", "X-Forwarded-Proto", "Authorization"} {
		if v := rec.header.Get(k); v != "" {
			t.Errorf("header %s reached upstream: %q", k, v)
		}
	}
	if got := rec.header.Get("Origin"); got != cfg.upstream.Scheme+"://"+cfg.upstream.Host {
		t.Errorf("Origin not rewritten: %q", got)
	}
	if rec.host != cfg.upstream.Host {
		t.Errorf("Host = %q, want %q", rec.host, cfg.upstream.Host)
	}
	if rec.header.Get("X-Cloud-Trace-Context") != "keep-me" {
		t.Errorf("unrelated header was dropped")
	}
}

func TestOriginKeptWhenRewriteDisabled(t *testing.T) {
	cfg := &config{rewriteOrigin: false}
	front, rec, _ := newTestStack(t, cfg)
	get(t, front, "/", map[string]string{"Origin": "https://proxy.run.app"})
	if got := rec.header.Get("Origin"); got != "https://proxy.run.app" {
		t.Errorf("Origin changed with REWRITE_ORIGIN=false: %q", got)
	}
}

func TestRedirectRewrittenToInboundHost(t *testing.T) {
	cfg := &config{}
	front, _, _ := newTestStack(t, cfg)
	resp := get(t, front, "/redirect", nil)
	if resp.StatusCode != http.StatusFound {
		t.Fatalf("status %d", resp.StatusCode)
	}
	loc := resp.Header.Get("Location")
	fu, _ := url.Parse(front.URL)
	if !strings.HasPrefix(loc, "https://"+fu.Host+"/landed") {
		t.Errorf("Location = %q, want https://%s/landed", loc, fu.Host)
	}
}

func TestHealthzNotProxied(t *testing.T) {
	cfg := &config{}
	front, rec, h := newTestStack(t, cfg)
	resp := get(t, front, "/healthz", nil)
	if resp.StatusCode != http.StatusServiceUnavailable {
		t.Errorf("healthz before up: %d, want 503", resp.StatusCode)
	}
	if rec.header != nil {
		t.Errorf("/healthz was proxied upstream")
	}
	// ready without a local client is still 503 (never 200 without a Running backend)
	h.ready.Store(true)
	resp = get(t, front, "/healthz", nil)
	if resp.StatusCode != http.StatusServiceUnavailable {
		t.Errorf("healthz ready-but-no-client: %d, want 503", resp.StatusCode)
	}
}

func TestIAPGuardRejectsMissingAndForged(t *testing.T) {
	cfg := &config{iapAudience: "/projects/123/locations/us-central1/services/herdr-proxy"}
	front, rec, _ := newTestStack(t, cfg)

	resp := get(t, front, "/", nil)
	if resp.StatusCode != http.StatusUnauthorized {
		t.Errorf("missing JWT: %d, want 401", resp.StatusCode)
	}
	resp = get(t, front, "/", map[string]string{iapJWTHeader: "not.a.jwt"})
	if resp.StatusCode != http.StatusUnauthorized {
		t.Errorf("garbage JWT: %d, want 401", resp.StatusCode)
	}
	resp = get(t, front, "/", map[string]string{iapJWTHeader: forgedES256(t, cfg.iapAudience)})
	if resp.StatusCode != http.StatusUnauthorized {
		t.Errorf("forged ES256 JWT: %d, want 401", resp.StatusCode)
	}
	if rec.header != nil {
		t.Errorf("a rejected request reached upstream")
	}
	// /healthz stays reachable without a JWT
	resp = get(t, front, "/healthz", nil)
	if resp.StatusCode == http.StatusUnauthorized {
		t.Errorf("/healthz was gated by the IAP guard")
	}
}

// forgedES256 builds a syntactically valid IAP-shaped JWT signed by a key
// Google never issued. Validation must fail at the key lookup / signature.
func forgedES256(t *testing.T, aud string) string {
	t.Helper()
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	enc := func(v any) string {
		b, _ := json.Marshal(v)
		return base64.RawURLEncoding.EncodeToString(b)
	}
	now := time.Now().Unix()
	header := enc(map[string]string{"alg": "ES256", "typ": "JWT", "kid": "forged"})
	payload := enc(map[string]any{
		"iss": iapIssuer, "aud": aud, "sub": "x", "email": "attacker@example.com",
		"iat": now, "exp": now + 300,
	})
	signing := header + "." + payload
	sum := sha256.Sum256([]byte(signing))
	r, s, err := ecdsa.Sign(rand.Reader, key, sum[:])
	if err != nil {
		t.Fatal(err)
	}
	sig := make([]byte, 64)
	r.FillBytes(sig[:32])
	s.FillBytes(sig[32:])
	return signing + "." + base64.RawURLEncoding.EncodeToString(sig)
}

func TestLoadConfigValidation(t *testing.T) {
	t.Setenv("TS_AUTHKEY", "tskey-client-x")
	t.Setenv("UPSTREAM", "not a url")
	if _, err := loadConfig(); err == nil {
		t.Errorf("expected error for bad UPSTREAM")
	}
	t.Setenv("UPSTREAM", "https://devbox.example.ts.net")
	t.Setenv("IAP_ALLOWED_EMAILS", "a@x.com, b@y.com")
	c, err := loadConfig()
	if err != nil {
		t.Fatal(err)
	}
	if c.upstream.Host != "devbox.example.ts.net" || len(c.allowedEmails) != 2 || !c.rewriteOrigin {
		t.Errorf("unexpected config: %+v", c)
	}
}
