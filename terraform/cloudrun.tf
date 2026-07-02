# Three Cloud Run v2 services + one migration Job.
#
# Gateway and backend:
#   - reach Cloud SQL via the native Cloud SQL connector (cloud_sql_instance
#     volume → unix socket at /cloudsql/<connection_name>), no VPC needed;
#   - reach Memorystore Valkey via Direct VPC egress (network_interfaces) into
#     the main subnet — no Serverless VPC Access connector;
#   - run a Google-built OpenTelemetry Collector sidecar ("collector") that
#     receives OTLP on localhost and ships traces/metrics to GCP. The app
#     container depends on the collector via container-dependencies so spans
#     aren't dropped at boot.

# ---------- Gateway ----------
resource "google_cloud_run_v2_service" "gateway" {
  name                = "${local.name}-gateway"
  location            = var.region
  ingress             = "INGRESS_TRAFFIC_INTERNAL_LOAD_BALANCER"
  labels              = local.labels
  deletion_protection = false

  template {
    service_account                  = google_service_account.runtime.email
    max_instance_request_concurrency = var.gateway_max_instance_request_concurrency

    annotations = {
      "run.googleapis.com/container-dependencies" = jsonencode({ app = ["collector"] })
    }

    vpc_access {
      network_interfaces {
        network    = google_compute_network.this.id
        subnetwork = google_compute_subnetwork.this.id
      }
      egress = "PRIVATE_RANGES_ONLY"
    }

    scaling {
      min_instance_count = var.gateway_min_instances
      max_instance_count = var.gateway_max_instances
    }

    # ---- app ----
    containers {
      name    = "app"
      image   = local.gateway_image
      command = ["sh", "-c"]
      args    = [local.gateway_args]

      ports {
        container_port = 4000
      }

      resources {
        limits = {
          cpu    = var.gateway_cpu
          memory = var.gateway_memory
        }
      }

      dynamic "env" {
        for_each = concat(local.shared_env_kv, local.gateway_otel_env_kv, local.gateway_extra_env_kv, local.proxy_config_env)
        content {
          name  = env.value.name
          value = env.value.value
        }
      }

      dynamic "env" {
        for_each = concat(local.shared_env_secrets, local.gateway_extra_secret_kv)
        content {
          name = env.value.name
          value_source {
            secret_key_ref {
              secret  = env.value.secret
              version = env.value.version
            }
          }
        }
      }

      volume_mounts {
        name       = "cloudsql"
        mount_path = "/cloudsql"
      }

      dynamic "volume_mounts" {
        for_each = local.proxy_config_enabled ? [1] : []
        content {
          name       = local.proxy_config_volume
          mount_path = local.proxy_config_mount_path
        }
      }

      startup_probe {
        http_get {
          path = "/health/readiness"
          port = 4000
        }
        initial_delay_seconds = 10
        period_seconds        = 10
        timeout_seconds       = 5
        failure_threshold     = 12
      }

      liveness_probe {
        http_get {
          path = "/health/liveliness"
          port = 4000
        }
        period_seconds  = 30
        timeout_seconds = 5
      }
    }

    # ---- collector sidecar ----
    containers {
      name  = "collector"
      image = var.otel_collector_image
      args  = ["--config=/etc/otelcol-google/config.yaml"]

      resources {
        limits = {
          cpu    = var.otel_collector_cpu
          memory = var.otel_collector_memory
        }
      }

      volume_mounts {
        name       = "otel-config"
        mount_path = "/etc/otelcol-google"
      }

      startup_probe {
        tcp_socket {
          port = 13133
        }
        period_seconds    = 10
        timeout_seconds   = 5
        failure_threshold = 6
      }
    }

    volumes {
      name = "cloudsql"
      cloud_sql_instance {
        instances = [google_sql_database_instance.this.connection_name]
      }
    }

    volumes {
      name = "otel-config"
      secret {
        secret = google_secret_manager_secret.otel_config.secret_id
        items {
          path    = "config.yaml"
          version = "latest"
        }
      }
    }

    dynamic "volumes" {
      for_each = local.proxy_config_enabled ? [1] : []
      content {
        name = local.proxy_config_volume
        gcs {
          bucket    = google_storage_bucket.proxy_config[0].name
          read_only = true
        }
      }
    }
  }

  depends_on = [
    google_secret_manager_secret_iam_member.master_key,
    google_secret_manager_secret_iam_member.db_url,
    google_secret_manager_secret_iam_member.otel_config,
    google_secret_manager_secret_iam_member.license,
    google_secret_manager_secret_iam_member.extras,
    google_storage_bucket_iam_member.proxy_config_runtime,
    google_sql_user.app,
    terraform_data.migration,
  ]
}

