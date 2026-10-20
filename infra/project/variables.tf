variable "project_id_prefix" {
  type        = string
  description = "Project ID prefix; a random 4-character suffix is appended for global uniqueness (project IDs can never be reused)."
  default     = "herdr-web"

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{3,24}$", var.project_id_prefix))
    error_message = "project_id_prefix must start with a letter, be 4-25 chars of lowercase letters, digits or hyphens."
  }
}

variable "project_name" {
  type        = string
  description = "Display name of the project."
  default     = "herdr-web"
}

variable "folder_id" {
  type        = string
  description = "Numeric folder ID to create the project under. Leave empty to use org_id, or leave both empty for a project with no organization (personal account)."
  default     = ""

  validation {
    condition     = var.folder_id == "" || can(regex("^[0-9]+$", var.folder_id))
    error_message = "folder_id must be the bare numeric folder ID (no folders/ prefix)."
  }
}

variable "org_id" {
  type        = string
  description = "Numeric organization ID to create the project under, when not using a folder."
  default     = ""
}

variable "billing_account" {
  type        = string
  description = "Billing account ID (XXXXXX-XXXXXX-XXXXXX) the new project links to."
}

variable "region" {
  type        = string
  description = "Default provider region (nothing regional is created in this root)."
  default     = "us-central1"
}

variable "labels" {
  type        = map(string)
  description = "Labels applied to the project."
  default = {
    app        = "herdr-web"
    managed-by = "terraform"
  }
}
