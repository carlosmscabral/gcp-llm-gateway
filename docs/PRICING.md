# Pricing — what this gateway adds to your GCP bill

This estimates the **GCP infrastructure cost of the gateway itself** — the
resources this Terraform module creates — as a function of traffic. It is a
planning aid, not a quote.

> **Scope.** This models the *gateway overhead*: Cloud Run, Cloud SQL, Memorystore
> (Valkey), the HTTPS load balancer, Artifact Registry, Secret Manager, Cloud
> Trace, Cloud Monitoring, and **Model Armor**. It **excludes the Vertex AI / Gemini
> model token charges** (the actual inference spend) — those are billed by Vertex
> per model and usually **dwarf** the gateway overhead. It includes Model Armor
> because that is a gateway-side safety feature you turn on here.
>
> **This is illustrative.** Cloud Run and Memorystore autoscaling, request
> duration, streaming, payload sizes, and metric cardinality all move the numbers.
> Every premise is stated so you can re-run the math for your own workload. Confirm
> unit prices against the live pricing pages (linked at the bottom) — rates change
> and vary by region.

All figures are **us-central1 (Tier 1)**, on-demand (no committed-use discounts),
and a month is **730 hours**.

---

## 1. The headline

```
   Monthly cost  ≈   FIXED FLOOR   +   VARIABLE (per traffic)   +   MODEL ARMOR (if on)
                     ≈$250/mo          scales with requests,        scales with tokens
                     (always on)       tokens, and duration         (input tokens)
```

- There is a **≈$250/month floor** with the ZONAL dev-style defaults, paid whether
  or not a single request arrives. It is dominated by **Cloud SQL** (≈$104) and the
  three **always-warm Cloud Run** services (≈$95).
- On top of the floor, cost scales with **requests**, **tokens**, and **request
  duration**.
- **Model Armor is the most traffic-sensitive line** — at high volume it can exceed
  every other gateway cost combined. It is **off by default**.

---

## 2. Unit prices used (grounded)

| Resource | Unit price (us-central1) | Free tier |
|---|---|---|
| Cloud Run vCPU (active, during request) | $0.000024 / vCPU-second | 180,000 vCPU-s / mo |
| Cloud Run memory (active) | $0.0000025 / GiB-second | 360,000 GiB-s / mo |
| Cloud Run vCPU + memory (**idle**, min-instances) | $0.0000025 / vCPU-s and / GiB-s | — |
| Cloud Run requests | $0.40 / million | 2,000,000 / mo |
| Cloud SQL vCPU (Enterprise) | $0.0413 / vCPU-hour | — |
| Cloud SQL memory (Enterprise) | $0.0070 / GB-hour | — |
| Cloud SQL SSD storage | ≈$0.17 / GB-month | — |
| Memorystore Valkey `shared-core-nano` | **premise** ≈$0.02 / node-hour (see §5) | — |
| HTTPS LB global forwarding rule | $0.025 / hour (first 5) | — |
| HTTPS LB data processing | ≈$0.01 / GiB (in + out) | — |
| Internet egress (to internet) | ≈$0.12 / GiB (first tier; premise) | — |
| Artifact Registry storage | $0.10 / GB-month | 0.5 GB |
| Secret Manager active version | $0.06 / version-month | 6 versions |
| Cloud Trace span ingestion | ≈$0.20 / million spans | 2.5M spans / mo |
| Cloud Monitoring — Google system metrics | free (non-chargeable) | — |
| Managed Prometheus samples (collector metrics) | $0.060 / million samples | — |
| Model Armor | $0.10 / million tokens | 2,000,000 tokens / mo |

