# Image mirror — a Docker *remote repository* that lazily pulls and caches the
# upstream LiteLLM images (default: ghcr.io/berriai) on first request. Cloud Run
# can't pull ghcr.io directly, so every deploy composes its images from this
# mirror instead. Fully declarative: no `docker pull/push`, no manual steps —
# each customer project gets its own mirror automatically on apply.
#
# Disable by setting create_image_mirror = false (and provide reachable images
# via image_registry / *_image), or bypass by setting image_registry.

locals {
  mirror_repo_id       = var.image_mirror_repository_id != "" ? var.image_mirror_repository_id : "${local.name}-mirror"
  image_mirror_enabled = var.create_image_mirror && var.image_registry == ""
}

resource "google_artifact_registry_repository" "mirror" {
  count = local.image_mirror_enabled ? 1 : 0

  location      = var.region
  repository_id = local.mirror_repo_id
  description   = "Remote mirror of ${var.image_mirror_upstream_uri} for LiteLLM images (${local.name})."
  format        = "DOCKER"
  mode          = "REMOTE_REPOSITORY"
  labels        = local.labels

  remote_repository_config {
    description                 = "Lazily mirrors ${var.image_mirror_upstream_uri}."
    disable_upstream_validation = true

    docker_repository {
      custom_repository {
        uri = var.image_mirror_upstream_uri
      }
    }

    # Only for private upstreams — public ghcr.io/berriai needs none.
    dynamic "upstream_credentials" {
      for_each = var.image_mirror_credentials_secret_version != "" ? [1] : []
      content {
        username_password_credentials {
          username                = var.image_mirror_upstream_username
          password_secret_version = var.image_mirror_credentials_secret_version
        }
      }
    }
  }

  depends_on = [google_project_service.services]
}

# The Cloud Run service agent pulls container images; grant it read on the
# mirror so image pulls (including the lazy upstream fetch) succeed.
resource "google_artifact_registry_repository_iam_member" "cloudrun_pull" {
  count = local.image_mirror_enabled ? 1 : 0

  project    = var.project_id
  location   = var.region
  repository = google_artifact_registry_repository.mirror[0].repository_id
  role       = "roles/artifactregistry.reader"
  member     = "serviceAccount:service-${data.google_project.this.number}@serverless-robot-prod.iam.gserviceaccount.com"
}
