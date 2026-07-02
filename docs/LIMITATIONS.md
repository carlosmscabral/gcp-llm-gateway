# Scope & limitations (OSS-first)

This deployment targets the **open-source LiteLLM distribution**. Some LiteLLM
capabilities are **enterprise-only**, and a few GCP features aren't yet exposed by
the Terraform provider. We deliberately avoid depending on those, and use
GCP-native equivalents where possible. This file records what we don't rely on and
why, so the module stays fully functional on OSS.

## LiteLLM enterprise-only features (not used here)

| Feature | Status | What we do instead |
|---|---|---|
| **Prometheus `/metrics` → Managed Prometheus** (`callbacks: ["prometheus"]` — LLM-native spend/token/per-key/per-team metrics) | **Enterprise** | Use **GCP-native Cloud Monitoring** metrics (Cloud Run request rate/latency/instances, Cloud SQL connections/CPU, Valkey CPU) **plus Model Armor metrics**, all on one dashboard. No license needed. |
| **Model-level guardrail attachment** (`guardrails: [...]` on a specific `model_list` entry) | **Enterprise** | Apply Model Armor **globally** (`model_armor_default_on = true`) or **per-request** (`guardrails: ["model-armor"]` in the request body). |
| **Deep UI white-labeling** (custom admin-UI logo/colors) | **Enterprise** | Custom **domain** (LB + managed cert), docs/Swagger title, `ROOT_REDIRECT_URL`, and assets from GCS/CDN. |
| **SSO / SCIM group sync** for the admin UI | **Enterprise** | Master key / `UI_PASSWORD` today; **IAP + Google SSO** is the production path (see PRODUCTION_READINESS.md §4.5). |

> The Managed-Prometheus path is intentionally **out of scope** for the OSS build.
> If you hold a LiteLLM enterprise license, it's a small add-on: set
> `callbacks: ["prometheus"]` in `proxy_config`, add a Prometheus receiver to the
> OTel sidecar scraping `localhost:<app-port>/metrics`, and export via the
> collector's existing `googlemanagedprometheus` exporter (the runtime SA already
> has `roles/monitoring.metricWriter`).

## Terraform provider gaps (google ~> 6.x)

| Feature | Status | Handling |
|---|---|---|
| Model Armor **filter version** (the "Stable" alias in the console) | **Not exposed** by `google_model_armor_template` | The Model Armor **API defaults to Stable**, so our templates use Stable filters by default. Pin explicitly only via API/gcloud if ever required. |
| Model Armor **multi-language detection** | **Exposed** | Enabled by default (`model_armor_multi_language = true`). |
| Memorystore Valkey endpoint attribute | `psc_auto_connections` marked deprecated | Read with a `try(...)` fallback to the newer `endpoints` shape. |

## What this means

- Every feature in this module works on **OSS LiteLLM** with GCP-native services.
- Observability, cost signals, and **Model Armor safety** don't require a LiteLLM
  license — they lean on Cloud Monitoring, Cloud Logging, and Model Armor.
- Enterprise-only niceties are documented as **optional upgrades**, not
  prerequisites.

See also: [`ARCHITECTURE.md`](./ARCHITECTURE.md) (security/observability),
[`DESIGN_DECISIONS.md`](./DESIGN_DECISIONS.md), and
[`PRODUCTION_READINESS.md`](./PRODUCTION_READINESS.md).
