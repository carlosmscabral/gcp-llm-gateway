# Simplified LiteLLM on GCP (Terraform)

A leaner Terraform deployment of [LiteLLM](https://github.com/BerriAI/litellm) on
Google Cloud, derived from the upstream `terraform/litellm/gcp` reference but
stripped of the networking and HA machinery a single-region, moderate-scale
deployment doesn't need. Built to be **replicated per project/customer** with no
ad-hoc setup steps.

For the reasoning behind each choice see
[`../docs/DESIGN_DECISIONS.md`](../docs/DESIGN_DECISIONS.md); for the path to a
production/mission-critical posture see
[`../docs/PRODUCTION_READINESS.md`](../docs/PRODUCTION_READINESS.md).

## What's simplified vs. upstream

| Concern | Upstream | Here |
|---|---|---|
| Cloud Run → Cloud SQL | Private IP via Serverless VPC connector | **Native Cloud SQL connector** (unix socket `/cloudsql/<conn>`) — no VPC, no PSA |
| Cloud Run → cache | Private IP via Serverless VPC connector | **Direct VPC egress** into a minimal subnet |
| Serverless VPC connector + PSA peering | Present | **Removed** |
| Postgres | Primary + cross-zone read replica | **Single instance** (`db_availability_type` ZONAL/REGIONAL) |
| Cache | Memorystore **Redis** STANDARD_HA, private IP + TLS | **Memorystore Valkey**, single node, private PSC endpoint |
| OpenTelemetry | Optional, arbitrary OTLP endpoint | **Mandatory**, Google-built OTel Collector sidecar → **Cloud Trace + Cloud Monitoring** |
| Images | Assumes reachable registry | **Artifact Registry remote mirror** of ghcr.io, created automatically |
| APIs | Manual enable | Enabled in Terraform (`google_project_service`) |

---

# Part 1 — User Guide (deploy the gateway)

## 1.1 Prerequisites

**Tools (local):**
- [Terraform](https://developer.hashicorp.com/terraform/install) ≥ 1.6
- [Google Cloud CLI](https://cloud.google.com/sdk/docs/install) (`gcloud`)
- `curl`, `python3` (for the smoke test)

**GCP:**
- A **project with billing enabled**. You can create one:
  ```bash
  gcloud projects create MY_PROJECT_ID --name="my-llm-gateway"
  gcloud billing projects link MY_PROJECT_ID --billing-account=XXXXXX-XXXXXX-XXXXXX
  ```
- Your user needs enough rights to create the resources — **Owner**, or the
  combination of Editor + Project IAM Admin + Service Usage Admin.
- **Authenticate Application Default Credentials** (Terraform and the migration
  step use these):
  ```bash
  gcloud auth application-default login
  gcloud config set project MY_PROJECT_ID
  ```
- **Bootstrap the two APIs Terraform needs to manage the rest** (one-time; the
  module enables every other API itself):
  ```bash
  gcloud services enable serviceusage.googleapis.com \
    cloudresourcemanager.googleapis.com --project=MY_PROJECT_ID
  ```

> **Images:** the LiteLLM images live on `ghcr.io`, which Cloud Run cannot pull
> directly. The module creates an **Artifact Registry remote repository** that
> mirrors them automatically on first pull — nothing to do manually.

## 1.2 Configure your deployment

```bash
cd terraform
cp examples/terraform.tfvars.example dev.tfvars   # then edit
```

Minimum values to set in `dev.tfvars`:

```hcl
project_id = "MY_PROJECT_ID"
region     = "us-central1"
tenant     = "acme"     # 1-21 chars, lower-kebab, resource name prefix
env        = "dev"      # 1-9 chars, lower-kebab

# Trial stack: no custom domain → serve HTTP on the LB IP.
allow_plaintext_lb = true

# Cheapest / disposable footprint for a test project:
db_availability_type         = "ZONAL"
cloudsql_deletion_protection = false
valkey_deletion_protection   = false
gcs_force_destroy            = true
```

All other inputs have sensible defaults — see `variables.tf`.

## 1.3 Deploy

```bash
terraform init
terraform plan  -var-file=dev.tfvars      # review: ~58 resources, 0 to destroy
terraform apply -var-file=dev.tfvars
```

What happens during apply (~15–25 min the first time):
1. APIs enabled, VPC/subnets, Secret Manager, IAM, and the image mirror.
2. Cloud SQL (~3–5 min) and Memorystore Valkey (~5–8 min) provision.
3. The **migration Cloud Run Job runs automatically** (`prisma migrate deploy`)
   via a `local-exec` that calls `gcloud run jobs execute --wait`.
4. Gateway, backend, and UI roll out (each pulling images through the mirror and
   starting its OTel collector sidecar), then the load balancer.

## 1.4 Basic checks

```bash
# Outputs (LB URL, service URLs, secret IDs, valkey endpoint, migration cmd)
terraform output

# The three Cloud Run services should be Ready=True
for s in gateway backend ui; do
  gcloud run services describe "$(terraform output -raw project_id | sed 's/.*//')cabral-litellm-dev-$s" >/dev/null 2>&1 || true
done
gcloud run services list --project="$(terraform output -raw project_id)" --region="$(terraform output -raw region 2>/dev/null || echo us-central1)"

# Load balancer health (LB can take a few minutes to warm; retry until 200)
curl -s -o /dev/null -w '%{http_code}\n' "$(terraform output -raw lb_url)/health/liveliness"

# Fetch the auto-generated master key when you need it
gcloud secrets versions access latest \
  --secret="$(terraform output -raw master_key_secret_id)" \
  --project="$(terraform output -raw project_id)"
```

- **LB URL / IP:** `terraform output lb_url`
- **UI:** open the `lb_url` in a browser (login user `admin`, password =
  `ui_password` if set, otherwise the master key)
- **Traces/metrics:** Cloud Trace + Cloud Monitoring (once LiteLLM emits — see
  the follow-up note at the end)

## 1.5 TLS and the endpoint URL

TLS is **on by default with no DNS setup**. The module reserves a static LB IP,
derives the hostname **`<lb-ip>.nip.io`** from it (nip.io resolves that name back
to the IP), and provisions a **Google-managed certificate** for it. `terraform
output lb_url` gives you the URL, e.g. `https://8.228.234.166.nip.io`.

Because the hostname is derived from the Terraform-managed IP, a **fresh apply
needs no prior knowledge of the address** — Terraform reserves the IP, then
builds the domain and cert from it, in order, in one apply.

One consequence of Google-managed certs: they provision **asynchronously**. The
`apply` returns while the cert is still `PROVISIONING` (~10–15 min). During that
window HTTPS (443) isn't serving yet and port 80 redirects to it, so requests
fail until the cert is `ACTIVE`. Watch it:

```bash
gcloud compute ssl-certificates list --project="$(terraform output -raw project_id)" \
  --format="table(name,managed.status,managed.domainStatus)"
# wait until MANAGED_STATUS = ACTIVE, then:
./examples/smoke-test.sh
```

**Options:**
- **Bring your own domain:** set `lb_domains = ["gw.example.com"]` and point a DNS
  A record at the `lb_ip` output. These override nip.io.
- **HTTP-only (quick trial):** set `allow_plaintext_lb = true` — no cert, serves
  plain HTTP on the IP (`lb_url` becomes `http://<ip>`).

> nip.io is a public convenience DNS service — great for dev, **not for
> production**. For prod use your own domain (and add Cloud Armor + an SSL policy
> — see [`../docs/PRODUCTION_READINESS.md`](../docs/PRODUCTION_READINESS.md) §4.4).

## 1.6 Tear down

```bash
terraform destroy -var-file=dev.tfvars
```

(Deletion protection is off in the example `dev.tfvars`; in real environments
keep it on.)

---

# Part 2 — Configuring LiteLLM (with Vertex AI)

## 2.1 How configuration is layered in this deployment

LiteLLM is configured two ways, and both are already wired here:

1. **Server settings — via environment (managed by Terraform):**
   - `LITELLM_MASTER_KEY` — auto-generated `sk-…`, stored in Secret Manager
     (override with `litellm_master_key`).
   - `DATABASE_URL` — assembled and injected as a secret.
   - `STORE_MODEL_IN_DB=true` (backend) — lets you add models at runtime via the
     Admin UI/API, persisted in Postgres.
   - `UI_PASSWORD` — set via `ui_password`.
   - OpenTelemetry — always on, shipping to the collector sidecar.

2. **Models & `config.yaml` — via the `proxy_config` variable:** whatever you put
   in `proxy_config` is YAML-encoded, uploaded to a private GCS bucket, and
   mounted read-only into gateway + backend at `/etc/litellm/config.yaml`. A
   content hash forces a new revision when it changes. This is the **declarative,
   IaC-friendly** way to manage models.

> You can *also* add models at runtime in the **Admin UI** (Models → Add Model)
> or via the `/model/new` API — those persist in the DB because
> `STORE_MODEL_IN_DB=true`. Use `proxy_config` for anything you want captured in
> source control.

## 2.2 A minimal config

The smallest useful `proxy_config` is a single model. A mock model (no provider
needed) is handy to prove the path end-to-end:

```hcl
proxy_config = {
  model_list = [
    {
      model_name = "mock-gpt"
      litellm_params = {
        model         = "gpt-3.5-turbo"
        mock_response = "Hello from the mock model!"
      }
    }
  ]
}
```

## 2.3 Targeting Vertex AI (Gemini) — the "easy button"

Vertex AI is the primary target and is **on by default** (`enable_vertex_ai =
true`). With no extra configuration, `terraform apply` will:

- enable `aiplatform.googleapis.com`,
- grant the Cloud Run runtime SA **`roles/aiplatform.user`**, and
- **auto-register the models in `vertex_gemini_models`** (default
  `gemini-3.5-flash`, `gemini-3.1-pro-preview`) pointed at **your** project, on
  the Vertex **`global`** endpoint by default.

On GCP, LiteLLM authenticates to Vertex with **Application Default Credentials**
— the runtime SA — so **there is no service-account key file anywhere**. A bare
deploy comes up serving Gemini; callers just use the model name (e.g.
`gemini-3.5-flash`). Nothing else to write.

**Customize the model set** (optional) in `dev.tfvars`:

```hcl
enable_vertex_ai     = true                                       # default
vertex_gemini_models = ["gemini-3.5-flash", "gemini-3.1-pro-preview"]
vertex_location      = "global"                                   # default; or a region like us-central1
```

Each entry becomes a callable model (`model_name` = the ID) routed to
`vertex_ai/<id>` with `vertex_project = project_id`, `vertex_location`, and no
credentials (ADC). To **add your own models** (or providers), keep using
`proxy_config.model_list` — those are merged with the auto-registered ones:

```hcl
proxy_config = {
  model_list = [
    { model_name = "mock-gpt", litellm_params = { model = "gpt-3.5-turbo", mock_response = "hi" } }
  ]
}
```

**Notes**
- Models are routed with the **`vertex_ai/`** prefix (Vertex REST API + ADC),
  *not* `gemini/` (which is the API-key-based Gemini API).
- **Location:** the default `global` endpoint is recommended for Gemini and
  avoids per-region availability gaps. Set `vertex_location` to a specific region
  (e.g. `us-central1`) only if you need data locality. List regional models with:
  ```bash
  gcloud ai models list --region=us-central1 --project=MY_PROJECT_ID 2>/dev/null | head
  ```
- **Model Garden / "Agent Platform" partner models** (Anthropic Claude, Llama,
  etc. hosted in Vertex) use the same provider and the same keyless ADC auth —
  just add their IDs to `vertex_gemini_models`, e.g.
  `claude-sonnet-4@20250514` → routed as `vertex_ai/claude-sonnet-4@20250514`.
  (Vertex AI *Agent Engine/Builder* agents are a different API, not proxied as
  `/chat/completions` models.)
- To disable Vertex entirely, set `enable_vertex_ai = false`.

## 2.4 Test the whole flow

Use the included script (from the `terraform/` directory, after `apply`). It
defaults to `gemini-3.5-flash`:

```bash
./examples/smoke-test.sh                 # or: ./examples/smoke-test.sh gemini-3.1-pro-preview
```

It reads the LB URL, project, and master key from Terraform/Secret Manager, then
runs a liveness check, lists models, and makes a real chat completion. Expected:

```
[1/3] GET /health/liveliness
      -> HTTP 200
[2/3] GET /v1/models
      models: ['gemini-3.5-flash', 'gemini-3.1-pro-preview', 'mock-gpt']
[3/3] POST /v1/chat/completions  (model=gemini-3.5-flash)
      model : gemini-3.5-flash
      reply : gateway ok
      usage : {'prompt_tokens': ..., 'completion_tokens': ..., 'total_tokens': ...}

SMOKE TEST PASSED
```

Equivalent raw `curl` (LB URL + master key):

```bash
BASE_URL=$(terraform output -raw lb_url)
MK=$(gcloud secrets versions access latest \
      --secret="$(terraform output -raw master_key_secret_id)" \
      --project="$(terraform output -raw project_id)")

# List configured models
curl -s -H "Authorization: Bearer $MK" "$BASE_URL/v1/models"

# Chat completion against Vertex
curl -s -H "Authorization: Bearer $MK" -H "Content-Type: application/json" \
  -d '{"model":"gemini-3.5-flash","messages":[{"role":"user","content":"hello"}]}' \
  "$BASE_URL/v1/chat/completions"
```

---

# Part 3 — Safety & observability (GCP-first)

## 3.1 Model Armor guardrail (LLM safety)

Enable Google Cloud **Model Armor** — prompt-injection/jailbreak, PII/SDP, and
malicious-URL screening — as a native LiteLLM guardrail, authenticated keyless via
the runtime SA (ADC):

```hcl
enable_model_armor      = true            # creates a Model Armor template + grants modelarmor.user
model_armor_enforcement = "INSPECT_ONLY"  # observe + log (default) or INSPECT_AND_BLOCK
model_armor_default_on  = false           # false = opt-in per request; true = every request
model_armor_mode        = ["pre_call"]    # scan prompt (add "post_call" to scan responses)
# model_armor_multi_language = true        # multi-language detection (default on)
```

- **Sampling:** LiteLLM has no percentage sampler. Use `model_armor_default_on = true`
  for 100%, or leave it `false` and opt in per request with
  `{"guardrails": ["model-armor"], ...}` in the body.
- **Filter version:** the provider doesn't expose it; the API defaults to the
  **Stable** alias (what the template uses).
- Test it: send a request with `"guardrails": ["model-armor"]`; under `INSPECT_ONLY`
  it returns 200 and logs findings. See Model Armor tiles on the dashboard (§3.2).

## 3.2 Cloud Monitoring dashboard, alerts, uptime

On by default (`enable_monitoring = true`), built from **GCP-native** metrics (no
LiteLLM license needed):

- A dashboard (`terraform output monitoring_dashboard_url`): gateway request rate /
  p95 latency / 5xx / instances, Cloud SQL connections + CPU, Valkey CPU, and Model
  Armor filter counts (when enabled).
- Alert policies: gateway p95 latency, Cloud SQL connections, uptime failing
  (attach channels via `alert_notification_channels`).
- An uptime check on the LB `/health/liveliness`.

LLM-native metrics (LiteLLM `/metrics` → Managed Prometheus) are **enterprise-gated**
and out of scope for the OSS build — see [`../docs/LIMITATIONS.md`](../docs/LIMITATIONS.md).

## Terraform tests

```bash
terraform test        # plan-mode assertions with mocked providers (no cloud calls)
```

## Known follow-up: LiteLLM OTEL emission

The GCP telemetry pipeline is verified working — the Google-built OTel Collector
sidecar runs on gateway + backend, receives OTLP on `localhost:4317/4318`, and
exports traces to **Cloud Trace** and metrics to **Cloud Monitoring** with the
correct IAM (`roles/cloudtrace.agent`, `roles/monitoring.metricWriter`).

However, the split `litellm-gateway:v1.86.0-dev` staging image does **not emit
any OTLP**, and we confirmed this is an **image limitation, not config**:

- The module enables the OSS OTEL integration correctly — `litellm_settings:
  callbacks: ["otel"]` is in the mounted `config.yaml`, with
  `OTEL_EXPORTER=otlp_http` and `OTEL_ENDPOINT=http://localhost:4318`.
- With that config and **successful real-model calls**, the app logs show **no
  OTLP export attempt** and **no spans reach Cloud Trace** (only Cloud Run/GFE
  platform samples like `/health` and Cloud SQL Query Insights spans appear).
  The `otel` callback loads as a silent no-op — the slimmed split image appears
  to omit the OpenTelemetry instrumentation.

**To get traces, change the image** (the config is already right): a stable
LiteLLM release tag, or the non-split `litellm` image. The moment LiteLLM emits,
spans flow to Cloud Trace with no other change — the collector sidecar is healthy
and ready.

> Note: the collector sidecar consumes ~1 vCPU per gateway/backend instance. While
> LiteLLM isn't emitting, that's overhead for no telemetry — consider right-sizing
> the app/collector CPU split or gating the sidecar until an emitting image is used.

## GCP Developer Knowledge MCP

This repo ships an `.mcp.json` for the Google Developer Knowledge MCP server.
It reads a bearer token from `$GCP_ACCESS_TOKEN` (ADC tokens expire hourly):

```bash
export GCP_ACCESS_TOKEN=$(gcloud auth application-default print-access-token)
```
