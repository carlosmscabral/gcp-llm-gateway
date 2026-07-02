# Design Decisions — Simplified LiteLLM-on-GCP

> Rationale for every notable architectural and configuration choice in the
> current (simplified) module under [`../terraform`](../terraform). Each entry
> states the decision, why it was made, the trade-off accepted, and the upgrade
> path for production (cross-referenced to
> [`PRODUCTION_READINESS.md`](./PRODUCTION_READINESS.md)).
>
> The guiding principle: **keep the smallest footprint that runs LiteLLM
> correctly and is trivially replicable per customer/project**, while never
> painting us into a corner for the production hardening in the roadmap.

**Legend:** each decision = **What** · **Why** · **Trade-off** · **Prod path →**

---

## A. Networking

### A1. Drop the Serverless VPC Access connector; use Direct VPC egress
- **What:** Cloud Run reaches the VPC via `vpc_access.network_interfaces`
  (Direct VPC egress) into the main subnet, not a `google_vpc_access_connector`.
- **Why:** The connector is a managed, always-on fleet of e2-micro VMs you pay
  for and must size/scale; Direct VPC egress is the modern, GA replacement with
  no extra resource, lower latency, and no per-connector throughput ceiling.
- **Trade-off:** Direct VPC egress still needs a subnet with enough IPs at high
  fan-out (sized via `subnet_cidr`).
- **Prod path →** unchanged; just size the subnet and route external egress via
  Cloud NAT (Roadmap §4.4).

### A2. Drop Private Service Access (PSA) peering
- **What:** No `google_service_networking_connection` /
  `google_compute_global_address` VPC-peering range.
- **Why:** PSA peering was only there to give Cloud SQL and Redis private IPs.
  We reach Cloud SQL via the native connector (A3/B2) and Valkey via PSC (C2),
  neither of which needs PSA — removing it deletes a whole class of setup and
  the `servicenetworking` dependency.
- **Trade-off:** none for our access paths.
- **Prod path →** if the DB moves to private IP via PSA, reintroduce it; PSC is
  the preferred alternative (Roadmap §4.2).

### A3. Reach Cloud SQL via the native Cloud Run connector (unix socket)
- **What:** `volumes.cloud_sql_instance` mounts the instance at
  `/cloudsql/<connection_name>`; `DATABASE_URL` uses `?host=/cloudsql/...`.
- **Why:** Zero VPC needed for DB access. The embedded Cloud SQL Auth Proxy
  connects over IAM + ephemeral mTLS certs — no connector, no PSA, and the DB is
  not exposed to the internet even with a public IP (see A4).
- **Trade-off:** couples DB access to the Cloud SQL connector; connection count
  scales with Cloud Run instances (no pooling yet).
- **Prod path →** add connection pooling + private IP (Roadmap §4.2).

### A4. Cloud SQL keeps a public IP but **no authorized networks**
- **What:** `ipv4_enabled = true`, `ssl_mode = ENCRYPTED_ONLY`, no
  `authorized_networks`.
- **Why:** The native connector path uses the public IP over Google's network
  with IAM + certs; with zero authorized networks there is no anonymous/internet
  reachability. This avoids needing private IP (and therefore PSA) while keeping
  the DB effectively closed.
- **Trade-off:** a public IP exists on the instance (attack-surface optics), even
  though it's not usable without IAM + certs.
- **Prod path →** switch to **private IP**, remove the public endpoint entirely
  (Roadmap §4.2, security checklist).

### A5. Two subnets: main (Direct VPC egress) + dedicated PSC subnet
- **What:** `google_compute_subnetwork.this` for Cloud Run egress IPs;
  `google_compute_subnetwork.psc` (`purpose = PRIVATE`) backs the Valkey PSC
  endpoint via a service connection policy.
- **Why:** Keeps PSC IP allocation from contending with Cloud Run instance IPs;
  clean separation and independent sizing.
- **Trade-off:** one extra subnet.
- **Prod path →** unchanged; replicate per region.

---

## B. Database (Cloud SQL)

### B1. Single instance, `ZONAL` by default (no read replica)
- **What:** One `google_sql_database_instance`; `db_availability_type` defaults
  to `ZONAL`; the upstream cross-zone read replica is removed.
- **Why:** Simplification goal + lowest cost for dev/test. A single writer is
  sufficient for moderate scale.
