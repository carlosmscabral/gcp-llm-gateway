# External global HTTP(S) load balancer fronting all three Cloud Run services.
# URL map mirrors the helm ingress routing: LLM data-plane → gateway, UI asset
# paths → ui, everything else → backend (management API).
#
# TLS is on by default with zero DNS setup: the module derives a hostname from
# the LB's static IP via nip.io (`<ip>.nip.io` resolves to `<ip>`) and gets a
# Google-managed certificate for it. Bring-your-own domains via var.lb_domains
# override nip.io. Set var.allow_plaintext_lb = true to fall back to HTTP-only.

locals {
  # nip.io hostname derived from the reserved LB IP (no DNS records needed).
  nip_io_domain = "${google_compute_global_address.lb.address}.nip.io"

  # Domain precedence: customer domains > nip.io (unless plaintext opt-out).
  effective_lb_domains = length(var.lb_domains) > 0 ? var.lb_domains : (
    var.use_nip_io_tls && !var.allow_plaintext_lb ? [local.nip_io_domain] : []
  )

  tls_enabled = length(local.effective_lb_domains) > 0
}

resource "google_compute_global_address" "lb" {
  name   = "${local.name}-lb-ip"
  labels = local.labels
}

resource "google_compute_region_network_endpoint_group" "gateway" {
  name                  = "${local.name}-gateway-neg"
  region                = var.region
  network_endpoint_type = "SERVERLESS"

  cloud_run {
    service = google_cloud_run_v2_service.gateway.name
  }
}

resource "google_compute_region_network_endpoint_group" "backend" {
  name                  = "${local.name}-backend-neg"
  region                = var.region
  network_endpoint_type = "SERVERLESS"

  cloud_run {
    service = google_cloud_run_v2_service.backend.name
  }
}

resource "google_compute_region_network_endpoint_group" "ui" {
  name                  = "${local.name}-ui-neg"
  region                = var.region
  network_endpoint_type = "SERVERLESS"

  cloud_run {
    service = google_cloud_run_v2_service.ui.name
  }
}

resource "google_compute_backend_service" "gateway" {
  name                  = "${local.name}-gateway-bs"
  protocol              = "HTTP"
  load_balancing_scheme = "EXTERNAL_MANAGED"

  backend {
    group = google_compute_region_network_endpoint_group.gateway.id
  }
}

resource "google_compute_backend_service" "backend" {
  name                  = "${local.name}-backend-bs"
  protocol              = "HTTP"
  load_balancing_scheme = "EXTERNAL_MANAGED"

  backend {
    group = google_compute_region_network_endpoint_group.backend.id
  }
}

resource "google_compute_backend_service" "ui" {
  name                  = "${local.name}-ui-bs"
  protocol              = "HTTP"
  load_balancing_scheme = "EXTERNAL_MANAGED"

  backend {
    group = google_compute_region_network_endpoint_group.ui.id
  }
}

resource "google_compute_url_map" "this" {
  name            = local.name
  default_service = google_compute_backend_service.backend.id

  host_rule {
    hosts        = ["*"]
    path_matcher = "main"
  }

  path_matcher {
    name            = "main"
    default_service = google_compute_backend_service.backend.id

    # UI paths first, so / and /favicon.ico win over gateway /v1/* rules.
    path_rule {
      paths   = local.ui_path_prefixes
      service = google_compute_backend_service.ui.id
    }

    # Gateway prefixes. GCP caps a path_rule at 10 globs, so chunk into rules.
    dynamic "path_rule" {
      for_each = { for idx, chunk in chunklist(local.gateway_path_prefixes, 10) : idx => chunk }
      content {
        paths   = path_rule.value
        service = google_compute_backend_service.gateway.id
      }
    }
  }
}

resource "google_compute_url_map" "https_redirect" {
  count = local.tls_enabled ? 1 : 0
  name  = "${local.name}-redirect"

  default_url_redirect {
    https_redirect         = true
    redirect_response_code = "MOVED_PERMANENTLY_DEFAULT"
    strip_query            = false
  }
}

resource "google_compute_target_http_proxy" "this" {
  name    = "${local.name}-http"
  url_map = local.tls_enabled ? google_compute_url_map.https_redirect[0].id : google_compute_url_map.this.id

  lifecycle {
    precondition {
      condition     = local.tls_enabled || var.allow_plaintext_lb
      error_message = "LB has no HTTPS forwarding rule. Set `lb_domains` to DNS names for a Google-managed cert, or set `allow_plaintext_lb = true` to opt into HTTP-only (trial / dev only)."
    }
  }
}

resource "google_compute_global_forwarding_rule" "http" {
  name                  = "${local.name}-http"
  ip_protocol           = "TCP"
  port_range            = "80"
  load_balancing_scheme = "EXTERNAL_MANAGED"
  ip_address            = google_compute_global_address.lb.address
  target                = google_compute_target_http_proxy.this.id
  labels                = local.labels
}

# ---------- HTTPS (gated on var.lb_domains) ----------

resource "google_compute_managed_ssl_certificate" "this" {
  count = local.tls_enabled ? 1 : 0

  name = "${local.name}-cert-${substr(sha1(join(",", local.effective_lb_domains)), 0, 8)}"

  managed {
    domains = local.effective_lb_domains
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "google_compute_target_https_proxy" "this" {
  count            = local.tls_enabled ? 1 : 0
  name             = "${local.name}-https"
  url_map          = google_compute_url_map.this.id
  ssl_certificates = [google_compute_managed_ssl_certificate.this[0].id]
}

resource "google_compute_global_forwarding_rule" "https" {
  count                 = local.tls_enabled ? 1 : 0
  name                  = "${local.name}-https"
  ip_protocol           = "TCP"
  port_range            = "443"
  load_balancing_scheme = "EXTERNAL_MANAGED"
  ip_address            = google_compute_global_address.lb.address
  target                = google_compute_target_https_proxy.this[0].id
  labels                = local.labels
}
