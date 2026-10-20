# Everything except the project itself (see ../project/ if you want Terraform
# to create that too). One Cloud Run service (herdr-proxy) with IAP enabled
# directly on it, its runtime service account, the Secret Manager secret
# holding the Tailscale OAuth client secret, and the Artifact Registry repo
# the image is pushed to. All of it lives in one project.
#
# Two-phase apply (Infra Manager has no -target): with var.image == "" the
# service and its IAM bindings are not created (count = 0). `./deploy.sh image`
# writes image.auto.tfvars after pushing; the next apply creates the service.

data "google_project" "this" {
  project_id = var.project_id
}

locals {
  service_name = "herdr-proxy"
  # IAP signs X-Goog-Iap-Jwt-Assertion with this audience for a Cloud Run
  # service (cloud.google.com/iap/docs/signed-headers-howto).
  iap_audience = "/projects/${data.google_project.this.number}/locations/${var.region}/services/${local.service_name}"

  # Default the proxy's email allow-list to the user: members granted IAP access.
  iap_allowed_emails = var.iap_allowed_emails != null ? var.iap_allowed_emails : [
    for m in var.iap_members : trimprefix(m, "user:") if startswith(m, "user:")
  ]

  create_service = var.image != "" ? 1 : 0
}

# --- APIs and service agents -------------------------------------------------

resource "google_project_service" "apis" {
  for_each = toset([
    "run.googleapis.com",
    "iap.googleapis.com",
    "secretmanager.googleapis.com",
    "artifactregistry.googleapis.com",
    "logging.googleapis.com",
  ])
  service            = each.key
  disable_on_destroy = false
}

# Force-provision the IAP and Cloud Run service agents so the IAM bindings
# below can reference them on the first apply. Agents created this way may
# not get their default roles, hence the explicit grants further down.
resource "google_project_service_identity" "iap" {
  provider   = google-beta
  service    = "iap.googleapis.com"
  depends_on = [google_project_service.apis]
}

resource "google_project_service_identity" "run" {
  provider   = google-beta
  service    = "run.googleapis.com"
  depends_on = [google_project_service.apis]
}

# --- Artifact Registry ----------------------------------------------------------

resource "google_artifact_registry_repository" "images" {
  repository_id = "herdr-web"
  location      = var.region
  format        = "DOCKER"
  description   = "herdr-iap-proxy images (pushed by deploy.sh image, pinned by digest in image.auto.tfvars)"
  labels        = var.labels

  cleanup_policies {
    id     = "keep-last-5"
    action = "KEEP"
    most_recent_versions {
      keep_count = 5
    }
  }

  depends_on = [google_project_service.apis]
}

# The Cloud Run service agent pulls the image at deploy time.
resource "google_artifact_registry_repository_iam_member" "run_agent_reader" {
  location   = google_artifact_registry_repository.images.location
  repository = google_artifact_registry_repository.images.name
  role       = "roles/artifactregistry.reader"
  member     = "serviceAccount:${google_project_service_identity.run.email}"
}

# --- Runtime identity and secret ------------------------------------------------

resource "google_service_account" "proxy" {
  account_id   = "herdr-proxy"
  display_name = "herdr-iap-proxy runtime (Cloud Run)"
  depends_on   = [google_project_service.apis]
}

# Metadata only. The value (the Tailscale OAuth client secret) is added as a
# version out-of-band by `./deploy.sh secret`, never by Terraform.
resource "google_secret_manager_secret" "ts_authkey" {
  secret_id = "herdr-proxy-ts-authkey"
  labels    = var.labels

  replication {
    auto {}
  }

  depends_on = [google_project_service.apis]
}

resource "google_secret_manager_secret_iam_member" "proxy_accessor" {
  secret_id = google_secret_manager_secret.ts_authkey.secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.proxy.email}"
}

# --- Cloud Run service (phase 2) --------------------------------------------------