- **Trade-off:** no in-region failover, no read scaling; a zone outage = DB down.
- **Prod path →** `REGIONAL` HA + read replicas + cross-region DR replica
  (Roadmap §4.2, §6).

### B2. `DATABASE_URL` delivered as a Secret Manager secret (not shell-assembled)
- **What:** The full connection string (incl. password + socket host) is
  assembled at apply time into `-db-url` and injected as a secret env var to
  gateway, backend, and the migration job.
- **Why:** Simpler containers — no runtime shell wrapper to build the URL from
  discrete `DATABASE_*` vars; one source of truth; the password never appears in
  plain env. **Verified:** the `litellm-migrations` image honors a preset
  `DATABASE_URL`.
- **Trade-off:** password is known at apply time (fine — it's generated and
  stored in Secret Manager); rotating requires re-apply of the secret version.
- **Prod path →** add Secret Manager rotation + CMEK (Roadmap §4.5).

### B3. Password auth (not IAM DB auth)
- **What:** Generated 32-char password in Secret Manager; `google_sql_user`.
- **Why:** LiteLLM's IAM-auth helper targets AWS RDS, not GCP IAM (documented
  upstream). Password auth is the compatible path.
- **Trade-off:** a long-lived credential to manage/rotate.
- **Prod path →** rotation + CMEK; revisit IAM auth if LiteLLM adds GCP support.

---

## C. Cache (Memorystore for Valkey)

### C1. Valkey instead of Redis; single node
- **What:** `google_memorystore_instance`, `shard_count = 1`,
  `replica_count = 0`, `SHARED_CORE_NANO`.
- **Why:** User-chosen. Valkey is OSS, Redis-API compatible, and cheaper;
  single node is the minimal footprint for the cache role (rate limiting,
  response cache, router state).
- **Trade-off:** no HA, no horizontal throughput headroom.
- **Prod path →** sharded cluster + replicas + multi-zone (Roadmap §4.3).

### C2. Reached via Private Service Connect (PSC), not PSA
- **What:** `google_network_connectivity_service_connection_policy`
  (`service_class = gcp-memorystore`) + `desired_auto_created_endpoints`; the app
  reads the PSC endpoint IP/port.
- **Why:** Valkey's modern connectivity model; avoids PSA peering and works with
  Direct VPC egress. Keeps the cache fully private (no public endpoint).
- **Trade-off:** the endpoint IP is read from a (currently deprecated but
  populated) attribute with a nested fallback (`try(...)`); PSC has a service
  connection policy to manage.
- **Prod path →** unchanged; replicate per region.

### C3. Transit encryption + AUTH disabled
- **What:** `TRANSIT_ENCRYPTION_DISABLED`, `AUTH_DISABLED`.
- **Why:** Traffic stays on the private PSC path inside the VPC; disabling both
  removes the CA-cert plumbing/startup hack the upstream needed, simplifying the
  containers.
- **Trade-off:** no in-transit encryption / no cache auth (acceptable on a
  private path for dev/test, **not** for mission-critical).
- **Prod path →** enable `SERVER_AUTHENTICATION` + AUTH (Roadmap §4.3, checklist).

---

## D. Compute — Cloud Run

### D1. Three services + a migration Job (mirrors upstream split)
- **What:** `gateway` (:4000), `backend` (:4001), `ui` (:3000) + a `migrations`
  Cloud Run Job.
- **Why:** Matches LiteLLM's split-image architecture and keeps the data plane
  (gateway), management API (backend), and static UI independently scalable.
- **Trade-off:** more moving parts than a single container.
- **Prod path →** per-workload scaling/concurrency tuning (Roadmap §4.1).

### D2. `min_instances = 1`, default CPU behavior
- **What:** Each service keeps one warm instance; no startup CPU boost; default
  CPU allocation.
- **Why:** Cheapest posture that avoids the worst cold starts for a dev/test
  stack.
- **Trade-off:** cold-start latency under scale-up; no burst headroom on boot.
- **Prod path →** warm pool `min≥N`, **startup CPU boost**, **CPU always
  allocated** (Roadmap §4.1).

### D3. Internal-LB ingress + `allUsers` invoker
- **What:** Services are `INGRESS_TRAFFIC_INTERNAL_LOAD_BALANCER`; an
  `allUsers` `run.invoker` binding lets LB traffic reach the container. Real auth
  is LiteLLM's `LITELLM_MASTER_KEY`.
