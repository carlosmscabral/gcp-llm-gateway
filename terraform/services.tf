# Enable every API the stack needs, in Terraform, so a fresh customer project
# requires no manual `gcloud services enable`. Foundational resources depend on
# this so creation waits until the relevant API is on.
#
# serviceusage.googleapis.com must be enabled out-of-band once per project
# before the first apply (it's the API that lets Terraform manage other APIs).

data "google_project" "this" {}

locals {
  base_apis = [
    "compute.googleapis.com",
    "run.googleapis.com",
    "sqladmin.googleapis.com",
    "memorystore.googleapis.com",
    "networkconnectivity.googleapis.com",
    "secretmanager.googleapis.com",
    "storage.googleapis.com",
    "artifactregistry.googleapis.com",
    "cloudtrace.googleapis.com",
    "monitoring.googleapis.com",
    "iam.googleapis.com",
  ]

  # Vertex AI API added only when the gateway will call Vertex models.
  required_apis = concat(local.base_apis, var.enable_vertex_ai ? ["aiplatform.googleapis.com"] : [])
}

resource "google_project_service" "services" {
  for_each = toset(local.required_apis)

  project = var.project_id
  service = each.value

  # Keep APIs enabled if the stack is destroyed — other workloads in the
  # project may depend on them.
  disable_on_destroy         = false
  disable_dependent_services = false
}
