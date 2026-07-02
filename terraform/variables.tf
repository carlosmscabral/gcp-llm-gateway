variable "project_id" {
  description = "GCP project ID."
  type        = string
}

variable "region" {
  description = "GCP region for VPC, Cloud SQL, Memorystore, Cloud Run, and the LB IP."
  type        = string
  default     = "us-central1"
}

variable "tenant" {
  description = "Tenant slug — prefix for every resource. Combined with var.env as `<tenant>-litellm-<env>`."
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{0,20}$", var.tenant))
    error_message = "tenant must be 1-21 chars, lower-kebab-case, starting with a letter."
  }
}

variable "env" {
  description = "Environment suffix appended to every resource name (e.g. `stage`, `prod`, `dev`)."
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{0,8}$", var.env))
    error_message = "env must be 1-9 chars, lower-kebab-case, starting with a letter."
  }
}

variable "labels" {
  description = "Per-deployment labels applied to every label-supporting resource, on top of the module's own labels."
  type        = map(string)
  default     = {}
}

# ---------- Tenant-supplied secrets ----------

variable "litellm_master_key" {
  description = "Pre-existing LITELLM_MASTER_KEY (must begin with `sk-`). Empty auto-generates a random `sk-…` key."
  type        = string
  default     = ""
  sensitive   = true
}

variable "litellm_license" {
  description = "LiteLLM enterprise license string. Empty for OSS-only deploys."
  type        = string
  default     = ""
  sensitive   = true
}

variable "ui_password" {
  description = "UI admin password, exposed to the backend as UI_PASSWORD. Empty falls back to LITELLM_MASTER_KEY for UI login."
  type        = string
  default     = ""
  sensitive   = true
}

# ---------- Networking ----------
#
# Simplified vs. upstream: no Serverless VPC Access connector and no Private
# Service Access peering. Cloud Run reaches the VPC via Direct VPC egress
# (main subnet); Memorystore Valkey is reached over a Private Service Connect
# endpoint allocated from the PSC subnet; Cloud SQL is reached via Cloud Run's
# native Cloud SQL connector (unix socket), which needs no VPC at all.

variable "subnet_cidr" {
  description = "CIDR for the main subnet Cloud Run uses for Direct VPC egress."
  type        = string
  default     = "10.40.0.0/20"
}

variable "psc_subnet_cidr" {
  description = "CIDR for the subnet that backs the Private Service Connect endpoint for Memorystore Valkey."
  type        = string
  default     = "10.40.240.0/24"
}

# ---------- Component images ----------
#
# By default the module stands up an Artifact Registry remote repository that
# mirrors ghcr.io/berriai (see create_image_mirror below) and composes image
# URIs from it, because Cloud Run cannot pull ghcr.io directly. Set
# image_registry to bypass the mirror and compose from an explicit prefix, or
# set the per-component *_image vars for full URIs.

variable "image_registry" {
  description = "Explicit registry prefix used to compose image URIs as `<image_registry>/litellm-<component>:<image_tag>`. Empty (default) uses the built-in Artifact Registry mirror. Cloud Run accepts Artifact Registry / gcr.io / docker.io only."
  type        = string
  default     = ""
}

variable "create_image_mirror" {
  description = "Create an Artifact Registry remote repo that lazily mirrors the upstream images, and compose image URIs from it. Ignored when image_registry is set."
  type        = bool
  default     = true
}

variable "image_mirror_upstream_uri" {
  description = "Upstream Docker registry the mirror pulls from."
  type        = string
  default     = "https://ghcr.io"
}

variable "image_mirror_upstream_path" {
  description = "Namespace/org path under the upstream registry (composed as `<mirror>/<path>/litellm-<component>`)."
  type        = string
  default     = "berriai"
}

variable "image_mirror_repository_id" {
  description = "Artifact Registry repository ID for the mirror. Empty defaults to `<tenant>-litellm-<env>-mirror`."
  type        = string
  default     = ""
}

variable "image_mirror_upstream_username" {
  description = "Username for a private upstream registry. Only used when image_mirror_credentials_secret_version is set."
  type        = string
  default     = ""
}

variable "image_mirror_credentials_secret_version" {
  description = "Secret Manager secret *version* name holding the upstream registry password/token (for private upstreams). Empty = anonymous pulls."
  type        = string
  default     = ""
}

variable "image_tag" {
  description = "Tag applied to all four litellm-* images when composed from image_registry."
  type        = string
  default     = "v1.86.0-dev"
}

