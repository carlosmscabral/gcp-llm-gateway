# Overview — Simplified LiteLLM on GCP

A compact, validated visual overview of the deployed system. For the full
reference (network paths, security model, complete data model, failure modes)
see [`ARCHITECTURE.md`](./ARCHITECTURE.md); this file is the fast orientation.

Canonical component names used across every diagram: **gateway**, **backend**,
**ui**, **LB** (external HTTPS load balancer), **Cloud SQL** (Postgres),
**Valkey** (Memorystore), **OTel collector** (sidecar), **Secret Manager**,
**GCS**, **Artifact Registry mirror**, **Vertex AI**.

---

## 1. System context

```mermaid
flowchart LR
  user(["API consumer / SDK"])
  admin(["Admin / operator"])
  subgraph gcp["GCP project"]
    lb["LB (external HTTPS)"]
    gw["gateway (Cloud Run)"]
    be["backend (Cloud Run)"]
    ui["ui (Cloud Run)"]
  end
  vertex(["Vertex AI — Gemini"])
  other(["Other LLM providers"])

  user -->|"HTTPS + Bearer sk-..."| lb
  admin -->|"HTTPS — admin UI / API"| lb
  lb --> gw
  lb --> be
  lb --> ui
  gw -->|"keyless ADC"| vertex
  gw -->|"provider API keys"| other
```

The gateway is an OpenAI-compatible front door: clients call
`/v1/chat/completions` with a bearer key; LiteLLM authenticates, rate-limits,
routes to a backing model, and returns the response while tracking spend and
emitting telemetry. Vertex AI is the primary backend, reached keyless via the
runtime service account (ADC). All external traffic enters through the LB;
raw `*.run.app` URLs are blocked (ingress = internal load balancer only).

ASCII fallback:

```
  API consumer / SDK          Admin / operator
        |  HTTPS Bearer sk-...       |  HTTPS UI/API
        +------------+---------------+
                     v
              LB (external HTTPS)
             /       |        \
          gateway  backend    ui
             |
     ADC -> Vertex AI ;  keys -> other providers
```

---

## 2. Container / component view

```mermaid
flowchart TB
  client(["Client"])

  subgraph edge["Edge"]
    ip["Reserved global IP + nip.io host"]
    cert["Google-managed TLS cert"]
    lb["LB: URL-map path routing"]
  end

  subgraph run["Cloud Run v2"]
    gw["gateway :4000 (app + OTel collector)"]
    be["backend :4001 (app + OTel collector)"]
    ui["ui :3000 (nginx)"]
    job["migrations Job (prisma migrate deploy)"]
  end

  subgraph data["Private data plane"]
    sql[("Cloud SQL Postgres")]
    valkey[("Valkey (PSC)")]
    sm["Secret Manager"]
    gcs["GCS (data + proxy config)"]
  end

  subgraph supply["Supply chain / platform"]
    ar["Artifact Registry mirror -> ghcr.io"]
    obs["Cloud Trace + Cloud Monitoring"]
    vertex(["Vertex AI"])
  end

  client --> lb
  cert -.attached.-> lb
  ip -.-> lb
  lb -->|"/v1/*, /chat/*, /health*"| gw
  lb -->|"default -> mgmt API"| be
  lb -->|"/, /ui, /_next/*"| ui

  gw -->|"unix socket /cloudsql"| sql
  be -->|"unix socket /cloudsql"| sql
  job -->|"unix socket /cloudsql"| sql
  gw -->|"Direct VPC egress -> PSC"| valkey
  be -->|"Direct VPC egress -> PSC"| valkey
  gw -->|"secret env refs"| sm
  be -->|"secret env refs"| sm
  gw --> gcs
  be --> gcs
  gw -->|"OTLP localhost"| obs
  be -->|"OTLP localhost"| obs
  gw -->|"ADC"| vertex
  run -.image pull.-> ar
```

Three Cloud Run v2 services fronted by one LB, plus a migrations Job. The LB
URL map fans traffic by path: LLM data-plane prefixes (`/v1/*`, `/chat/*`,
`/health*`, provider passthroughs) go to **gateway :4000**; UI asset paths
(`/`, `/ui`, `/_next/*`) go to **ui :3000**; everything else (the management
API: `/key/*`, `/user/*`, `/team/*`) defaults to **backend :4001**. gateway and
backend each run the app container plus an **OTel collector** sidecar (app waits
on collector via container-dependencies). **ui** runs a single nginx container
under a zero-IAM service account. Images are pulled through the **Artifact
Registry mirror** that lazily caches `ghcr.io/berriai/litellm-*`.

---

## 3. Request lifecycle — POST /v1/chat/completions

```mermaid
sequenceDiagram
  autonumber
  participant C as Client
  participant LB as LB
  participant GW as gateway
  participant VK as Valkey
  participant PG as Cloud SQL
  participant VX as Vertex AI
  participant OT as OTel collector

  Note over GW: secrets loaded at boot from Secret Manager
  C->>LB: POST /v1/chat/completions with Bearer key
  LB->>GW: route data-plane path to gateway NEG
  GW->>VK: look up key in cache, check tpm and rpm counters
  alt key not cached
    GW->>PG: validate key in VerificationToken table
    PG-->>GW: key metadata, cached back into Valkey
  end
  GW->>VK: router picks a deployment, skips cooled-down ones
  GW->>VX: chat request via ADC runtime SA
  VX-->>GW: completion and token usage
  GW->>PG: record spend and usage async
  GW->>VK: update tpm and rpm usage and cooldown state
  GW-)OT: emit span via OTLP to Cloud Trace and Monitoring
  GW-->>C: 200 and completion
```

