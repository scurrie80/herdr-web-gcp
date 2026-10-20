# No backend block: this root is applied through GCP Infrastructure Manager
# (see ../../deploy.sh), which stores and locks state itself and rejects
# sources that declare a backend. To run plain `terraform` instead, add a
# backend_override.tf (gitignored and gcloudignored) with your own backend.
terraform {
  required_version = ">= 1.5.0"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 7.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.0"
    }
  }
}

provider "google" {
  region = var.region
}
