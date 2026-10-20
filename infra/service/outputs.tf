output "service_uri" {
  value       = var.image == "" ? null : google_cloud_run_v2_service.proxy[0].uri
  description = "The IAP-protected service URL (null until phase 2)"
}

output "service_name" {
  value = local.service_name
}

output "iap_audience" {
  value       = local.iap_audience
  description = "Expected aud claim of the X-Goog-Iap-Jwt-Assertion header"
}

output "artifact_registry" {
  value       = "${var.region}-docker.pkg.dev/${var.project_id}/${google_artifact_registry_repository.images.repository_id}"
  description = "Push the proxy image here (then pin it by digest in image.auto.tfvars)"
}

output "runtime_service_account" {
  value = google_service_account.proxy.email
}

output "ts_authkey_secret" {
  value       = google_secret_manager_secret.ts_authkey.secret_id
  description = "Add the Tailscale OAuth client secret as a version of this secret (./deploy.sh secret)"
}