# ---------- Backend ----------
resource "google_cloud_run_v2_service" "backend" {
  name                = "${local.name}-backend"
  location            = var.region
  ingress             = "INGRESS_TRAFFIC_INTERNAL_LOAD_BALANCER"
  labels              = local.labels
  deletion_protection = false

  template {
    service_account                  = google_service_account.runtime.email
    max_instance_request_concurrency = var.backend_max_instance_request_concurrency

    annotations = {
      "run.googleapis.com/container-dependencies" = jsonencode({ app = ["collector"] })
    }

    vpc_access {
      network_interfaces {
        network    = google_compute_network.this.id
        subnetwork = google_compute_subnetwork.this.id
      }
      egress = "PRIVATE_RANGES_ONLY"
    }

    scaling {
      min_instance_count = var.backend_min_instances
      max_instance_count = var.backend_max_instances
    }

    # ---- app ----
    containers {
      name    = "app"
      image   = local.backend_image
      command = ["sh", "-c"]
      args    = [local.backend_args]

      ports {
        container_port = 4001
      }

      resources {
        limits = {
          cpu    = var.backend_cpu
          memory = var.backend_memory
        }
      }

      dynamic "env" {
        for_each = concat(local.shared_env_kv, local.backend_default_env_kv, local.backend_otel_env_kv, local.backend_extra_env_kv, local.proxy_config_env)
        content {
          name  = env.value.name
          value = env.value.value
        }
      }

      dynamic "env" {
        for_each = concat(local.shared_env_secrets, local.backend_managed_env_secrets, local.backend_extra_secret_kv)
        content {
          name = env.value.name
          value_source {
            secret_key_ref {
              secret  = env.value.secret
              version = env.value.version
            }
          }
        }
      }

      volume_mounts {
        name       = "cloudsql"
        mount_path = "/cloudsql"
      }

      dynamic "volume_mounts" {
        for_each = local.proxy_config_enabled ? [1] : []
        content {
          name       = local.proxy_config_volume
          mount_path = local.proxy_config_mount_path
        }
      }

      startup_probe {
        http_get {
          path = "/health/readiness"
          port = 4001
        }
        initial_delay_seconds = 10
        period_seconds        = 10
        timeout_seconds       = 5
        failure_threshold     = 12
      }

      liveness_probe {
        http_get {
          path = "/health/liveliness"
          port = 4001
        }
        period_seconds  = 30
        timeout_seconds = 5
      }
    }

    # ---- collector sidecar ----
    containers {
      name  = "collector"
      image = var.otel_collector_image
      args  = ["--config=/etc/otelcol-google/config.yaml"]

      resources {
        limits = {
          cpu    = var.otel_collector_cpu
          memory = var.otel_collector_memory
        }
      }

      volume_mounts {
        name       = "otel-config"
        mount_path = "/etc/otelcol-google"
      }

      startup_probe {
        tcp_socket {
          port = 13133
        }
        period_seconds    = 10
        timeout_seconds   = 5
        failure_threshold = 6
      }
    }

    volumes {
      name = "cloudsql"
      cloud_sql_instance {
        instances = [google_sql_database_instance.this.connection_name]
      }
    }

    volumes {
      name = "otel-config"
      secret {
        secret = google_secret_manager_secret.otel_config.secret_id
        items {
          path    = "config.yaml"
          version = "latest"
        }
      }
    }

    dynamic "volumes" {
      for_each = local.proxy_config_enabled ? [1] : []
      content {
        name = local.proxy_config_volume
        gcs {
          bucket    = google_storage_bucket.proxy_config[0].name
          read_only = true
        }
      }
    }
  }

  depends_on = [
    google_secret_manager_secret_iam_member.master_key,
    google_secret_manager_secret_iam_member.db_url,
    google_secret_manager_secret_iam_member.otel_config,
    google_secret_manager_secret_iam_member.license,
    google_secret_manager_secret_iam_member.ui_password,
    google_secret_manager_secret_iam_member.extras,
    google_storage_bucket_iam_member.proxy_config_runtime,
    google_sql_user.app,
    terraform_data.migration,
  ]
}

