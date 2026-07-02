# Runtime SA for gateway, backend, and the migration job. Has Cloud SQL client,
# Secret Manager accessor on the managed/extra secrets, and — because the OTel
# collector runs as a sidecar under this same SA — the telemetry write roles.
resource "google_service_account" "runtime" {
  account_id   = "${local.name}-runtime"
  display_name = "LiteLLM Cloud Run runtime"
}

# UI runtime SA — no role bindings. The UI is static nginx with no DB, cache,
# or Secret Manager dependency, so a compromised UI container can't pivot.
resource "google_service_account" "ui_runtime" {
  account_id   = "${local.name}-ui-runtime"
  display_name = "LiteLLM Cloud Run UI runtime (no data-plane access)"
}

# Cloud SQL client — required by the native Cloud SQL connector.
resource "google_project_iam_member" "runtime_cloudsql" {
  project = var.project_id
  role    = "roles/cloudsql.client"
  member  = "serviceAccount:${google_service_account.runtime.email}"
}

# Telemetry write roles for the OTel collector sidecar: traces → Cloud Trace,
# metrics → Cloud Monitoring (Managed Service for Prometheus).
resource "google_project_iam_member" "runtime_trace" {
  project = var.project_id
  role    = "roles/cloudtrace.agent"
  member  = "serviceAccount:${google_service_account.runtime.email}"
}

resource "google_project_iam_member" "runtime_metrics" {
  project = var.project_id
  role    = "roles/monitoring.metricWriter"
  member  = "serviceAccount:${google_service_account.runtime.email}"
}

# ---------- Secret accessors ----------

resource "google_secret_manager_secret_iam_member" "master_key" {
  secret_id = google_secret_manager_secret.master_key.id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.runtime.email}"
}

resource "google_secret_manager_secret_iam_member" "db_url" {
  secret_id = google_secret_manager_secret.db_url.id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.runtime.email}"
}

resource "google_secret_manager_secret_iam_member" "otel_config" {
  secret_id = google_secret_manager_secret.otel_config.id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.runtime.email}"
}

resource "google_secret_manager_secret_iam_member" "license" {
  count = var.litellm_license == "" ? 0 : 1

  secret_id = google_secret_manager_secret.license[0].id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.runtime.email}"
}

resource "google_secret_manager_secret_iam_member" "ui_password" {
  count = var.ui_password == "" ? 0 : 1

  secret_id = google_secret_manager_secret.ui_password[0].id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.runtime.email}"
}

# User-supplied extras. Dedupe on the secret resource ID.
resource "google_secret_manager_secret_iam_member" "extras" {
  for_each = toset(values(merge(var.gateway_extra_secrets, var.backend_extra_secrets)))

  secret_id = each.value
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.runtime.email}"
}
