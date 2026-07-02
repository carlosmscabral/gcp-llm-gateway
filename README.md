# gcp-llm-gateway

A simplified, replicable Terraform deployment of [LiteLLM](https://github.com/BerriAI/litellm)
on Google Cloud (Cloud Run + Cloud SQL + Memorystore Valkey + external HTTPS LB),
with mandatory OpenTelemetry wired to Cloud Trace and Cloud Monitoring.

## Layout

- [`terraform/`](./terraform) — the module + its [README](./terraform/README.md)
  (usage, prerequisites, tests).
- [`docs/DESIGN_DECISIONS.md`](./docs/DESIGN_DECISIONS.md) — why each choice in the
  current *simplified* architecture was made, with the production upgrade path.
- [`docs/PRODUCTION_READINESS.md`](./docs/PRODUCTION_READINESS.md) — roadmap and
  target architecture for high-resiliency, high-throughput, mission-critical
  deployments (diagrams, phasing, RTO/RPO, Google-first security).
