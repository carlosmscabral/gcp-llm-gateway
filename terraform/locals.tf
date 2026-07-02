locals {
  # Every resource is named `${tenant}-litellm-${env}` (plus a per-resource
  # suffix where needed).
  name = "${var.tenant}-litellm-${var.env}"

  labels = merge(
    {
      "litellm-stack" = local.name
      "managed-by"    = "terraform"
    },
    var.labels,
  )

  # ---------- Memorystore Valkey endpoint ----------
  # The PSC endpoint IP/port are allocated by service connectivity automation.
  # `psc_auto_connections` is the stable read path today; fall back to the
  # newer nested `endpoints` shape if a future provider drops it.
  valkey_host = try(
    google_memorystore_instance.this.psc_auto_connections[0].ip_address,
    google_memorystore_instance.this.endpoints[0].connections[0].psc_auto_connection[0].ip_address,
  )
  valkey_port = try(google_memorystore_instance.this.psc_auto_connections[0].port, 6379)

  # ---------- Image URIs ----------
  # Prefix precedence: explicit image_registry > built-in AR mirror > raw
  # upstream (last one won't pull on Cloud Run — surfaces the misconfig).
  image_prefix = var.image_registry != "" ? var.image_registry : (
    local.image_mirror_enabled ? "${var.region}-docker.pkg.dev/${var.project_id}/${local.mirror_repo_id}/${var.image_mirror_upstream_path}" : "ghcr.io/${var.image_mirror_upstream_path}"
  )

  # Load-test k6 image, hosted in the STANDARD load-test AR repo (not the ghcr mirror).
  loadtest_repo_id = "${local.name}-loadtest"
  k6_image         = var.k6_image != "" ? var.k6_image : "${var.region}-docker.pkg.dev/${var.project_id}/${local.loadtest_repo_id}/k6:latest"

  gateway_image    = var.gateway_image != "" ? var.gateway_image : "${local.image_prefix}/litellm-gateway:${var.image_tag}"
  backend_image    = var.backend_image != "" ? var.backend_image : "${local.image_prefix}/litellm-backend:${var.image_tag}"
  ui_image         = var.ui_image != "" ? var.ui_image : "${local.image_prefix}/litellm-ui:${var.image_tag}"
  migrations_image = var.migrations_image != "" ? var.migrations_image : "${local.image_prefix}/litellm-migrations:${var.image_tag}"

  # ---------- Vertex AI auto-registered models ("easy button") ----------
  # One model_list entry per vertex_gemini_models ID, keyless (ADC), pointed at
  # this project + location. Merged ahead of any user-supplied model_list.
  vertex_location = var.vertex_location != "" ? var.vertex_location : var.region
  vertex_auto_models = var.enable_vertex_ai ? [
    for m in var.vertex_gemini_models : {
      model_name = m
      litellm_params = {
        model           = "vertex_ai/${m}"
        vertex_project  = var.project_id
        vertex_location = local.vertex_location
      }
    }
  ] : []

  # ---------- proxy_config (config.yaml) ----------
  # Effective config = user proxy_config with the auto Vertex models prepended
  # to its model_list. Lets a bare deploy serve Gemini with no proxy_config set.
  user_model_list      = try(var.proxy_config.model_list, [])
  effective_model_list = concat(local.vertex_auto_models, local.user_model_list)
  effective_proxy_config = length(local.effective_model_list) > 0 ? merge(
    var.proxy_config, { model_list = local.effective_model_list }
  ) : var.proxy_config

  proxy_config_enabled    = length(keys(local.effective_proxy_config)) > 0
  proxy_config_yaml       = local.proxy_config_enabled ? yamlencode(local.effective_proxy_config) : ""
  proxy_config_mount_path = "/etc/litellm"
  proxy_config_file_name  = "config.yaml"
  proxy_config_volume     = "proxy-config"

  proxy_config_env = local.proxy_config_enabled ? [
    { name = "CONFIG_FILE_PATH", value = "${local.proxy_config_mount_path}/${local.proxy_config_file_name}" },
    # Forces a new revision when the YAML changes (gcsfuse only surfaces the
    # new object on container restart).
    { name = "PROXY_CONFIG_HASH", value = md5(local.proxy_config_yaml) },
  ] : []

  # ---------- OpenTelemetry (mandatory) ----------
  otel_environment_name = var.otel_environment_name != "" ? var.otel_environment_name : var.env
  otel_local_endpoint   = var.otel_exporter == "otlp_grpc" ? "http://localhost:4317" : "http://localhost:4318"

  # LiteLLM always ships OTLP to the in-pod collector sidecar.
  otel_shared_env_kv = [
    { name = "LITELLM_OTEL_V2", value = "true" },
    { name = "OTEL_EXPORTER", value = var.otel_exporter },
    { name = "OTEL_ENDPOINT", value = local.otel_local_endpoint },
    { name = "OTEL_ENVIRONMENT_NAME", value = local.otel_environment_name },
    { name = "OTEL_INSTRUMENTATION_GENAI_CAPTURE_MESSAGE_CONTENT", value = var.otel_capture_message_content },
  ]
  gateway_otel_env_kv_raw = concat(local.otel_shared_env_kv, [
    { name = "OTEL_SERVICE_NAME", value = "${local.name}-gateway" },
  ])
  backend_otel_env_kv_raw = concat(local.otel_shared_env_kv, [
    { name = "OTEL_SERVICE_NAME", value = "${local.name}-backend" },
  ])
  # A caller-supplied OTEL_* in *_extra_env wins (Cloud Run rejects duplicate
  # env names).
  gateway_otel_env_kv = [
    for e in local.gateway_otel_env_kv_raw : e if !contains(keys(var.gateway_extra_env), e.name)
  ]
  backend_otel_env_kv = [
    for e in local.backend_otel_env_kv_raw : e if !contains(keys(var.backend_extra_env), e.name)
  ]

  # Google-built OpenTelemetry Collector config. Receives OTLP on localhost and
  # exports traces → Cloud Trace, metrics → Cloud Monitoring (Managed Service
  # for Prometheus). Auth is the Cloud Run runtime service account (ADC).
  otel_collector_config_yaml = <<-YAML
    receivers:
      otlp:
        protocols:
          grpc:
            endpoint: localhost:4317
          http:
            endpoint: localhost:4318
    processors:
      batch:
        send_batch_size: 200
        timeout: 5s
      memory_limiter:
        check_interval: 1s
        limit_percentage: 65
        spike_limit_percentage: 20
      resourcedetection:
        detectors: [gcp]
        timeout: 10s
    exporters:
      googlecloud: {}
      googlemanagedprometheus: {}
    extensions:
      health_check:
        endpoint: 0.0.0.0:13133
    service:
      extensions: [health_check]
      pipelines:
        traces:
          receivers: [otlp]
          processors: [resourcedetection, memory_limiter, batch]
          exporters: [googlecloud]
        metrics:
          receivers: [otlp]
          processors: [resourcedetection, memory_limiter, batch]
          exporters: [googlemanagedprometheus]
  YAML

  # ---------- Container env ----------
  # DATABASE_URL is delivered as a secret (assembled in cloudsql.tf), so no
  # runtime shell assembly is needed. Valkey has TLS/auth disabled on a private
  # PSC path, so REDIS_SSL is false and there is no CA-cert plumbing.
  shared_env_kv = [
    { name = "REDIS_HOST", value = local.valkey_host },
    { name = "REDIS_PORT", value = tostring(local.valkey_port) },
    { name = "REDIS_SSL", value = "false" },
    { name = "GCS_BUCKET_NAME", value = google_storage_bucket.this.name },
  ]

  backend_default_env_kv = [
    { name = "STORE_MODEL_IN_DB", value = "true" },
  ]

  gateway_extra_env_kv = [for k, v in var.gateway_extra_env : { name = k, value = v }]
  backend_extra_env_kv = [for k, v in var.backend_extra_env : { name = k, value = v }]

  # Secret env vars (value_source.secret_key_ref).
  shared_env_secrets = concat(
    [
      { name = "LITELLM_MASTER_KEY", secret = google_secret_manager_secret.master_key.id, version = "latest" },
      { name = "DATABASE_URL", secret = google_secret_manager_secret.db_url.id, version = "latest" },
    ],
    var.litellm_license == "" ? [] : [
      { name = "LITELLM_LICENSE", secret = google_secret_manager_secret.license[0].id, version = "latest" },
    ],
  )

  backend_managed_env_secrets = var.ui_password == "" ? [] : [
    { name = "UI_PASSWORD", secret = google_secret_manager_secret.ui_password[0].id, version = "latest" },
  ]

  gateway_extra_secret_kv = [for k, v in var.gateway_extra_secrets : { name = k, secret = v, version = "latest" }]
  backend_extra_secret_kv = [for k, v in var.backend_extra_secrets : { name = k, secret = v, version = "latest" }]

  # The migration job assembles nothing — it consumes DATABASE_URL directly.
  migrations_env_secrets = [
    { name = "DATABASE_URL", secret = google_secret_manager_secret.db_url.id, version = "latest" },
  ]

  # Startup commands. No DB/Redis assembly fragments — DATABASE_URL is injected
  # as a secret and Valkey needs no CA file.
  gateway_args = "exec uvicorn gateway.main:app --host 0.0.0.0 --port 4000 --workers ${var.gateway_num_workers}"
  backend_args = "exec uvicorn backend.main:app --host 0.0.0.0 --port 4001"

  # ---------- URL map path routing (mirrors the helm ingress) ----------
  gateway_path_prefixes = [
    "/v1/chat/*", "/chat/*",
    "/v1/completions*", "/completions*",
    "/v1/embeddings*", "/embeddings*",
    "/v1/moderations*", "/moderations*",
    "/v1/audio/*", "/audio/*",
    "/v1/images/*", "/images/*",
    "/v1/files*", "/files*",
    "/v1/batches*", "/batches*",
    "/v1/fine_tuning/*", "/fine_tuning/*",
    "/v1/fine-tuning/*", "/fine-tuning/*",
    "/v1/responses*", "/responses*",
    "/v1/threads*", "/threads*",
    "/v1/assistants*", "/assistants*",
    "/v1/vector_stores*", "/vector_stores*",
    "/v1/indexes*",
    "/v1/models*", "/models*",
    "/openai/*", "/engines/*",
    "/v1/messages*", "/messages*",
    "/v1/skills/*", "/v1/a2a/*",
    "/v1/rerank*", "/v2/rerank*", "/rerank*",
    "/v1/ocr*", "/ocr*",
    "/v1/rag/*", "/rag/*",
    "/v1/video/*", "/v1/videos/*", "/video/*", "/videos/*",
    "/v1/search*", "/search*",
    "/v1/containers/*", "/containers/*",
    "/v1/evals/*",
    "/v1/memory/*",
    "/queue/chat/*",
    "/v1beta/*",
    "/interactions/*",
    "/anthropic/*", "/azure/*", "/azure_ai/*", "/aws/*", "/bedrock/*",
    "/cohere/*", "/gemini/*", "/google/*",
    "/vertex_ai/*", "/vertex-ai/*",
    "/assemblyai/*", "/eu.assemblyai/*",
    "/langfuse/*", "/vllm/*",
    "/mistral/*", "/groq/*", "/voyage/*", "/cursor/*", "/milvus/*",
    "/openai_passthrough/*",
    "/toolset/*",
    "/v1/realtime*", "/realtime*",
    "/health*", "/metrics", "/test*",
  ]

  ui_path_prefixes = [
    "/",
    "/favicon.ico",
    "/litellm-asset-prefix/*",
    "/_next/*",
    "/assets/*",
    "/ui",
    "/ui/*",
  ]
}