Sources in §8. The Cloud Run **idle** rate is the reduced min-instance rate
(≈90% off active CPU); memory is the same rate active or idle. Cloud Monitoring
alerting is free today but [begins charging no sooner than Sept 1, 2026](https://cloud.google.com/products/observability/pricing)
(≈$0.35 per policy-month) — with 3 alert policies that is ≈$1/mo, noted but excluded.

---

## 3. The fixed floor (always-on, ZONAL defaults)

What runs 24×7 regardless of traffic, at the module defaults (gateway/backend =
1 vCPU + 4 GiB each with a 1 vCPU + 0.5 GiB OTel sidecar; UI = 1 vCPU + 0.5 GiB;
all `min_instances = 1`; Cloud SQL `db-custom-2-7680` = 2 vCPU / 7.5 GB, ZONAL;
Valkey nano; TLS load balancer = 2 forwarding rules).

| Item | Calculation | $/month |
|---|---|--:|
| Cloud SQL compute (2 vCPU) | 2 × $0.0413 × 730 | $60.30 |
| Cloud SQL memory (7.5 GB) | 7.5 × $0.0070 × 730 | $38.33 |
| Cloud SQL SSD (20 GB) | 20 × $0.17 | $3.40 |
| Cloud SQL backups + PITR | premise | ≈$2.00 |
| Cloud Run idle CPU (5 vCPU total) | 5 × $0.0000025 × 2,628,000 | $32.85 |
| Cloud Run idle memory (9.5 GiB total) | 9.5 × $0.0000025 × 2,628,000 | $62.42 |
| Memorystore Valkey (nano) | premise ≈$0.02 × 730 | ≈$15.00 |
| HTTPS LB forwarding rules (2) | 2 × $0.025 × 730 | $36.50 |
| Artifact Registry (mirror cache ≈5 GB) | ≈5 × $0.10 | ≈$0.50 |
| Secret Manager (few versions) | near free tier | <$1.00 |
| **Fixed floor** | | **≈ $252 / month** |

The two big levers on the floor: **Cloud SQL** (≈$104; halve by dropping to
`db-custom-1-3840` if the workload allows, or roughly **double** it by choosing
REGIONAL HA) and the **4 GiB memory on gateway/backend** (that alone is ≈$26/mo of
idle memory; dropping to 2 GiB cuts it in half — see §6).

---

## 4. Variable cost by traffic profile

Three illustrative profiles. Token mix is **25% input / 75% output** (Gemini), as
requested. Premises for the variable math:

- **Request duration / packing:** each request holds a gateway instance for ≈**4 s**
  of wall time; effective concurrency ≈**10** per instance → ≈**0.4 billed
  instance-seconds/request** across the gateway's 2 vCPU + 4.5 GiB (app + sidecar).
- **Wire size:** ≈**6 bytes/token** (≈4 bytes/token + JSON/SSE overhead).
- **Spans:** **8 per request** (the nested app trace).
- **Model Armor:** `INSPECT_ONLY`, `pre_call` only → inspects **input tokens only**
  (25% of total).

| Profile | Requests / mo | Avg tokens / req | Total tokens / mo | Input (25%) |
|---|--:|--:|--:|--:|
| **Light** (dev / small team) | 100,000 | 1,000 | 100 M | 25 M |
| **Medium** (production app) | 3,000,000 | 1,500 | 4.5 B | 1.125 B |
| **Heavy** (scale) | 30,000,000 | 2,000 | 60 B | 15 B |

### Variable line items (Model Armor OFF)

| Line item | Light | Medium | Heavy |
|---|--:|--:|--:|
| Cloud Run active compute | $0 (free tier) | $65.88 | $705.78 |
| Cloud Run request fee | $0 (free tier) | $0.40 | $11.20 |
| LB data processing | ≈$0.01 | $0.27 | $3.60 |
| Internet egress | ≈$0.07 | $3.24 | $43.20 |
| Cloud Trace spans | $0 (free tier) | $4.30 | $47.50 |
| Cloud Monitoring samples | ≈$1 (premise) | ≈$8 (premise) | ≈$25 (premise) |
| **Variable subtotal** | **≈ $1** | **≈ $82** | **≈ $836** |

### Totals

| | Light | Medium | Heavy |
|---|--:|--:|--:|
| Fixed floor | $252 | $252 | $252 |
| Variable (MA off) | $1 | $82 | $836 |
| **Gateway total — Model Armor OFF** | **≈ $253 / mo** | **≈ $334 / mo** | **≈ $1,088 / mo** |
| Model Armor add-on (see §5) | +$2 | +$112 | +$1,500 |
| **Gateway total — Model Armor ON** | **≈ $255 / mo** | **≈ $446 / mo** | **≈ $2,588 / mo** |

Reading it: at **Light** volume almost everything falls inside GCP free tiers, so
you essentially pay the **floor**. At **Heavy** volume the **Cloud Run active
compute** (≈$706) and **Model Armor** (≈$1,500) dominate.

---

## 5. Model Armor — the traffic-sensitive line

Model Armor bills **$0.10 per million tokens** processed, with the **first 2M
tokens/month free**. Our default (`model_armor_mode = ["pre_call"]`) inspects only
the **prompt** (input tokens); adding `"post_call"` also inspects responses and
roughly **quadruples** the token volume (output is 3× input in this mix).

| Profile | Inspected tokens (pre_call = input) | Billable (− 2M free) | Cost @ $0.10/M |
|---|--:|--:|--:|
| Light | 25 M | 23 M | **$2.30** |
| Medium | 1.125 B | 1.123 B | **$112.30** |
| Heavy | 15 B | 14.998 B | **$1,499.80** |

Because it scales linearly with tokens and has no percentage sampler in LiteLLM,
Model Armor is the **first thing to scope deliberately**: keep it **off by default**
(`model_armor_default_on = false`) and opt in per-request (`guardrails:
["model-armor"]`) for only the traffic that needs screening, or reserve it for
untrusted/end-user surfaces. (Model Armor also adds ≈+150 ms p50 / ≈+330 ms p95 of
latency — see [`LIMITATIONS.md`](./LIMITATIONS.md).)

> The exact `shared-core-nano` Valkey rate isn't published in a machine-readable
> form (the pricing page uses a region selector); §3 uses a **premise of
> ≈$0.02/node-hour (≈$15/mo)**. It's a dev/test node (1.12 GB, no SLA) and a small
> slice of the floor — confirm on the pricing page and, for production, price a
> larger node type.

---

## 6. Levers to lower the bill

| Lever | Effect |
|---|--:|
| **Right-size gateway/backend memory** 4 GiB → 2 GiB | −≈$26/mo idle + lower active memory |
| **UI `min_instances = 0`** (accept a cold start) | −≈$7/mo floor |
| **Backend `min_instances = 0`** (control-plane, bursty) | −≈$43/mo floor |
| **Cloud SQL** `db-custom-1-3840` instead of `-2-7680` | ≈halve the ≈$99 SQL compute |
| **Stay ZONAL** (default) vs REGIONAL HA | REGIONAL ≈ **2×** SQL compute + storage |
| **Cloud Trace sampling** (1-in-N) | cuts span cost ≈linearly at Heavy scale |
| **Model Armor** off-by-default + per-request opt-in, `pre_call` only | avoids the largest variable line |
| **Committed Use Discounts** (1–3 yr) on Cloud Run / Cloud SQL | ≈25–52% off steady-state compute |
| **CPU always-allocated** (prod streaming) | *raises* cost — trade for lower tail latency |

---

## 7. Compute your own estimate

```
FIXED  ≈ 252                                        # ZONAL defaults, us-central1

Cloud Run active = max(0, R*D/C*V - 180000)*0.000024        # V = vCPU (2), free 180k
                 + max(0, R*D/C*M - 360000)*0.0000025       # M = GiB (4.5), free 360k
Requests         = max(0, R - 2_000_000)/1e6 * 0.40
Network          = T * 6 / 1e9 * (0.01 + 0.12)             # LB proc + egress, $/GiB
Trace            = max(0, R*8 - 2_500_000)/1e6 * 0.20
Model Armor      = max(0, T_in - 2_000_000)/1e6 * 0.10     # T_in = input tokens; pre_call

where R = requests/mo, D = avg seconds/request, C = effective concurrency,
      T = total tokens/mo, T_in = input tokens/mo.
```

Plug in your `R`, `D`, `C`, and token counts. The [Google Cloud Pricing
Calculator](https://cloud.google.com/products/calculator) is the authoritative
tool for a per-SKU quote once you settle on machine sizes.

---

## 8. Sources

- [Cloud Run pricing](https://cloud.google.com/run/pricing)
- [Cloud SQL pricing](https://cloud.google.com/sql/pricing)
- [Memorystore for Valkey pricing](https://cloud.google.com/memorystore/valkey/pricing)
- [Cloud Load Balancing pricing](https://cloud.google.com/load-balancing/pricing) · [Network pricing](https://cloud.google.com/vpc/network-pricing)
- [Artifact Registry pricing](https://cloud.google.com/artifact-registry/pricing)
- [Secret Manager pricing](https://cloud.google.com/secret-manager/pricing)
- [Google Cloud Observability (Trace + Monitoring) pricing](https://cloud.google.com/products/observability/pricing)
- [Security Command Center pricing (Model Armor)](https://cloud.google.com/security-command-center/pricing)

See also: [`DESIGN_DECISIONS.md`](./DESIGN_DECISIONS.md) (why each resource is sized
this way), [`PRODUCTION_READINESS.md`](./PRODUCTION_READINESS.md) (HA/scale upgrades
and their cost implications), and [`LIMITATIONS.md`](./LIMITATIONS.md).
