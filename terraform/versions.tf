terraform {
  required_version = ">= 1.6.0"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = ">= 6.36.0, < 7.0.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}

# This module is applied as a root configuration (it owns project_id / region),
# so it configures the provider directly. Auth comes from Application Default
# Credentials (`gcloud auth application-default login`).
provider "google" {
  project = var.project_id
  region  = var.region
}