variable "gateway_image" {
  description = "Full gateway image URI. Empty composes from image_registry + image_tag."
  type        = string
  default     = ""
}

variable "backend_image" {
  description = "Full backend image URI. Empty composes from image_registry + image_tag."
  type        = string
  default     = ""
}

variable "ui_image" {
  description = "Full UI image URI. Empty composes from image_registry + image_tag."
  type        = string
  default     = ""
}

variable "migrations_image" {
  description = "Full migrations image URI (prisma migrate deploy job). Empty composes from image_registry + image_tag."
  type        = string
  default     = ""
}

# ---------- Service sizing ----------

variable "gateway_cpu" {
  description = "Cloud Run CPU per gateway instance (app container; the OTel sidecar adds its own)."
  type        = string
  default     = "1000m"
}

variable "gateway_memory" {
  description = "Cloud Run memory per gateway instance (app container)."
  type        = string
  default     = "4Gi"
}

variable "gateway_num_workers" {
  description = "uvicorn worker processes per gateway instance."
  type        = number
  default     = 1

  validation {
    condition     = var.gateway_num_workers >= 1
    error_message = "gateway_num_workers must be >= 1."
  }
}

variable "gateway_min_instances" {
  description = "Lower bound on gateway Cloud Run instances."
  type        = number
  default     = 1
}

variable "gateway_max_instances" {
  description = "Upper bound on gateway Cloud Run instances."
  type        = number
  default     = 10
}

variable "gateway_max_instance_request_concurrency" {
  description = "Concurrent requests one gateway instance handles before scaling out."
  type        = number
  default     = 80
}

variable "backend_cpu" {
  description = "Cloud Run CPU per backend instance (app container)."
  type        = string
  default     = "1000m"
}

variable "backend_memory" {
  description = "Cloud Run memory per backend instance (app container)."
  type        = string
  default     = "4Gi"
}

variable "backend_min_instances" {
  description = "Lower bound on backend Cloud Run instances."
  type        = number
  default     = 1
}

variable "backend_max_instances" {
  description = "Upper bound on backend Cloud Run instances."
  type        = number
  default     = 4
}

variable "backend_max_instance_request_concurrency" {
  description = "Concurrent requests one backend instance handles before scaling out."
  type        = number
  default     = 80
}

variable "ui_cpu" {
  description = "Cloud Run CPU per UI instance."
  type        = string
  default     = "1000m"
}

variable "ui_memory" {
  description = "Cloud Run memory per UI instance (Cloud Run rejects < 512Mi with always-allocated CPU)."
  type        = string
  default     = "512Mi"
}

variable "ui_min_instances" {
  description = "Lower bound on UI Cloud Run instances."
  type        = number
  default     = 1
}

variable "ui_max_instances" {
  description = "Upper bound on UI Cloud Run instances."
  type        = number
  default     = 3
}

variable "ui_max_instance_request_concurrency" {
  description = "Concurrent requests one UI instance handles before scaling out (static nginx, can be high)."
  type        = number
  default     = 200
}

variable "otel_collector_cpu" {
  description = "CPU for the OTel collector sidecar. Total per-instance CPU (app + sidecar) must be a Cloud Run-supported value (1, 2, 4, 6, 8)."
  type        = string
  default     = "1000m"
}

variable "otel_collector_memory" {
  description = "Memory for the OTel collector sidecar."
  type        = string
  default     = "512Mi"
}

# ---------- Cloud SQL (single instance — no read replica) ----------

variable "db_tier" {
  description = "Cloud SQL machine tier."
  type        = string
  default     = "db-custom-2-7680"
}

variable "db_edition" {
  description = "Cloud SQL edition. ENTERPRISE accepts db-custom-* / db-n1-* tiers."
  type        = string
  default     = "ENTERPRISE"

  validation {
    condition     = contains(["ENTERPRISE", "ENTERPRISE_PLUS"], var.db_edition)
    error_message = "db_edition must be ENTERPRISE or ENTERPRISE_PLUS."
  }
}

variable "db_availability_type" {
  description = "ZONAL (single zone, cheapest — the simplified default) or REGIONAL (in-region HA failover, no read replica)."
  type        = string
  default     = "ZONAL"

  validation {
    condition     = contains(["ZONAL", "REGIONAL"], var.db_availability_type)
    error_message = "db_availability_type must be ZONAL or REGIONAL."
  }
}

variable "db_version" {
  description = "Cloud SQL Postgres version."
  type        = string
  default     = "POSTGRES_16"
}

