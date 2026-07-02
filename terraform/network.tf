# Minimal VPC for the simplified stack.
#
# Removed vs. upstream:
#   - google_vpc_access_connector  (Serverless VPC Access connector)
#   - google_compute_global_address.psa + google_service_networking_connection
#     (Private Service Access peering)
#
# Cloud Run reaches this VPC via Direct VPC egress (network_interfaces on the
# service template), so no connector is needed. Memorystore Valkey is exposed
# through a Private Service Connect endpoint whose IP is allocated from the PSC
# subnet below via a service connection policy. Cloud SQL is reached through
# Cloud Run's native Cloud SQL connector (unix socket) and needs no VPC path.

resource "google_compute_network" "this" {
  name                    = local.name
  auto_create_subnetworks = false
  routing_mode            = "REGIONAL"

  depends_on = [google_project_service.services]
}

# Main subnet — Cloud Run instances draw Direct VPC egress IPs from here.
resource "google_compute_subnetwork" "this" {
  name                     = "${local.name}-${var.region}"
  region                   = var.region
  network                  = google_compute_network.this.id
  ip_cidr_range            = var.subnet_cidr
  private_ip_google_access = true
}

# Dedicated subnet backing the Private Service Connect endpoint(s) for
# Memorystore Valkey. Kept separate from the Direct VPC egress subnet so PSC
# IP allocation never contends with Cloud Run instance IPs.
resource "google_compute_subnetwork" "psc" {
  name          = "${local.name}-psc"
  region        = var.region
  network       = google_compute_network.this.id
  ip_cidr_range = var.psc_subnet_cidr
  purpose       = "PRIVATE"
}

# Service connection policy authorizes Service Connectivity Automation to
# auto-create PSC endpoints for the Memorystore service class in our network,
# drawing IPs from the PSC subnet.
resource "google_network_connectivity_service_connection_policy" "valkey" {
  name          = "${local.name}-valkey"
  location      = var.region
  service_class = "gcp-memorystore"
  description   = "PSC auto-connect policy for Memorystore Valkey (${local.name})."
  network       = google_compute_network.this.id

  psc_config {
    subnetworks = [google_compute_subnetwork.psc.id]
  }

  depends_on = [google_project_service.services]
}