# ---------- UI ----------
# Static nginx — no DB, cache, secrets, VPC, or OTel. Runs as ui_runtime (a SA
# with zero IAM bindings).
resource "google_cloud_run_v2_service" "ui" {
  name                = "${local.name}-ui"
  location            = var.region
  ingress             = "INGRESS_TRAFFIC_INTERNAL_LOAD_BALANCER"
  labels              = local.labels
  deletion_protection = false

  template {
    service_account                  = google_service_account.ui_runtime.email
    max_instance_request_concurrency = var.ui_max_instance_request_concurrency

    scaling {
      min_instance_count = var.ui_min_instances
      max_instance_count = var.ui_max_instances
    }

    containers {
      image = local.ui_image

      ports {
        container_port = 3000
      }

      resources {
        limits = {
          cpu    = var.ui_cpu
          memory = var.ui_memory
        }
      }

      startup_probe {
        http_get {
          path = "/healthz"
          port = 3000
        }
        initial_delay_seconds = 5
        period_seconds        = 10
        timeout_seconds       = 3
        failure_threshold     = 6
      }
    }
  }
}

# Open Cloud Run's invoker gate so LB traffic reaches the containers. Real auth
# is in the proxy (LITELLM_MASTER_KEY).
resource "google_cloud_run_v2_service_iam_member" "gateway_allusers" {
  project  = var.project_id
  location = google_cloud_run_v2_service.gateway.location
  name     = google_cloud_run_v2_service.gateway.name
  role     = "roles/run.invoker"
  member   = "allUsers"
}

resource "google_cloud_run_v2_service_iam_member" "backend_allusers" {
  project  = var.project_id
  location = google_cloud_run_v2_service.backend.location
  name     = google_cloud_run_v2_service.backend.name
  role     = "roles/run.invoker"
  member   = "allUsers"
}

resource "google_cloud_run_v2_service_iam_member" "ui_allusers" {
  project  = var.project_id
  location = google_cloud_run_v2_service.ui.location
  name     = google_cloud_run_v2_service.ui.name
  role     = "roles/run.invoker"
  member   = "allUsers"
}

# ---------- Migrations job ----------
# Reaches Cloud SQL via the native connector (no VPC). Consumes DATABASE_URL
# directly from Secret Manager.
resource "google_cloud_run_v2_job" "migrations" {
  name                = "${local.name}-migrations"
  location            = var.region
  labels              = local.labels
  deletion_protection = false

  template {
    template {
      service_account = google_service_account.runtime.email

      containers {
        image = local.migrations_image

        resources {
          limits = {
            cpu    = "1000m"
            memory = "4Gi"
          }
        }

        dynamic "env" {
          for_each = local.migrations_env_secrets
          content {
            name = env.value.name
            value_source {
              secret_key_ref {
                secret  = env.value.secret
                version = env.value.version
              }
            }
          }
        }

        volume_mounts {
          name       = "cloudsql"
          mount_path = "/cloudsql"
        }
      }

      volumes {
        name = "cloudsql"
        cloud_sql_instance {
          instances = [google_sql_database_instance.this.connection_name]
        }
      }
    }
  }

  depends_on = [
    google_secret_manager_secret_iam_member.db_url,
    google_sql_user.app,
  ]
}
