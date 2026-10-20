variable "project_id" {
  type        = string
  description = "GCP project that hosts the Cloud Run service, its runtime service account, the secret and the Artifact Registry repo."
}

variable "region" {
  type        = string
  description = "Region for the Cloud Run service and the Artifact Registry repo. Pick one close to you; latency to the dev box goes over Tailscale anyway."
  default     = "us-central1"
}

variable "image" {
  type        = string
  description = <<-EOT
    Full Artifact Registry image reference BY DIGEST
    (<region>-docker.pkg.dev/<project>/herdr-web/herdr-iap-proxy@sha256:...).
    Empty (the default) means "phase 1": APIs, identities, runtime SA, secret
    and Artifact Registry are created but no Cloud Run service yet, because
    the service cannot exist before the image is pushed and the secret has a
    version. `./deploy.sh image` writes image.auto.tfvars; commit it. Never
    pass this via --input-values: an apply without it would destroy the service.
  EOT
  default     = ""

  validation {
    condition     = var.image == "" || can(regex("@sha256:[0-9a-f]{64}$", var.image))
    error_message = "image must be pinned by digest (…@sha256:<64 hex>), never by tag."
  }
}

variable "upstream" {
  type        = string
  description = "herdr-web-ui as seen from the tailnet: normally the Tailscale Serve URL of the dev box, e.g. https://devbox.your-tailnet.ts.net. Dialled from inside the proxy over tsnet."

  validation {
    condition     = can(regex("^https?://", var.upstream))
    error_message = "upstream must be an http(s) URL."
  }
}

variable "upstream_dial_addr" {
  type        = string
  description = "Optional ip:port to dial instead of resolving the upstream name via MagicDNS (escape hatch; TLS SNI still uses the name)."
  default     = ""
}

variable "rewrite_origin" {
  type        = bool
  description = "Rewrite the browser's Origin header to the upstream host so WebSocket upgrades pass herdr-web-ui's origin check."
  default     = true
}

variable "cpu_always_allocated" {
  type        = bool
  description = <<-EOT
    true = instance-based billing (CPU always on while an instance exists).
    tsnet needs CPU between requests to keep its control/DERP connection
    alive; with request-based throttling the ephemeral node goes offline, is
    garbage-collected, and every later dial fails until the liveness probe
    restarts the container. Cost applies only while an instance is alive
    (idle instances stop after ~15 min), so leave this on.
  EOT
  default     = true
}

variable "iap_members" {
  type        = list(string)
  description = "Principals granted roles/iap.httpsResourceAccessor on the service, in IAM member syntax, e.g. [\"user:you@example.com\"]."

  validation {
    condition     = length(var.iap_members) > 0
    error_message = "iap_members must list at least one principal, or nobody can reach the service."
  }
}

variable "iap_allowed_emails" {
  type        = list(string)
  description = "Emails the proxy itself accepts in the verified IAP JWT (defence in depth on top of the IAP IAM policy). null (default) = the user: members of iap_members. [] = any IAP-authenticated principal."
  default     = null
}

variable "ts_hostname" {
  type        = string
  description = "Tailnet hostname the ephemeral node registers as."
  default     = "herdr-proxy"
}

variable "ts_tag" {
  type        = string
  description = "Tailnet tag the node advertises; must match the Tailscale OAuth client's tag and the policy's tagOwners."
  default     = "tag:herdr-proxy"
}

variable "labels" {
  type        = map(string)
  description = "Labels applied to every resource that supports them."
  default = {
    app        = "herdr-web"
    managed-by = "terraform"
  }
}
