# Simplified LiteLLM on GCP (Terraform)

A leaner Terraform deployment of [LiteLLM](https://github.com/BerriAI/litellm) on
Google Cloud, derived from the upstream
`terraform/litellm/gcp` reference but stripped of the networking and HA
machinery a single-region, moderate-scale deployment doesn't need.

## What's simplified vs. upstream

| Concern | Upstream | Here |
|---|---|---|
| Cloud Run → Cloud SQL | Private IP via Serverless VPC connector | **Native Cloud SQL connector** (unix socket `/cloudsql/<conn>`) — no VPC, no PSA, DB not internet-exposed |
| Cloud Run → cache | Private IP via Serverless VPC connector | **Direct VPC egress** into a minimal subnet |
| Serverless VPC connector + PSA peering | Present | **Removed** |
| Postgres | Primary + cross-zone read replica | **Single instance** (`db_availability_type` ZONAL/REGIONAL) |
| Cache | Memorystore **Redis** STANDARD_HA, private IP + TLS | **Memorystore Valkey**, single node, private PSC endpoint |
| OpenTelemetry | Optional, arbitrary OTLP endpoint | **Mandatory**, Google-built OTel Collector sidecar → **Cloud Trace + Cloud Monitoring** |
| Ingress | External HTTPS LB | Same (toggle TLS via `lb_domains` / `allow_plaintext_lb`) |

## Prerequisites

- `terraform >= 1.6`, `gcloud` authenticated (`gcloud auth application-default login`).
- A project with billing enabled and these APIs on: `run`, `sqladmin`,
  `memorystore`, `compute`, `secretmanager`, `storage`, `cloudtrace`,
  `monitoring`, `networkconnectivity`, `servicenetworking` (for PSC automation),
  `artifactregistry`.
- LiteLLM images reachable by Cloud Run (Artifact Registry or a remote repo
  mirroring `ghcr.io/berriai`). See `image_registry` / `*_image`.

## Usage

```bash
cd terraform
cp examples/terraform.tfvars.example dev.tfvars   # edit values
terraform init
terraform plan  -var-file=dev.tfvars
terraform apply -var-file=dev.tfvars
```

Observability: traces land in **Cloud Trace**, metrics in **Cloud Monitoring**
(Managed Service for Prometheus), tagged with `OTEL_ENVIRONMENT_NAME`.

## Tests

```bash
terraform test        # plan-mode assertions with mocked providers (no cloud calls)
```

## Known follow-up: LiteLLM OTEL emission

The GCP telemetry pipeline is verified working — the Google-built OTel Collector
sidecar runs on gateway + backend, receives OTLP on `localhost:4317/4318`, and
exports traces to **Cloud Trace** and metrics to **Cloud Monitoring** with the
correct IAM (`roles/cloudtrace.agent`, `roles/monitoring.metricWriter`).

However, the split `litellm-gateway:v1.86.0-dev` staging image does **not emit
any OTLP** despite the documented config (`LITELLM_OTEL_V2=true`,
`OTEL_EXPORTER=otlp_http`, `OTEL_ENDPOINT=http://localhost:4318`) — its startup
logs show no OpenTelemetry initialization. This is an application/image-version
issue, not an infra one. To resolve, try (in order):

1. A stable LiteLLM release tag instead of `-dev` (`image_tag`).
2. Adding standard OTel SDK env vars via `gateway_extra_env` / `backend_extra_env`:
   `OTEL_EXPORTER_OTLP_ENDPOINT=http://localhost:4318`, `OTEL_TRACES_EXPORTER=otlp`.
3. The non-split `litellm` image.

The moment LiteLLM sends spans, they will flow to Cloud Trace with no infra change.

## GCP Developer Knowledge MCP

This repo ships an `.mcp.json` for the Google Developer Knowledge MCP server.
It reads a bearer token from `$GCP_ACCESS_TOKEN` (ADC tokens expire hourly):

```bash
export GCP_ACCESS_TOKEN=$(gcloud auth application-default print-access-token)
```
