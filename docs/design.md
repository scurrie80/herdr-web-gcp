# Design notes: herdr-web-ui behind Google IAP via Cloud Run and Tailscale

## Goal

Occasional, secure browser access, mainly from a phone, to `herdr-web-ui`
running on a dev box that is reachable only on a Tailscale tailnet. Typical
use: open the UI, start or check a command in a herdr session, leave. The
session lives on the dev box, so the proxy can be fully stateless.

## Architecture

```
Browser ──HTTPS──▶ Cloud Run (*.run.app, IAP enabled directly on the service)
                        │  Go binary: tsnet (embedded Tailscale) + httputil.ReverseProxy
                        ▼  tailnet (WireGuard, usually via a DERP relay)
                   dev box: Tailscale Serve ──▶ herdr-web-ui (HTTP + WebSocket)
```

- **Auth layer:** Identity-Aware Proxy directly on the Cloud Run service, no
  load balancer. Only the listed Google accounts are allowed.
- **Proxy:** one small Go binary using `tailscale.com/tsnet` and
  `net/http/httputil.ReverseProxy`. No tailscaled, no SOCKS proxy, no sidecar.
- **Tailnet identity:** an ephemeral, tagged node (`tag:herdr-proxy`)
  authenticated with a Tailscale **OAuth client secret** from Secret Manager.
  Unlike auth keys, OAuth client secrets do not expire.
- **Tailnet policy:** `tag:herdr-proxy` may reach only the dev box's Serve
  endpoint on 443.
- **Upstream over Serve, not the raw port.** Tailscale Serve gives a valid TLS
  certificate and keeps herdr-web-ui bound to localhost on the dev box. Since
  the proxy node is tagged, Serve adds no user identity, so herdr-web-ui's own
  device pairing remains the last gate.

### Decided against

- An external Application Load Balancer (and HTTP/3). Roughly US$18/month for
  no benefit; the terminal WebSocket runs over TCP anyway.
- A GCE jump box, or running a browser terminal on Cloud Run.
- A custom domain. Easy to add later.
- Cloud Build triggers or any automatic deployment. Everything is driven by a
  human running `deploy.sh`, which keeps the blast radius and cost at zero.

## The proxy

Configuration is entirely from the environment:

| Variable | Meaning |
|---|---|
| `TS_AUTHKEY` | Tailscale OAuth client secret (from Secret Manager). The proxy appends `?ephemeral=true&preauthorized=true`. |
| `UPSTREAM` | `https://<devbox>.<tailnet>.ts.net`, dialled over tsnet |
| `UPSTREAM_DIAL_ADDR` | Optional `ip:port` to dial instead of resolving the name (SNI still uses the name) |
| `PORT` | Set by Cloud Run |
| `TS_HOSTNAME`, `TS_TAGS` | Node name and tags (tags must match the OAuth client) |
| `IAP_AUDIENCE` | Enables JWT verification: `/projects/<number>/locations/<region>/services/<service>` |
| `IAP_ALLOWED_EMAILS` | Optional email allow-list applied to the verified JWT |
| `REWRITE_ORIGIN` | Rewrite the browser's `Origin` to the upstream host (needed for the WebSocket upgrade) |
| `TS_NO_LOGS_NO_SUPPORT` | Set to `true` by Terraform to stop tsnet shipping logs to Tailscale |

Behaviour:

1. Listen on `:$PORT` immediately, so Cloud Run's startup probe can poll
   `/healthz` (503 until the tailnet is up), then bring tsnet up in the
   background with a 60 s budget. A failed `Up` exits 1 so the reason is
   visible in the logs and Cloud Run restarts the container.
2. `/healthz` returns 200 only while the tsnet backend reports `Running`. It is
   never proxied and never behind the JWT check. The startup probe gates
   traffic on it; the liveness probe restarts the container if the ephemeral
   node is ever lost.
3. Every other request passes the IAP guard: `X-Goog-Iap-Jwt-Assertion` must
   validate against Google's IAP keys with the exact audience and issuer, and
   the email claim must be in the allow-list when one is set. Missing or bad
   assertions get 401; a wrong email gets 403.
4. The reverse proxy dials the upstream through `tsnet.Server.Dial`, keeps the
   transport on HTTP/1.1 so WebSocket upgrades work, sets `FlushInterval = -1`
   so terminal output is never buffered, rewrites `Host` (and `Origin` when
   enabled), strips inbound identity and forwarding headers, and rewrites
   absolute redirects back to the host the browser used.
5. Logging is JSON lines that Cloud Logging parses natively. Request logs carry
   method, path, status, duration and whether it was a WebSocket upgrade. No
   bodies, no tokens, no emails.
6. On SIGTERM the HTTP server drains, the node is logged out (which deletes the
   ephemeral device promptly rather than waiting for garbage collection) and
   tsnet is closed.

## Cloud Run settings and why

| Setting | Value | Why |
|---|---|---|
| Ingress | all | IAP on the run.app URL needs public ingress; IAP is the gate |
| IAP | enabled on the service | No load balancer needed |
| Min / max instances | 0 / 1 | Occasional use; one tailnet node at a time |
| Concurrency | 80 | The page and its WebSocket need parallel connections (not 1) |
| Request timeout | 3600 s | Cloud Run caps WebSockets at 60 minutes; the UI reconnects |
| CPU | always allocated | tsnet needs CPU between requests to keep its control and DERP connections alive; with request-based throttling the node goes offline and is garbage-collected |
| Session affinity | on | Keeps a browser on the same instance when there is more than one |
| Port | 8080, HTTP/1 | h2c would break the WebSocket upgrade |
| Startup probe | `/healthz`, 60 s budget | Holds traffic until the node is `Running` |
| Liveness probe | `/healthz` every 30 s | Re-registers a fresh node if the backend ever leaves `Running` |

## Acceptance criteria

1. Opening the service URL in an incognito window forces Google sign-in. A
   non-allowed account gets 403 from IAP.
2. A direct request without IAP credentials is rejected before reaching the app.
3. Signed in, herdr-web-ui loads, the terminal WebSocket connects, typing works,
   and output streams without buffering lag.
4. A command started in herdr keeps running after the tab is closed. Reopening
   shows the same session.
5. After scale-to-zero and a cold start, the first load succeeds within ~10 s.
6. Each cold start appears in the Tailscale admin console as one ephemeral
   `tag:herdr-proxy` node and disappears afterwards. No stale nodes accumulate.
7. From the proxy node, only the dev box on 443 is reachable; the policy tests
   encode this.
8. With `IAP_AUDIENCE` set, a request carrying a forged or missing JWT header
   gets 401 from the proxy.
9. No secrets in the repo, image or logs.

## Known risks

- **Stale tailnet connection after idle** if CPU throttling is enabled. Keep
  `cpu_always_allocated = true`.
- **WebSocket rejected on upgrade** if herdr-web-ui checks `Origin`. Keep
  `rewrite_origin = true`.
- **60-minute WebSocket cap.** Expected; the UI reconnects and the herdr
  session is unaffected.
- **Latency.** Traffic normally goes through a Tailscale DERP relay, because
  Cloud Run cannot accept inbound UDP. Fine for a terminal UI; measured at well
  under a second to open a WebSocket.
- **OAuth secret scope.** Scope it to auth-key creation for `tag:herdr-proxy`
  only, and make sure no other policy rule grants that tag broader access.

## Cost expectation

Effectively free: scale to zero, one instance max, occasional use. Instance
time is billed only while an instance exists (idle instances stop after about
15 minutes). Secret Manager and Artifact Registry costs are negligible.