variable "db_name" {
  description = "Initial database created on the Cloud SQL instance."
  type        = string
  default     = "litellm"
}

variable "db_username" {
  description = "Application Postgres user (password-auth; password auto-generated into Secret Manager)."
  type        = string
  default     = "litellm_app"
}

variable "cloudsql_deletion_protection" {
  description = "Cloud SQL instance-level deletion protection. Set false for ephemeral / CI."
  type        = bool
  default     = true
}

variable "gcs_force_destroy" {
  description = "Allow `terraform destroy` to delete the GCS bucket even when non-empty. Set true only for ephemeral / CI."
  type        = bool
  default     = false
}

# ---------- Memorystore for Valkey ----------

variable "valkey_engine_version" {
  description = "Valkey engine version for the Memorystore instance."
  type        = string
  default     = "VALKEY_7_2"
}

variable "valkey_node_type" {
  description = "Memorystore Valkey node type (SHARED_CORE_NANO is the cheapest, fine for dev/test)."
  type        = string
  default     = "SHARED_CORE_NANO"
}

variable "valkey_shard_count" {
  description = "Number of shards. 1 = single-node (relaxed HA), matching the simplification goal."
  type        = number
  default     = 1
}

variable "valkey_replica_count" {
  description = "Replicas per shard. 0 keeps it single-node."
  type        = number
  default     = 0
}

variable "valkey_deletion_protection" {
  description = "Memorystore Valkey deletion protection. Set false for ephemeral / CI."
  type        = bool
  default     = true
}

# ---------- Load balancer / TLS ----------

variable "lb_domains" {
  description = "DNS names for a Google-managed SSL certificate fronting the LB. Empty disables TLS (combine with allow_plaintext_lb = true)."
  type        = list(string)
  default     = []
}

variable "allow_plaintext_lb" {
  description = "Opt into HTTP-only mode on the LB. `terraform plan` fails when lb_domains = [] unless this is true."
  type        = bool
  default     = false
}

# ---------- Extras / proxy_config ----------

variable "gateway_extra_env" {
  description = "Plain-text env vars layered onto the gateway."
  type        = map(string)
  default     = {}
}

variable "backend_extra_env" {
  description = "Plain-text env vars layered onto the backend."
  type        = map(string)
  default     = {}
}

variable "gateway_extra_secrets" {
  description = "Extra gateway env vars sourced from Secret Manager. Map of env-var name to secret resource ID."
  type        = map(string)
  default     = {}
}

variable "backend_extra_secrets" {
  description = "Same shape as gateway_extra_secrets, layered onto the backend."
  type        = map(string)
  default     = {}
}

variable "proxy_config" {
  description = "LiteLLM proxy config (contents of config.yaml). YAML-encoded, uploaded to GCS, mounted read-only into gateway + backend. Empty skips it."
  type        = any
  default     = {}
}

# ---------- OpenTelemetry (mandatory → GCP Cloud Trace + Cloud Monitoring) ----------
#
# OTel is always on. LiteLLM ships OTLP to a Google-built OpenTelemetry
# Collector sidecar on localhost, which exports traces to Cloud Trace and
# metrics to Cloud Monitoring using the Cloud Run service account.

variable "otel_exporter" {
  description = "LiteLLM OTLP exporter protocol pointed at the sidecar. otlp_http is the safe default."
  type        = string
  default     = "otlp_http"
  validation {
    condition     = contains(["otlp_http", "otlp_grpc"], var.otel_exporter)
    error_message = "otel_exporter must be otlp_http or otlp_grpc."
  }
}

variable "otel_environment_name" {
  description = "Value for OTEL_ENVIRONMENT_NAME (deployment.environment on every span). Defaults to var.env."
  type        = string
  default     = ""
}

variable "otel_capture_message_content" {
  description = "OTEL_INSTRUMENTATION_GENAI_CAPTURE_MESSAGE_CONTENT. Keep no_content unless you've audited what lands in your backend."
  type        = string
  default     = "no_content"
  validation {
    condition     = contains(["no_content", "prompt_and_completion"], var.otel_capture_message_content)
    error_message = "otel_capture_message_content must be no_content or prompt_and_completion."
  }
}

variable "otel_collector_image" {
  description = "Google-built OpenTelemetry Collector image for the Cloud Run sidecar."
  type        = string
  default     = "us-docker.pkg.dev/cloud-ops-agents-artifacts/google-cloud-opentelemetry-collector/otelcol-google:0.151.0"
}
