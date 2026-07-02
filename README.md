# gcp-llm-gateway

A simplified, replicable Terraform deployment of [LiteLLM](https://github.com/BerriAI/litellm)
on Google Cloud (Cloud Run + Cloud SQL + Memorystore Valkey + external HTTPS LB),
with mandatory OpenTelemetry wired to Cloud Trace and Cloud Monitoring.

## Layout

- [`terraform/`](./terraform) — the module + its [README](./terraform/README.md)
  (usage, prerequisites, tests).
- [`loadtest/`](./loadtest) — repeatable, config-driven k6 load/stress test on
  Cloud Run Jobs; see its [README](./loadtest/README.md) to run and re-configure.
- [`docs/ARCHITECTURE.md`](./docs/ARCHITECTURE.md) — heavily-visual architecture
  reference: components, network paths, request lifecycle, the Postgres/Valkey
  data model, and the security model (diagrams throughout).
- [`docs/OVERVIEW.md`](./docs/OVERVIEW.md) — concise visual overview (system context,
  containers, request lifecycle, data model, load-test), with a Structurizr C4 model
  in [`docs/workspace.dsl`](./docs/workspace.dsl).
- [`docs/DESIGN_DECISIONS.md`](./docs/DESIGN_DECISIONS.md) — why each choice in the
  current *simplified* architecture was made, with the production upgrade path.
- [`docs/PRODUCTION_READINESS.md`](./docs/PRODUCTION_READINESS.md) — roadmap and
  target architecture for high-resiliency, high-throughput, mission-critical
  deployments (diagrams, phasing, RTO/RPO, Google-first security).
- [`docs/UPDATING.md`](./docs/UPDATING.md) — how to upgrade the LiteLLM version
  safely: mechanics, risks, step-by-step runbook, rollback, and resilience tips.
- [`docs/PRICING.md`](./docs/PRICING.md) — what the gateway adds to your GCP bill:
  a fixed floor plus per-traffic cost across sample monthly profiles (grounded on
  GCP pricing; excludes Vertex model tokens, includes Model Armor).
- [`docs/LIMITATIONS.md`](./docs/LIMITATIONS.md) — OSS-first scope: which LiteLLM
  features are enterprise-only (e.g. Prometheus `/metrics` → Managed Prometheus)
  and Terraform provider gaps, with the GCP-native equivalents we use instead.