Auth, rate limiting, and routing all consult Valkey first (fast, shared across
instances) and fall back to Cloud SQL for the authoritative key record on a
cache miss. Vertex AI is called keyless with the runtime SA. Spend is written
back to Cloud SQL asynchronously; a span is emitted to the OTel collector, which
exports traces to Cloud Trace and metrics to Cloud Monitoring. (This diagram is
the request path, not one distributed trace — the LiteLLM app trace is separate
from the LB/Cloud Run platform trace; see [`LIMITATIONS.md`](./LIMITATIONS.md).)

---

## 4. Data model — Postgres vs Valkey

| Store | Role | Holds | If lost |
|---|---|---|---|
| **Cloud SQL (Postgres)** | Source of truth | Virtual keys (hashed), users/teams/orgs, budgets, spend ledger (`SpendLogs` + daily rollups), DB-stored models, config, audit. Schema owned by LiteLLM (Prisma), applied by the migrations Job. | Hard outage: auth, spend, and model config unavailable. |
| **Valkey** | Fast shared cache/coord | tpm/rpm rate-limit counters, router cooldowns and usage, auth/metadata cache, optional response cache. All ephemeral and TTL'd. | Degraded only: cross-instance rate limiting, cooldowns, and caching reset; requests still serve. |

Secrets (master key, `DATABASE_URL`, provider keys, OTel config) live in
**Secret Manager** and are injected as secret env at boot. The proxy
`config.yaml` and file/request storage live in **GCS**. Valkey is never a source
of truth, so flushing it is non-destructive. See
[`ARCHITECTURE.md` section 7](./ARCHITECTURE.md) for the full table catalog and ER diagram.

---

## 5. Load-test harness

Gated behind `enable_loadtest` (default `false`): a normal deploy creates none of
it. When enabled, `loadtest/run.sh` orchestrates repeatable, config-driven load
against the deployed **LB** using **k6 on a Cloud Run Job**. Scale and traffic
shape live in `loadtest/config.json`.

```mermaid
flowchart TB
  op(["Operator (loadtest/run.sh)"])

  subgraph cmds["run.sh subcommands"]
    build["build"]
    setup["setup"]
    run["run"]
    collect["collect"]
    teardown["teardown"]
  end

  subgraph harness["Load-test harness (enable_loadtest only)"]
    cb["Cloud Build"]
    ar["STANDARD Artifact Registry repo (k6 image)"]
    job["k6 Cloud Run Job (N tasks, parallelism N)"]
    bucket[("results bucket (GCS)")]
  end

  subgraph base["Base deployment"]
    lb["LB (external HTTPS)"]
    gw["gateway :4000"]
    be["backend :4001 (management API)"]
    mon["Cloud Monitoring"]
  end

  op --> build & setup & run & collect & teardown

  build --> cb --> ar
  setup -->|"mint 1 virtual key per enabled profile: POST /key/generate"| lb
  lb -->|"default route: mgmt API"| be
  setup -->|"per-run config.json to runs/current"| bucket

  run -->|"jobs update tasks and parallelism, then execute wait"| job
  ar -.image pull.-> job
  job -->|"1/N of load via execution segments: POST /v1/chat/completions + Bearer vk"| lb
  lb -->|"data-plane route"| gw
  job -->|"summary-i.json per task"| bucket

  collect -->|"pull and merge k6 summaries"| bucket
  collect -->|"query run-window metrics"| mon
  collect --> report["results/RUN_ID/report.md"]

  teardown -->|"delete run keys: POST /key/delete"| lb
  teardown -->|"remove per-run config"| bucket
```

ASCII fallback:

```
  Operator (loadtest/run.sh)
     |    |     |      |        |
   build setup  run  collect teardown
     |    |      |      |  \       |
     v    |      |      |   \      v
 Cloud    |      |      |    \  POST /key/delete -> LB -> backend
 Build    |      |      |     query -> Cloud Monitoring
     |    |      |      v
     v    |      |    merge summaries <- results bucket (GCS)
  AR repo |      |      -> results/RUN_ID/report.md
 (k6 img) |      |
     |    |      +-> jobs update+execute -> k6 Cloud Run Job (N tasks)
     |    |            image pull ^   |  POST /v1/chat/completions +Bearer vk
     |    |                           v            |
     |    +-> POST /key/generate -> LB ------------+--> gateway :4000
     |         + config.json -> results bucket (GCS)
     +--> (image pulled by the Job)
```

The five subcommands split cleanly: `build` uses **Cloud Build** to push the k6
image to a **STANDARD Artifact Registry repo** (distinct from the `ghcr.io`
pull-through mirror; the first build also runs during `terraform apply`). `setup`
mints one virtual key per enabled profile through the **backend** management API
(`/key/generate`) and writes the per-run `config.json` to the **results bucket**
(GCS). `run` sets the Job's `--tasks`/`--parallelism` to `tasks` from the config
and executes it; each task runs `1/N` of the load via k6 execution segments,
hitting the **LB** on `/v1/chat/completions` with its profile's virtual key, and
writes a per-task `summary-i.json` back to the bucket. `collect` merges those
summaries with **Cloud Monitoring** run-window metrics into `report.md`; `teardown`
deletes the run's keys and per-run config. Only the virtual keys and the per-run
config object are transient — base models, the master key, and all infra stay
intact. See [`loadtest/README.md`](../loadtest/README.md) for scale/profile tuning.
