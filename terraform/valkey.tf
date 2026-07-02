# Memorystore for Valkey — single-node, reached over Private Service Connect.
#
# Simplified vs. upstream (which used google_redis_instance on PRIVATE_SERVICE_
# ACCESS): Valkey is cheaper and OSS, and PSC auto-connect avoids the legacy
# PSA peering. Transit encryption and auth are disabled — traffic stays on the
# private PSC path inside the VPC, reached only via Cloud Run Direct VPC egress.
# The service connection policy that authorizes the PSC endpoint lives in
# network.tf.

resource "google_memorystore_instance" "this" {
  instance_id = local.name
  location    = var.region

  shard_count    = var.valkey_shard_count
  replica_count  = var.valkey_replica_count
  node_type      = var.valkey_node_type
  engine_version = var.valkey_engine_version

  transit_encryption_mode = "TRANSIT_ENCRYPTION_DISABLED"
  authorization_mode      = "AUTH_DISABLED"

  desired_auto_created_endpoints {
    network    = google_compute_network.this.id
    project_id = var.project_id
  }

  deletion_protection_enabled = var.valkey_deletion_protection

  labels = local.labels

  depends_on = [
    google_network_connectivity_service_connection_policy.valkey,
    google_project_service.services,
  ]
}
