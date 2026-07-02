# Observability — Cloud Monitoring dashboard, alert policies, and an uptime check
# built on GCP-native metrics (Cloud Run, Cloud SQL, Memorystore). No app changes
# and no LiteLLM license required. Gated by var.enable_monitoring (default true).
#
# LLM-native metrics (spend/tokens/per-model) come from LiteLLM's /metrics scraped
# into Managed Prometheus — see the enable_litellm_metrics path in locals.tf /
# cloudrun.tf, which is off by default (may require an enterprise license).

locals {
  mon_gateway = "${local.name}-gateway"
  mon_sql_id  = "${var.project_id}:${google_sql_database_instance.this.name}"

  # Dashboard tiles: title + metric filter + aligners. Laid out 2-wide.
  mon_base_tiles = [
    {
      t = "Gateway — request rate (req/s)"
      f = "resource.type=\"cloud_run_revision\" resource.labels.service_name=\"${local.mon_gateway}\" metric.type=\"run.googleapis.com/request_count\""
      a = "ALIGN_RATE", r = "REDUCE_SUM"
    },
    {
      t = "Gateway — p95 latency (ms)"
      f = "resource.type=\"cloud_run_revision\" resource.labels.service_name=\"${local.mon_gateway}\" metric.type=\"run.googleapis.com/request_latencies\""
      a = "ALIGN_PERCENTILE_95", r = "REDUCE_MEAN"
    },
    {
      t = "Gateway — 5xx rate (req/s)"
      f = "resource.type=\"cloud_run_revision\" resource.labels.service_name=\"${local.mon_gateway}\" metric.type=\"run.googleapis.com/request_count\" metric.labels.response_code_class=\"5xx\""
      a = "ALIGN_RATE", r = "REDUCE_SUM"
    },
    {
      t = "Gateway — container instances"
      f = "resource.type=\"cloud_run_revision\" resource.labels.service_name=\"${local.mon_gateway}\" metric.type=\"run.googleapis.com/container/instance_count\""
      a = "ALIGN_MAX", r = "REDUCE_SUM"
    },
    {
      t = "Cloud SQL — active connections"
      f = "resource.type=\"cloudsql_database\" resource.labels.database_id=\"${local.mon_sql_id}\" metric.type=\"cloudsql.googleapis.com/database/postgresql/num_backends\""
      a = "ALIGN_MAX", r = "REDUCE_MAX"
    },
    {
      t = "Cloud SQL — CPU utilization"
      f = "resource.type=\"cloudsql_database\" resource.labels.database_id=\"${local.mon_sql_id}\" metric.type=\"cloudsql.googleapis.com/database/cpu/utilization\""
      a = "ALIGN_MEAN", r = "REDUCE_MEAN"
    },
    {
      t = "Valkey — CPU utilization"
      f = "metric.type=\"memorystore.googleapis.com/instance/cpu/average_utilization\" resource.labels.instance_id=\"${local.name}\""
      a = "ALIGN_MEAN", r = "REDUCE_MEAN"
    },
  ]

  # Model Armor tiles (added only when enabled). Counts per filter; Model Armor
  # emits no latency metric, so latency is measured client-side (load-test A/B).
  mon_armor_tiles = var.enable_model_armor ? [
    { t = "Model Armor — sanitize requests/s", f = "metric.type=\"modelarmor.googleapis.com/template/request_count\"", a = "ALIGN_RATE", r = "REDUCE_SUM" },
    { t = "Model Armor — prompt-injection/jailbreak", f = "metric.type=\"modelarmor.googleapis.com/template/pi_jb_request_count\"", a = "ALIGN_RATE", r = "REDUCE_SUM" },
    { t = "Model Armor — sensitive data (SDP)", f = "metric.type=\"modelarmor.googleapis.com/template/sdp_request_count\"", a = "ALIGN_RATE", r = "REDUCE_SUM" },
    { t = "Model Armor — malicious URI", f = "metric.type=\"modelarmor.googleapis.com/template/malicious_uri_request_count\"", a = "ALIGN_RATE", r = "REDUCE_SUM" },
  ] : []

  mon_tiles = concat(local.mon_base_tiles, local.mon_armor_tiles)

  mon_uptime_host = local.tls_enabled ? local.effective_lb_domains[0] : google_compute_global_address.lb.address
}