- **Why:** The upstream pattern for putting Cloud Run behind an external HTTPS LB;
  the internal-LB ingress means only the LB (not the raw `*.run.app`) serves
  traffic, and app-layer auth gates actual use.
- **Trade-off:** `allUsers` on the invoker is coarse; no identity at the edge.
  (Also note: this binding intermittently tripped an org policy during apply.)
- **Prod path →** **IAP + Google SSO**, remove `allUsers` (Roadmap §4.5).

### D4. OTel Collector as a sidecar container (app depends on it)
- **What:** `gateway`/`backend` run a second container (`collector`,
  `otelcol-google`) with `container-dependencies = {app:[collector]}`.
- **Why:** LiteLLM ships OTLP to `localhost:4318`; the sidecar authenticates to
  GCP with the runtime SA and exports — sending OTLP directly to
  `telemetry.googleapis.com` from the app needs per-RPC Google auth the LiteLLM
  exporter can't supply. The dependency ordering avoids dropping boot spans.
- **Trade-off:** +1 container (CPU/mem) per instance; total CPU must be a valid
  Cloud Run value (app + sidecar).
- **Prod path →** unchanged pattern; just resolve the LiteLLM emission gap (§F1).

### D5. UI runs under a separate zero-permission service account
- **What:** `ui_runtime` SA has **no** IAM bindings; gateway/backend/job share
  `runtime`.
- **Why:** The UI is static nginx with no DB/cache/secret needs — a compromised
  UI container can't reach data-plane resources via the metadata server.
- **Trade-off:** gateway and backend still **share** one SA (coarser than
  ideal).
- **Prod path →** split gateway vs backend into separate least-privilege SAs
  (Roadmap §4.5).

### D6. Migration via Cloud Run Job + `terraform_data` `local-exec`
- **What:** A Job holds the migration container; a `local-exec` runs
  `gcloud run jobs execute --wait` during apply; gateway/backend depend on it.
- **Why:** Runs schema migrations exactly once per apply before the app goes
  live, using the same image/secret wiring.
- **Trade-off:** `local-exec` depends on `gcloud` + creds on the machine running
  Terraform — fine for a workstation/CI runner, not ideal for GitOps.
- **Prod path →** run the migration as a pipeline step, not `local-exec`
  (Roadmap §4.7).

---

## E. Observability

### E1. OTel → Cloud Trace + Cloud Monitoring via `googlecloud` /
`googlemanagedprometheus`
- **What:** The collector exports **traces → `googlecloud`** (Cloud Trace) and
  **metrics → `googlemanagedprometheus`** (Cloud Monitoring / Managed
  Prometheus), authenticating via the runtime SA (`cloudtrace.agent`,
  `monitoring.metricWriter`).
- **Why:** These exporters use ADC directly (simplest auth on Cloud Run) and are
  Google's recommended targets — no `googleclientauth` extension or telemetry-
  endpoint quota-project juggling.
- **Trade-off:** GCP-specific (by design — the requirement is GCP-native OTEL).
- **Prod path →** add SLOs/alerts/dashboards + `/metrics` scrape (Roadmap §4.6).

---

## F. Images & supply chain

### F1. Artifact Registry **remote repository** mirroring ghcr.io (declarative)
- **What:** `google_artifact_registry_repository` (`REMOTE_REPOSITORY`, custom
  Docker upstream `https://ghcr.io`); images composed from the mirror; Cloud Run
  service agent granted `artifactregistry.reader`.
- **Why:** Cloud Run cannot pull `ghcr.io` directly. A remote repo **lazily
  mirrors on first pull** — fully declarative, no `docker pull/push`, and every
  customer project gets its own mirror on apply (the replication requirement).
- **Trade-off:** first pull incurs the upstream fetch; needs the AR API + IAM.
- **Prod path →** add **Binary Authorization** + vuln scanning + SBOM
  (Roadmap §4.5); optionally pin digests.

### F2. API enablement captured in Terraform (`google_project_service`)
- **What:** All 11 required APIs enabled via `for_each` `google_project_service`;
  foundational resources `depends_on` it.
- **Why:** A fresh customer project needs **zero** manual `gcloud services
  enable` — everything is captured by automation (the replication mindset).
- **Trade-off:** `serviceusage` must be enabled once out-of-band before the first
  apply.
- **Prod path →** unchanged; enforce via CI policy.

