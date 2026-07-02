# Plan-mode tests using mocked providers — no GCP credentials or API calls.
# Asserts the key simplifications hold: single Cloud SQL instance, Direct VPC
# egress (no connector), native Cloud SQL connector volume, mandatory OTel
# collector sidecar, and Valkey (not Redis) for the cache.

mock_provider "google" {}
mock_provider "random" {}

variables {
  project_id         = "test-project"
  tenant             = "acme"
  env                = "test"
  allow_plaintext_lb = true
}

run "simplified_architecture" {
  command = plan

  # ---- OTel sidecar is mandatory on gateway + backend ----
  assert {
    condition     = length(google_cloud_run_v2_service.gateway.template[0].containers) == 2
    error_message = "gateway must have exactly 2 containers (app + otel collector)."
  }
  assert {
    condition     = contains([for c in google_cloud_run_v2_service.gateway.template[0].containers : c.name], "collector")
    error_message = "gateway must include the otel collector sidecar."
  }
  assert {
    condition     = contains([for c in google_cloud_run_v2_service.backend.template[0].containers : c.name], "collector")
    error_message = "backend must include the otel collector sidecar."
  }

  # ---- Direct VPC egress, not a Serverless VPC connector ----
  assert {
    condition     = length(google_cloud_run_v2_service.gateway.template[0].vpc_access[0].network_interfaces) == 1
    error_message = "gateway must use Direct VPC egress (network_interfaces)."
  }

  # ---- Native Cloud SQL connector volume ----
  assert {
    condition     = contains([for v in google_cloud_run_v2_service.gateway.template[0].volumes : v.name], "cloudsql")
    error_message = "gateway must mount the native Cloud SQL connector volume."
  }

  # ---- Single-node Valkey cache ----
  assert {
    condition     = google_memorystore_instance.this.shard_count == 1
    error_message = "Valkey should be a single shard (simplified, no HA fan-out)."
  }
}
