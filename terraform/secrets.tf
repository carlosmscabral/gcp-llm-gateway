resource "random_password" "master_key" {
  length      = 48
  special     = false
  min_lower   = 4
  min_upper   = 4
  min_numeric = 4
}

# LITELLM_MASTER_KEY (sk-…). Operator-supplied value wins; otherwise generated.
resource "google_secret_manager_secret" "master_key" {
  secret_id = "${local.name}-master-key"
  labels    = local.labels
  replication {
    auto {}
  }

  depends_on = [google_project_service.services]
}

resource "google_secret_manager_secret_version" "master_key" {
  secret      = google_secret_manager_secret.master_key.id
  secret_data = coalesce(var.litellm_master_key, "sk-${random_password.master_key.result}")
}

# LITELLM_LICENSE — only created when supplied.
resource "google_secret_manager_secret" "license" {
  count = var.litellm_license == "" ? 0 : 1

  secret_id = "${local.name}-license"
  labels    = local.labels
  replication {
    auto {}
  }

  depends_on = [google_project_service.services]
}

resource "google_secret_manager_secret_version" "license" {
  count = var.litellm_license == "" ? 0 : 1

  secret      = google_secret_manager_secret.license[0].id
  secret_data = var.litellm_license
}

# UI_PASSWORD — backend-only, only created when supplied.
resource "google_secret_manager_secret" "ui_password" {
  count = var.ui_password == "" ? 0 : 1

  secret_id = "${local.name}-ui-password"
  labels    = local.labels
  replication {
    auto {}
  }

  depends_on = [google_project_service.services]
}

resource "google_secret_manager_secret_version" "ui_password" {
  count = var.ui_password == "" ? 0 : 1

  secret      = google_secret_manager_secret.ui_password[0].id
  secret_data = var.ui_password
}

# OpenTelemetry Collector config for the sidecar. Not sensitive, but Secret
# Manager is the simplest self-contained way to mount a config file into a
# Cloud Run v2 container (no extra bucket needed).
resource "google_secret_manager_secret" "otel_config" {
  secret_id = "${local.name}-otel-config"
  labels    = local.labels
  replication {
    auto {}
  }

  depends_on = [google_project_service.services]
}

resource "google_secret_manager_secret_version" "otel_config" {
  secret      = google_secret_manager_secret.otel_config.id
  secret_data = local.otel_collector_config_yaml
}
