# herdr-web-gcp

**TL;DR:** reach [herdr-web-ui](https://github.com/devswha/herdr-web-ui) on
your dev box from devices you cannot install Tailscale on, such as a work
phone or a borrowed laptop. Nothing on the dev box is exposed to the internet.
You sign in with your Google account on an IAP-protected Cloud Run URL, and a
tiny proxy carries the traffic onto your tailnet from inside Google Cloud.

```mermaid
flowchart LR
    browser["📱 Browser<br/>anywhere"]

    subgraph gcp["Google Cloud · one project"]
        direction LR
        iap["<b>Gate 1 · IAP</b><br/>Google sign-in<br/>allow-listed accounts"]
        subgraph run["Cloud Run · herdr-proxy · 0–1 instances"]
            direction LR
            jwt["<b>Gate 2 · JWT check</b><br/>signature · audience<br/>issuer · email"]
            rp["Reverse proxy<br/>HTTP + WebSocket<br/>headers stripped"]
            tsnet["tsnet node<br/><i>tag:herdr-proxy</i><br/>ephemeral"]
        end
        sm["Secret Manager<br/>OAuth client secret"]
    end

    subgraph devbox["Dev box on your tailnet"]
        direction LR
        serve["Tailscale Serve<br/>:443 · TLS"]
        ui["<b>Gate 3 · herdr-web-ui</b><br/>127.0.0.1:7317<br/>device pairing"]
        herdr["herdr server<br/>your sessions"]
    end

    browser -- "HTTPS<br/>*.run.app" --> iap
    iap -- "signed<br/>IAP JWT" --> jwt
    jwt --> rp --> tsnet
    sm -. "TS_AUTHKEY<br/>at start" .-> tsnet
    tsnet -- "WireGuard over DERP<br/>policy: tag:herdr-proxy → dev box:443 only" --> serve
    serve --> ui --> herdr

    classDef gate fill:#fff4e5,stroke:#e67e22,stroke-width:2px,color:#000
    classDef cloud fill:#eef4ff,stroke:#4a7bd0,color:#000
    classDef local fill:#eafaf0,stroke:#2e9e5b,color:#000
    classDef secret fill:#f4f4f4,stroke:#888,stroke-dasharray:4 3,color:#000
    class iap,jwt,ui gate
    class rp,tsnet cloud
    class serve,herdr local
    class sm secret
```

Three gates, in order:

1. **Google Identity-Aware Proxy (IAP)** on the Cloud Run service. Only the
   Google accounts you list get past the sign-in page.
2. **The proxy's own IAP JWT check.** Even if the service were reached without
   IAP, requests without a Google-signed assertion for this exact service are
   rejected. By default it accepts the same email addresses as gate 1.
3. **herdr-web-ui's device pairing.** The proxy joins the tailnet as a tagged
   node, so Tailscale adds no user login; the app asks each browser to pair
   once with a six-digit code generated on the dev box.

Nothing is stored in the cloud. The herdr session lives on the dev box, and the
proxy's tailnet identity is ephemeral and discarded with the instance. The
service scales to zero, so it costs effectively nothing between uses.

## Layout

| Path | What |
|---|---|
| `src/herdr-iap-proxy/` | The Go proxy and its Dockerfile |
| `infra/service/` | Terraform: Cloud Run + IAP, runtime SA, secret, Artifact Registry |
| `infra/project/` | Terraform: optionally creates a dedicated GCP project |
| `tailscale/policy-snippet.hujson` | Policy change to merge into your tailnet policy |
| `deploy.sh` | Deployment driver (Infra Manager applies, image build, secret) |

## Prerequisites

- A Tailscale tailnet with the dev box on it, herdr-web-ui running there, and
  admin access to the tailnet policy file.
- A Google Cloud project with billing (or let `infra/project` create one), and
  an account that can create a service account and grant it roles.
- Locally: `gcloud`, `docker`, `git`, and ideally `jq`. Go is not needed; the
  image builds inside Docker.
- herdr-web-ui exposed on the dev box with Tailscale Serve:
  `tailscale serve --bg 7317` (adjust the port). Serve gives you a
  `https://<devbox>.<tailnet>.ts.net` URL with a valid certificate, which is
  what the proxy dials. The app itself keeps listening on localhost only.

## Setup, in order

Steps done in a web console rather than from the repo are marked **(H)**.

1. **Config.** `cp .env.example .env && chmod 600 .env`, fill it in. Copy
   `infra/service/terraform.auto.tfvars.example` to `terraform.auto.tfvars`
   and set `project_id`, `upstream` and `iap_members`.
2. **Deployer service account.** Infra Manager runs Terraform as a service
   account you create once. `infra/README.md` has the commands and roles.
3. **(Optional) Project.** If you want a dedicated project:
   `./deploy.sh preview project`, then `./deploy.sh project`. Put the resulting
   project ID into `infra/service/terraform.auto.tfvars` and `.env`.
4. **Phase 1.** `./deploy.sh base` enables APIs, provisions service agents, and
   creates the runtime SA, the empty secret and the Artifact Registry repo.
5. **(H) Tailnet policy.** Merge `tailscale/policy-snippet.hujson` into your
   policy file (tag owner, the `tag:herdr-proxy → dev box:443` grant, tests).
   Then: Settings → OAuth clients → Generate. Scope **Auth Keys: Write**, tag
   `tag:herdr-proxy`. Copy the secret once.
6. **Secret.** `./deploy.sh secret` and paste it. It is never echoed or stored
   locally.
7. **Image.** `./deploy.sh image` builds in Docker, pushes to Artifact Registry
   and writes `infra/service/image.auto.tfvars` with the digest. Commit it.
8. **Phase 2.** `./deploy.sh apply`. Then `./deploy.sh url`.
9. **(H) Consumer accounts and organizations.** Skip this if the project is
   not in a Google Cloud organization, or if the IAP members are accounts of
   that organization. Otherwise (project in an org, you sign in with a
   `@gmail.com` account): Google-managed IAP OAuth clients only admit in-org
   users, and the org policy `iam.allowedPolicyMemberDomains` may block the
   binding. Once, in the Console for the project: **Google Auth Platform →
   Branding**, Audience **External**; then **Security → Identity-Aware Proxy →
   herdr-proxy → ⋮ Settings → Custom OAuth → Auto Generate Credentials →
   Save**. If step 8 failed on the `iap.httpsResourceAccessor` binding, re-run
   `./deploy.sh apply` now.
10. **(H) Pair the phone.** Open the service URL on the phone and sign in.
    herdr-web-ui shows its pairing screen. On a machine on the tailnet open the
    Serve URL → Settings → Phone & devices → generate a code → enter it on the
    phone. Once per browser.

## Check it works

1. Incognito window → service URL → Google sign-in. A non-allowed account gets
   403 from IAP.
2. `curl -sI https://<url>/` with no credentials gets an IAP redirect or 401,
   never the app.
3. Signed in: the UI loads, the terminal connects, typing echoes, output
   streams without lag.
4. A command started in a herdr pane keeps running after the tab closes;
   reopening shows the same session.
5. After scale-to-zero, the first load succeeds within about 10 seconds.
6. The Tailscale admin console shows one ephemeral `herdr-proxy` node while an
   instance is alive and none after it stops.

## Operations

- **Rotate the Tailscale secret:** generate a new OAuth client (or secret),
  `./deploy.sh secret`, then force a new instance (`gcloud run services update
  herdr-proxy --region=<REGION> --project=<WORKLOAD_PROJECT> --update-labels=rotated=$(date +%s)`
  or just wait for scale-to-zero). Revoke the old client in the admin console.
- **New proxy build:** `./deploy.sh image`, commit `image.auto.tfvars`, `./deploy.sh apply`.
- **Change who may access:** edit `iap_members` (and `iap_allowed_emails` if
  you set it) in `infra/service/terraform.auto.tfvars`, `./deploy.sh apply`.
- **Logs:** `gcloud logging read 'resource.type="cloud_run_revision" AND resource.labels.service_name="herdr-proxy"' --project=<WORKLOAD_PROJECT> --limit=50`.
  JSON lines with `severity`; `component=tsnet` lines are Tailscale's own messages.
- **Teardown:** `infra/README.md`.

## Troubleshooting

- **Pairing screen right after signing in, although the phone was paired.**
  The app's device cookie is `SameSite=Strict`; the first navigation back from
  accounts.google.com is cross-site, so the cookie is withheld once. Reload.
- **502 "upstream unavailable" on every request.** Check `/healthz` via the
  logs. If the tailnet is up, the usual cause is the policy: without the
  `tag:herdr-proxy → dev box:443` grant the peer is not in the netmap, so the
  MagicDNS name does not resolve. `upstream_dial_addr` (`"100.x.y.z:443"`) is
  the escape hatch if resolution itself is the problem.
- **Node missing / stale after idle.** The service runs with CPU always
  allocated (`cpu_always_allocated = true`) so the tailnet connection stays
  alive between requests. Leave it on; the cost is cents, and only while an
  instance exists.
- **WebSocket upgrade rejected (403/400).** herdr-web-ui checks `Origin`;
  `rewrite_origin = true` (default) rewrites it to the Serve hostname.
- **"tsnet up failed" at start.** Bad or revoked OAuth secret, or
  `tag:herdr-proxy` not in `tagOwners`. The container exits so it is visible.
- **"Connecting to herdr web ui…" for 40 s or more.** Not the proxy: the direct
  tailnet URL shows the same wait. It is the app's own boot and scales with
  load on the dev box.
- **"Input held until the terminal is ready" when typing into a pane.** herdr
  allows one attached client per terminal; another tab (often the direct
  tailnet one) already holds that pane. Use a pane no other tab has open, or
  discard the held input.
- **Disconnects after 60 minutes.** Cloud Run's request cap; the UI reconnects
  and the herdr session is unaffected.
- **"Setting IAM permissions failed" on the first IAP enable.** Service-agent
  timing in a fresh project; re-run `./deploy.sh apply`.