---

## G. Edge / load balancing

### G1. External global HTTPS LB with path routing (kept from upstream)
- **What:** Serverless NEGs + backend services + URL map routing LLM paths →
  gateway, UI asset paths → ui, everything else → backend; managed cert when
  `lb_domains` set.
- **Why:** Single domain, unified TLS, path-based routing across the three
  services — production-like and the most useful shape even in the simplified
  build. User confirmed keeping it.
- **Trade-off:** more resources than exposing raw `*.run.app` URLs.
- **Prod path →** add Cloud Armor + CDN + TLS-only + multi-region backends
  (Roadmap §4.4).

### G2. Plaintext LB allowed via explicit opt-in
- **What:** `allow_plaintext_lb` must be `true` when `lb_domains = []`, else
  `plan` fails.
- **Why:** Lets trial/dev stacks come up on the anycast IP without DNS, while the
  default-deny forces a conscious choice.
- **Trade-off:** plaintext is insecure (dev/test only).
- **Prod path →** remove the flag; TLS-only + SSL policy (Roadmap §4.4).

---

## H. Conventions & safety

### H1. Naming: `<tenant>-litellm-<env>`
- **What:** Every resource derives from `local.name = "${tenant}-litellm-${env}"`.
- **Why:** Deterministic, collision-free names across many tenants/envs in the
  same or different projects — core to multi-customer replication.
- **Prod path →** unchanged.

### H2. Deletion protection defaults on; `*_force_destroy` off
- **What:** Cloud SQL + Valkey deletion protection default `true`; GCS
  `force_destroy` default `false`. `dev.tfvars` flips them off for the test env.
- **Why:** Safe-by-default tripwires against accidental data loss; explicit
  opt-out for ephemeral stacks.
- **Prod path →** keep on in prod; add tested restore runbooks (Roadmap §6).

### H3. Secrets in Secret Manager; master key auto-generated
- **What:** `master_key`, `db_url`, `otel_config`, optional `license`/
  `ui_password` in Secret Manager; master key auto-generated if not supplied.
- **Why:** No secrets in plain env; usable out-of-the-box for trials.
- **Trade-off:** secret **values** can still land in Terraform state.
- **Prod path →** remote encrypted state, rotation, CMEK, and virtual keys for
  API consumers (Roadmap §4.5).

### H4. `proxy_config` mounted read-only via GCS gcsfuse
- **What:** When `proxy_config` is set, its YAML is uploaded to a dedicated
  bucket and mounted at `/etc/litellm/config.yaml`; a content hash forces a new
  revision on change. **Verified working** (mock model surfaced via config).
- **Why:** Declarative model/config management without rebuilding images.
- **Prod path →** unchanged; manage config via pipeline.

### H5. Module configures its own provider + local state *(known trade-off)*
- **What:** The module includes a `provider "google"` block and uses **local
  state**.
- **Why:** It's applied as a root config per project — simplest for standing up
  test stacks.
- **Trade-off:** provider-in-module limits composition; **local state is not
  team/prod-safe**.
- **Prod path →** **remote GCS state + locking**; consider a
  root-module/child-module split (Roadmap §4.7).

---

## Summary map: simplification ↔ production lever

| Area | Simplified choice | First production upgrade |
|---|---|---|
| VPC | Direct VPC egress, no PSA | + Cloud NAT static egress, VPC-SC |
| Cloud SQL | Single ZONAL, public IP + native connector | REGIONAL HA + read replicas + private IP + pooling |
| Valkey | 1 node, no TLS/AUTH, PSC | Cluster + replicas + TLS/AUTH, multi-zone |
| Cloud Run | min=1, default CPU | Warm pool + CPU boost + always-on CPU, multi-region |
| Edge | HTTPS LB, plaintext allowed, `allUsers` | Cloud Armor + CDN + TLS-only + IAP |
| Identity | Master key + UI password | Google SSO/OIDC + IAP + virtual keys/RBAC |
| Images | AR remote mirror | + Binary Authorization + scanning |
| State/CD | Local state, local-exec migration | Remote state + CI/CD + WIF + canary |
| Keys | Google-managed | CMEK everywhere + rotation |
| DR | None | Cross-region replicas + tested failover |

See [`PRODUCTION_READINESS.md`](./PRODUCTION_READINESS.md) for the full roadmap,
diagrams, phasing, and RTO/RPO targets.
