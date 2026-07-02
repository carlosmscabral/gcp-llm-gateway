# General-purpose GCS bucket. Name exposed to gateway + backend as
# GCS_BUCKET_NAME; reference it from proxy_config via os.environ/GCS_BUCKET_NAME.

resource "random_id" "bucket_suffix" {
  byte_length = 4
}

resource "google_storage_bucket" "this" {
  name                        = "${var.project_id}-${local.name}-${random_id.bucket_suffix.hex}"
  location                    = var.region
  uniform_bucket_level_access = true
  force_destroy               = var.gcs_force_destroy
  public_access_prevention    = "enforced"

  versioning {
    enabled = true
  }

  labels = local.labels

  depends_on = [google_project_service.services]
}

resource "google_storage_bucket_iam_member" "runtime" {
  bucket = google_storage_bucket.this.name
  role   = "roles/storage.objectAdmin"
  member = "serviceAccount:${google_service_account.runtime.email}"
}

# Dedicated bucket holding only config.yaml, mounted read-only via gcsfuse.
# Only created when proxy_config is non-empty.
resource "google_storage_bucket" "proxy_config" {
  count = local.proxy_config_enabled ? 1 : 0

  name                        = "${var.project_id}-${local.name}-config-${random_id.bucket_suffix.hex}"
  location                    = var.region
  uniform_bucket_level_access = true
  force_destroy               = var.gcs_force_destroy
  public_access_prevention    = "enforced"

  versioning {
    enabled = true
  }

  labels = local.labels
}

resource "google_storage_bucket_object" "proxy_config" {
  count = local.proxy_config_enabled ? 1 : 0

  name         = local.proxy_config_file_name
  bucket       = google_storage_bucket.proxy_config[0].name
  content      = local.proxy_config_yaml
  content_type = "application/yaml"
}

resource "google_storage_bucket_iam_member" "proxy_config_runtime" {
  count = local.proxy_config_enabled ? 1 : 0

  bucket = google_storage_bucket.proxy_config[0].name
  role   = "roles/storage.objectViewer"
  member = "serviceAccount:${google_service_account.runtime.email}"
}
