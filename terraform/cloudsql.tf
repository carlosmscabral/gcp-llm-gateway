# Cloud SQL for PostgreSQL — a single instance (no read replica).
#
# Simplified vs. upstream: no private IP / PSA. The instance keeps a public
# IPv4 endpoint but has NO authorized networks, so it is not reachable from the
# internet — only through Cloud Run's native Cloud SQL connector, which uses
# IAM (roles/cloudsql.client) + ephemeral client certs over TLS via the unix
# socket at /cloudsql/<connection_name>. Password auth is used because
# LiteLLM's IAM-auth helper speaks AWS RDS, not GCP IAM.

resource "google_sql_database_instance" "this" {
  name             = local.name
  region           = var.region
  database_version = var.db_version

  settings {
    edition           = var.db_edition
    tier              = var.db_tier
    availability_type = var.db_availability_type
    disk_size         = 20
    disk_autoresize   = true

    user_labels = local.labels

    backup_configuration {
      enabled                        = true
      point_in_time_recovery_enabled = true
      start_time                     = "07:00"
    }

    ip_configuration {
      # Public IP is enabled so the native Cloud SQL connector can reach the
      # instance, but no authorized_networks are added — connections still
      # require IAM + client certs, so the DB is not open to the internet.
      ipv4_enabled = true
      ssl_mode     = "ENCRYPTED_ONLY"
    }

    insights_config {
      query_insights_enabled  = true
      record_application_tags = true
      record_client_address   = true
    }
  }

  deletion_protection = var.cloudsql_deletion_protection

  lifecycle {
    # disk_autoresize grows storage but never shrinks it; set the initial size
    # only and let Cloud SQL own it thereafter (otherwise a perceived shrink
    # forces a destroy/recreate).
    ignore_changes = [settings[0].disk_size]
  }

  depends_on = [google_project_service.services]
}

resource "google_sql_database" "this" {
  name            = var.db_name
  instance        = google_sql_database_instance.this.name
  deletion_policy = "ABANDON"
}

resource "random_password" "db_password" {
  length      = 32
  special     = false
  min_lower   = 4
  min_upper   = 4
  min_numeric = 4
}

resource "google_sql_user" "app" {
  name            = var.db_username
  instance        = google_sql_database_instance.this.name
  password        = random_password.db_password.result
  deletion_policy = "ABANDON"
}

# Whole DATABASE_URL assembled at apply time (password is known), so the Cloud
# Run containers and the migration job just consume DATABASE_URL directly — no
# runtime shell assembly needed. The `host` query param points Prisma at the
# Cloud SQL unix socket mounted by the native connector.
resource "google_secret_manager_secret" "db_url" {
  secret_id = "${local.name}-db-url"
  labels    = local.labels
  replication {
    auto {}
  }

  depends_on = [google_project_service.services]
}

resource "google_secret_manager_secret_version" "db_url" {
  secret      = google_secret_manager_secret.db_url.id
  secret_data = "postgresql://${var.db_username}:${random_password.db_password.result}@localhost/${var.db_name}?host=/cloudsql/${google_sql_database_instance.this.connection_name}"
}
