workspace "Simplified LiteLLM on GCP" "C4 model: one model, systemContext + container views." {

  model {
    apiConsumer = person "API consumer / SDK" "Calls the OpenAI-compatible API with a bearer key."
    admin = person "Admin / operator" "Manages keys, teams, budgets and models via the admin UI/API."

    litellm = softwareSystem "LiteLLM Gateway on GCP" "OpenAI-compatible LLM gateway: auth, rate limiting, routing, spend tracking, telemetry." {
      lb = container "LB" "Global external HTTPS load balancer with URL-map path routing; TLS via nip.io or a custom domain." "GCP External HTTPS LB"
      gateway = container "gateway" "LLM data plane on :4000; /v1/*, /chat/*, /health*, provider passthroughs. App + OTel collector sidecar." "Cloud Run v2"
      backend = container "backend" "Management/control plane on :4001; /key/*, /user/*, /team/*, model CRUD, UI login API (default route). App + OTel collector sidecar." "Cloud Run v2"
      ui = container "ui" "Static admin dashboard (nginx) on :3000; runs under a zero-IAM service account." "Cloud Run v2"
      migrations = container "migrations Job" "Runs prisma migrate deploy against Cloud SQL before services go live." "Cloud Run Job"
      cloudsql = container "Cloud SQL" "Postgres: source of truth for keys, users, teams, budgets, spend ledger, models, config." "Cloud SQL Postgres" "Database"
      valkey = container "Valkey" "Memorystore Valkey over PSC: rate-limit counters, router cooldowns, auth cache, optional response cache." "Memorystore Valkey" "Database"
      secrets = container "Secret Manager" "Master key, DATABASE_URL, provider keys, OTel config; injected as secret env at boot." "Secret Manager"
      gcs = container "GCS" "Proxy config.yaml and file/request storage." "Cloud Storage"
      otel = container "OTel collector" "Sidecar receiving OTLP on localhost; exports traces to Cloud Trace and metrics to Cloud Monitoring." "OpenTelemetry Collector"
    }

    mirror = softwareSystem "Artifact Registry mirror" "Remote AR repository lazily mirroring ghcr.io/berriai/litellm-* images." "External"
    vertex = softwareSystem "Vertex AI" "Primary model backend (Gemini); reached keyless via the runtime service account (ADC)." "External"
    providers = softwareSystem "Other LLM providers" "OpenAI, Anthropic, etc.; reached with provider API keys." "External"
    observability = softwareSystem "Cloud Trace + Cloud Monitoring" "Traces and metrics backends." "External"

    # context-level
    apiConsumer -> litellm "Calls /v1/chat/completions with Bearer key" "HTTPS"
    admin -> litellm "Manages keys/teams/budgets/models" "HTTPS"
    litellm -> vertex "Chat completions, keyless" "HTTPS (ADC)"
    litellm -> providers "Chat completions" "HTTPS (API keys)"

    # container-level
    apiConsumer -> lb "POST /v1/chat/completions with Bearer key" "HTTPS"
    admin -> lb "Admin UI / API" "HTTPS"
    lb -> gateway "Data-plane paths: /v1/*, /chat/*, /health*" "HTTP"
    lb -> backend "Default route: management API" "HTTP"
    lb -> ui "UI asset paths: /, /ui, /_next/*" "HTTP"

    gateway -> cloudsql "Validate keys, record spend" "unix socket /cloudsql, IAM + mTLS"
    backend -> cloudsql "Key/user/team/model CRUD" "unix socket /cloudsql, IAM + mTLS"
    migrations -> cloudsql "prisma migrate deploy" "unix socket /cloudsql"
    gateway -> valkey "Rate-limit counters, cooldowns, auth cache" "Direct VPC egress -> PSC"
    backend -> valkey "Shared cache/coordination" "Direct VPC egress -> PSC"
    gateway -> secrets "Read secret env at boot" "secret_key_ref"
    backend -> secrets "Read secret env at boot" "secret_key_ref"
    gateway -> gcs "Read proxy config, store files" ""
    backend -> gcs "Read proxy config, store files" ""
    gateway -> otel "Emit spans/metrics" "OTLP localhost"
    backend -> otel "Emit spans/metrics" "OTLP localhost"
    otel -> observability "Export traces + metrics" "googlecloud / GMP"
    gateway -> vertex "Chat request, keyless" "HTTPS (ADC)"
    gateway -> providers "Chat request" "HTTPS (API keys)"

    litellm -> mirror "Pull container images" "HTTPS"
  }

  views {
    systemContext litellm "SystemContext" {
      include *
      autolayout lr
    }

    container litellm "Containers" {
      include *
      autolayout tb
    }

    theme default
  }
}