resource "google_monitoring_dashboard" "this" {
  count = var.enable_monitoring ? 1 : 0

  dashboard_json = jsonencode({
    displayName = "${local.name} — LiteLLM gateway"
    mosaicLayout = {
      columns = 12
      tiles = [for i, d in local.mon_tiles : {
        width  = 6
        height = 4
        xPos   = (i % 2) * 6
        yPos   = floor(i / 2) * 4
        widget = {
          title = d.t
          xyChart = {
            dataSets = [{
              plotType = "LINE"
              timeSeriesQuery = {
                timeSeriesFilter = {
                  filter = d.f
                  aggregation = {
                    alignmentPeriod    = "60s"
                    perSeriesAligner   = d.a
                    crossSeriesReducer = d.r
                  }
                }
              }
            }]
          }
        }
      }]
    }
  })
}

# HTTP uptime check on the load balancer health endpoint.
resource "google_monitoring_uptime_check_config" "gateway" {
  count = var.enable_monitoring ? 1 : 0

  display_name = "${local.name}-gateway-health"
  timeout      = "10s"
  period       = "60s"

  http_check {
    path         = "/health/liveliness"
    port         = local.tls_enabled ? 443 : 80
    use_ssl      = local.tls_enabled
    validate_ssl = local.tls_enabled
  }

  monitored_resource {
    type = "uptime_url"
    labels = {
      project_id = var.project_id
      host       = local.mon_uptime_host
    }
  }
}

# ---------- Alert policies ----------

resource "google_monitoring_alert_policy" "gateway_latency" {
  count = var.enable_monitoring ? 1 : 0

  display_name          = "${local.name} — gateway p95 latency high"
  combiner              = "OR"
  notification_channels = var.alert_notification_channels

  conditions {
    display_name = "p95 request latency > ${var.gateway_latency_p95_alert_ms} ms"
    condition_threshold {
      filter          = "resource.type=\"cloud_run_revision\" resource.labels.service_name=\"${local.mon_gateway}\" metric.type=\"run.googleapis.com/request_latencies\""
      comparison      = "COMPARISON_GT"
      threshold_value = var.gateway_latency_p95_alert_ms
      duration        = "300s"
      aggregations {
        alignment_period   = "60s"
        per_series_aligner = "ALIGN_PERCENTILE_95"
      }
    }
  }
}

resource "google_monitoring_alert_policy" "sql_connections" {
  count = var.enable_monitoring ? 1 : 0

  display_name          = "${local.name} — Cloud SQL connections high"
  combiner              = "OR"
  notification_channels = var.alert_notification_channels

  conditions {
    display_name = "active connections > ${var.sql_connections_alert}"
    condition_threshold {
      filter          = "resource.type=\"cloudsql_database\" resource.labels.database_id=\"${local.mon_sql_id}\" metric.type=\"cloudsql.googleapis.com/database/postgresql/num_backends\""
      comparison      = "COMPARISON_GT"
      threshold_value = var.sql_connections_alert
      duration        = "300s"
      aggregations {
        alignment_period   = "60s"
        per_series_aligner = "ALIGN_MAX"
      }
    }
  }
}

resource "google_monitoring_alert_policy" "gateway_uptime" {
  count = var.enable_monitoring ? 1 : 0

  display_name          = "${local.name} — gateway uptime check failing"
  combiner              = "OR"
  notification_channels = var.alert_notification_channels

  conditions {
    display_name = "uptime check not passing"
    condition_threshold {
      filter          = "resource.type=\"uptime_url\" metric.type=\"monitoring.googleapis.com/uptime_check/check_passed\" metric.labels.check_id=\"${google_monitoring_uptime_check_config.gateway[0].uptime_check_id}\""
      comparison      = "COMPARISON_LT"
      threshold_value = 1
      duration        = "300s"
      aggregations {
        alignment_period   = "300s"
        per_series_aligner = "ALIGN_FRACTION_TRUE"
      }
    }
  }
}
