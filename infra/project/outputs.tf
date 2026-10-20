# Copy project_id into ../service/terraform.auto.tfvars and ../../.env after
# the first apply: the two roots are wired by committed values, not by state.
output "project_id" {
  value       = google_project.this.project_id
  description = "The new project (put it in ../service/terraform.auto.tfvars and .env WORKLOAD_PROJECT)"
}

output "project_number" {
  value       = google_project.this.number
  description = "Project number (used in the IAP JWT audience and service agent emails)"
}