resource "google_cloud_run_v2_service" "proxy" {
  count = local.create_service

  name     = local.service_name
  location = var.region
  labels   = var.labels

  # IAP on the run.app endpoint needs public ingress; IAP is the gate.
  ingress     = "INGRESS_TRAFFIC_ALL"
  iap_enabled = true

  # Provider default is true, which wedges teardown.
  deletion_protection = false

  template {
    service_account                  = google_service_account.proxy.email
    execution_environment            = "EXECUTION_ENVIRONMENT_GEN2"
    timeout                          = "3600s" # WebSockets are capped at 60 min; the UI reconnects
    max_instance_request_concurrency = 80      # page + WebSocket need parallel connections
    session_affinity                 = true
    labels                           = var.labels

    scaling {
      min_instance_count = 0
      max_instance_count = 1
    }

    containers {
      image = var.image

      ports {
        container_port = 8080 # HTTP/1 only (h2c would break the WebSocket upgrade)
      }

      resources {
        limits = {
          cpu    = "1"
          memory = "512Mi"
        }
        cpu_idle          = !var.cpu_always_allocated
        startup_cpu_boost = true
      }

      env {
        name  = "UPSTREAM"
        value = var.upstream
      }
      env {
        name  = "UPSTREAM_DIAL_ADDR"
        value = var.upstream_dial_addr
      }
      env {
        name  = "TS_HOSTNAME"
        value = var.ts_hostname
      }
      env {
        name  = "TS_TAGS"
        value = var.ts_tag
      }
      env {
        name  = "REWRITE_ORIGIN"
        value = tostring(var.rewrite_origin)
      }
      env {
        name  = "IAP_AUDIENCE"
        value = local.iap_audience
      }
      env {
        name  = "IAP_ALLOWED_EMAILS"
        value = join(",", local.iap_allowed_emails)
      }
      env {
        # Stop tsnet shipping its logs to log.tailscale.com.
        name  = "TS_NO_LOGS_NO_SUPPORT"
        value = "true"
      }
      env {
        name = "TS_AUTHKEY"
        value_source {
          secret_key_ref {
            secret  = google_secret_manager_secret.ts_authkey.secret_id
            version = "latest"
          }
        }
      }

      # Traffic is held until tsnet reports Running (60 s budget).
      startup_probe {
        http_get {
          path = "/healthz"
        }
        period_seconds    = 2
        timeout_seconds   = 2
        failure_threshold = 30
      }

      # If the ephemeral node is ever lost (e.g. garbage-collected while the
      # instance was idle), restart the container for a fresh registration.
      liveness_probe {
        http_get {
          path = "/healthz"
        }
        period_seconds    = 30
        timeout_seconds   = 5
        failure_threshold = 3
      }
    }
  }

  depends_on = [
    google_project_service.apis,
    google_project_service_identity.iap,
    google_secret_manager_secret_iam_member.proxy_accessor,
    google_artifact_registry_repository_iam_member.run_agent_reader,
  ]
}

# IAP calls the service as its service agent; it needs invoker.
resource "google_cloud_run_v2_service_iam_member" "iap_invoker" {
  count = local.create_service

  location = google_cloud_run_v2_service.proxy[0].location
  name     = google_cloud_run_v2_service.proxy[0].name
  role     = "roles/run.invoker"
  member   = "serviceAccount:${google_project_service_identity.iap.email}"
}

# Who may pass IAP. If your project sits in a Google Cloud organization and the
# member is a consumer account (e.g. @gmail.com), the org policy
# iam.allowedPolicyMemberDomains must allow it and IAP needs a custom OAuth
# client with an External audience (README.md, "Consumer accounts and
# organizations").
resource "google_iap_web_cloud_run_service_iam_member" "accessor" {
  for_each = var.image == "" ? toset([]) : toset(var.iap_members)

  project                = var.project_id
  location               = google_cloud_run_v2_service.proxy[0].location
  cloud_run_service_name = google_cloud_run_v2_service.proxy[0].name
  role                   = "roles/iap.httpsResourceAccessor"
  member                 = each.value
}
