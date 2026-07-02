output "project_id" {
  description = "GCP project the stack is deployed to."
  value       = var.project_id
}

output "region" {
  description = "GCP region the stack is deployed to."
  value       = var.region
}

output "lb_ip" {
  description = "Global anycast IP of the external HTTPS load balancer."
  value       = google_compute_global_address.lb.address
}

output "lb_url" {
  description = "Proxy URL. HTTPS at the effective domain (customer domain, else the nip.io hostname) when TLS is enabled; otherwise HTTP at the anycast IP."
  value       = local.tls_enabled ? "https://${local.effective_lb_domains[0]}" : "http://${google_compute_global_address.lb.address}"
}

output "gateway_service_url" {
  description = "Default Cloud Run URL for the gateway (bypasses the LB)."
  value       = google_cloud_run_v2_service.gateway.uri
}

output "backend_service_url" {
  description = "Default Cloud Run URL for the backend (bypasses the LB)."
  value       = google_cloud_run_v2_service.backend.uri
}

output "ui_service_url" {
  description = "Default Cloud Run URL for the UI (bypasses the LB)."
  value       = google_cloud_run_v2_service.ui.uri
}

output "cloudsql_connection_name" {
  description = "Cloud SQL instance connection name (project:region:instance) used by the native Cloud Run connector."
  value       = google_sql_database_instance.this.connection_name
}

output "valkey_endpoint" {
  description = "Memorystore Valkey PSC endpoint (host:port), reachable from Cloud Run via Direct VPC egress."
  value       = "${local.valkey_host}:${local.valkey_port}"
}

output "gcs_bucket" {
  description = "GCS bucket name. Exposed to gateway + backend as GCS_BUCKET_NAME."
  value       = google_storage_bucket.this.name
}

output "master_key_secret_id" {
  description = "Secret Manager resource ID holding LITELLM_MASTER_KEY."
  value       = google_secret_manager_secret.master_key.secret_id
}

output "db_url_secret_id" {
  description = "Secret Manager resource ID holding the full DATABASE_URL (unix-socket form)."
  value       = google_secret_manager_secret.db_url.secret_id
}

output "loadtest_job_name" {
  description = "Name of the k6 load-test Cloud Run Job (empty unless enable_loadtest)."
  value       = var.enable_loadtest ? google_cloud_run_v2_job.loadtest[0].name : ""
}

output "loadtest_results_bucket" {
  description = "GCS bucket holding load-test config + k6 summaries (empty unless enable_loadtest)."
  value       = var.enable_loadtest ? google_storage_bucket.loadtest[0].name : ""
}

output "loadtest_ar_repo" {
  description = "STANDARD Artifact Registry repo hosting the k6 image (empty unless enable_loadtest)."
  value       = var.enable_loadtest ? google_artifact_registry_repository.loadtest[0].repository_id : ""
}

output "migration_run_command" {
  description = "Shell command that executes the one-off migration job. Run after the first apply if needed."
  value = format(
    "gcloud run jobs execute %s --region %s --project %s --wait",
    google_cloud_run_v2_job.migrations.name,
    var.region,
    var.project_id,
  )
}
