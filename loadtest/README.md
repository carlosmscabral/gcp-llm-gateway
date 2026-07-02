# Load / stress test harness

Repeatable, config-driven load testing of the deployed LiteLLM gateway using
**k6 on Cloud Run Jobs**. Bulk traffic uses the zero-cost `mock-gpt` model to
stress the gateway/DB/Valkey; a small profile hits real `gemini-3.5-flash`.
Purpose-built virtual keys exercise LiteLLM's rate-limit / budget / model-ACL
enforcement. Results come from k6 **and** Cloud Monitoring (Cloud Run, Cloud SQL,
Memorystore Valkey).

## How it works

```
run.sh → build (once)   Cloud Build → k6 image → STANDARD Artifact Registry repo
       → setup          mint 1 virtual key per enabled profile (/key/generate),
                        write per-run config to gs://<bucket>/runs/current/config.json
       → run            gcloud run jobs update --tasks N; execute --wait
                        each task runs 1/N of the load (k6 execution segments),
                        writes summary-<i>.json to the results bucket
       → collect        merge k6 summaries + query Cloud Monitoring → report.md
       → teardown       delete the run's keys + per-run config
```

The k6 Job hits the public HTTPS LB (`lb_url`). Only the **virtual keys** and the
per-run config object are transient — base models, the master key, and all infra
are left intact.

## Prerequisites

- Stack deployed **with the harness on** (a single apply also builds + pushes the
  k6 image via Cloud Build, so the Job can be created in one pass):
  ```bash
  cd ../terraform
  terraform apply -var-file=dev.tfvars -var enable_loadtest=true
  ```
- `terraform`, `gcloud` (authenticated), `python3`.
- `run.sh build` is only needed to **rebuild** the k6 image after editing
  `k6/loadtest.js` (the initial build happens during `terraform apply`).

## Usage

```bash
cd loadtest
./run.sh build          # first time only (or after editing the k6 image)
./run.sh all            # setup → run → collect → teardown

# or step-by-step (keeps keys alive between run/collect):
./run.sh setup
./run.sh run
./run.sh collect        # prints results/<run-id>/report.md
./run.sh teardown
```

### Re-running later

The harness is fully repeatable — nothing to rebuild between runs:

```bash
cd loadtest
# 1. edit config.json (scale / profiles) as needed
./run.sh all            # setup → run → collect → teardown
```

Each run is namespaced by a timestamp `run_id`, so results never collide
(`results/<run-id>/`). To keep several configs around, point `CONFIG` at an
alternate file instead of editing `config.json`:

```bash
CONFIG=./scenarios/spike.json ./run.sh all
```

Only rebuild the k6 image (`./run.sh build`) after editing `k6/loadtest.js`.

### Removing the harness

Per-run keys/config are cleaned by `teardown`. To remove the harness
infrastructure itself (AR repo, results bucket, SA, Job):

```bash
cd ../terraform
terraform apply -var-file=dev.tfvars -var enable_loadtest=false
```

The base LiteLLM deployment is unaffected.

## Configuring scale & profiles — `config.json`

- `tasks` — number of parallel Cloud Run Job tasks (load is split across them).
- Each entry in `profiles`:
  - `enabled` — include it in this run.
  - `model` — the model the request asks for.
  - `executor` — `constant-arrival-rate` (use `rate` = **total** RPS across tasks,
    `duration`, `preAllocatedVUs`, `maxVUs`) or `ramping-vus` (use `stages`).
  - `stream`, `prompt_tokens`, `max_tokens` — request shape.
  - `expect_status` — the reject code this profile should provoke (429 / 400).
  - `key_models`, `key_rpm`, `key_tpm`, `key_budget` — the virtual key minted for it.

Built-in profiles: `throughput` (mock, max RPS), `streaming` (mock SSE), `real`
(gemini-3.5-flash, bounded), `ratelimit` (low rpm → 429s), `budget` (tiny budget →
rejects), `model-acl` (asks for a model the key can't use → rejects), `ramp`
(disabled; VU ramp to find the knee).

## Measuring Model Armor latency (A/B)

Model Armor emits request/filter **counts** but no latency metric, so measure the
added latency by comparing two runs on the authoritative Cloud Run p95:

Run a plain profile and a `guardrails: ["model-armor"]` profile **side by side**
with the same rate + prompt, at a rate **below** gateway saturation (a saturated
run measures queue wait, not the guardrail). k6 emits **per-profile**
`http_req_duration` sub-metrics, so each profile's p50/p95 is in its
`summary-*.json`; the delta ≈ Model Armor's added latency.

Two gotchas we hit: set **`model_armor_default_on = false`** or the "plain" profile
also runs Model Armor (delta ≈ 0); and vary/repeat carefully — measured overhead
was **~+150ms median / +330ms p95** unsaturated, but climbs sharply under load
(and, with `fail_on_error=false`, Model Armor errors **fail open**).

Per-request opt-in (`guardrails` in the profile) is also how you "sample" Model
Armor when `model_armor_default_on = false` — LiteLLM has no percentage sampler.

## Output

`results/<run-id>/`:
- `report.md` — client (k6) throughput/errors/rejects + server (Cloud Run / SQL /
  Valkey) latency & saturation, with the likely first bottleneck.
- `metrics.json` — raw merged metrics.
- `summary-*.json` — per-task k6 summaries.
- `config.json`, `keys.json` — the run's config and (for teardown) key records.

## Cost & scope notes

- Bulk load is `mock-gpt` (no provider call → ~zero token cost). The `real` and
  `budget` profiles make real Vertex calls — kept at low RPS to cap spend/quota.
- Running at **current defaults** (gateway max 10, backend max 4, ZONAL Postgres,
  single-shard Valkey) is intentional: find the ceiling and first bottleneck. The
  fixes are in [`../docs/PRODUCTION_READINESS.md`](../docs/PRODUCTION_READINESS.md).
- Valkey Cloud Monitoring metric names can vary; if they show `n/a` in the report,
  refine `lib/collect.py` using `gcloud monitoring metric-descriptors list`.
