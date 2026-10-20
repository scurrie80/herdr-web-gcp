# Project creation, deliberately its own Terraform root and its own Infra
# Manager deployment, separate from ../service/. google_project is the one
# resource where a bad plan can permanently burn quota: deleted project IDs
# stay reserved for 30 days. Keeping it in a state that the frequently-changed
# service configuration never touches means no proxy refactor can accidentally
# replace the project. It is create-only: deletion_policy PREVENT plus
# prevent_destroy, so removing it takes two deliberate config edits.
#
# This root is optional. If you already have a project, skip it and put that
# project's ID in ../service/terraform.auto.tfvars.

locals {
  # google_project accepts at most one parent; neither means "no organization".
  folder_id = var.folder_id != "" ? var.folder_id : null
  org_id    = var.folder_id == "" && var.org_id != "" ? var.org_id : null
}

# Global-uniqueness suffix, generated once and kept for the life of the project.
resource "random_string" "suffix" {
  length  = 4
  lower   = true
  upper   = false
  numeric = true
  special = false
}

resource "google_project" "this" {
  name            = var.project_name
  project_id      = "${var.project_id_prefix}-${random_string.suffix.result}"
  folder_id       = local.folder_id
  org_id          = local.org_id
  billing_account = var.billing_account
  deletion_policy = "PREVENT"
  labels          = var.labels

  lifecycle {
    prevent_destroy = true
  }
}

# Baseline APIs only; ../service/ owns all service-specific enablement.
resource "google_project_service" "baseline" {
  for_each = toset([
    "cloudresourcemanager.googleapis.com",
    "serviceusage.googleapis.com",
    "iam.googleapis.com",
  ])
  project            = google_project.this.project_id
  service            = each.key
  disable_on_destroy = false
}
