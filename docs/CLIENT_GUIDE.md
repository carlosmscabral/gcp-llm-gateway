# Client guide — calling Vertex models through the gateway

How a **client** invokes Vertex-hosted models (native Gemini, Claude on Vertex,
DeepSeek MaaS) through the LiteLLM gateway, and the **trade-off between native
fidelity and governance** depending on the SDK/format you choose.

Every claim here is backed by a smoke test in
[`terraform/examples/client-tests/`](../terraform/examples/client-tests/) — the
check id (e.g. `C4`) is cited in the tables. Results below were **verified live**
on project `gcp-llm-gateway-cabral` (Gemini 3.5-flash / 3.1-pro, Claude Opus 4.7,
DeepSeek v3.2-maas).

---

## 1. The short answer

You are **not** limited to OpenAI `/chat/completions`. There are **three access
tiers**, trading governance for native fidelity:

| Tier | You send | Endpoint(s) | Native fidelity | Governance (keys / budgets / rate-limits / routing / fallbacks / cost) |
|---|---|---|---|---|
| **1. Unified (OpenAI)** | OpenAI format | `/v1/chat/completions`, `/v1/embeddings`, `/v1/rerank`, `/v1/responses`, `/v1/models` | Medium — native features via provider params / `extra_body` | **Full** |
| **2. Alternate native (translated)** | Anthropic Messages format | `/v1/messages` | High — Anthropic features (tools, thinking, caching), works against *any* backend | **Full** (cost, logging, guardrails, routing) |
| **3. Provider passthrough** | The provider's own **native** payload | `/vertex_ai/…:generateContent`, `…:rawPredict` | **Full** — exact Vertex API, native SDKs | **Reduced** — key-auth + logging only (see §5) |

Rule of thumb: **stay on Tier 1/2 for governance** (budgets, rate-limits,
load-balancing, spend), **drop to Tier 3 only when a client needs native payload
fidelity** an OpenAI/Anthropic shape can't express.

---

## 2. Choose by SDK / client style

| Your client | Use | Endpoint | Fidelity | Governance | Verified |
|---|---|---|---|---|---|
| OpenAI SDK / `curl` | `OpenAI(base_url=".../v1")` | `/v1/chat/completions` | Medium | **Full** | C1, C7–C9, C11 |
| Anthropic SDK | `anthropic.Anthropic(base_url=…)` | `/v1/messages` | High (Anthropic) | **Full** | C3, C10 |
| Google GenAI SDK (`google-genai`) | `genai.Client(vertexai=True, http_options=base_url=".../vertex_ai")` + `x-litellm-api-key` header | `/vertex_ai/*` passthrough | **Full** (native Gemini) | **Reduced** | C6 |
| Native `curl` (Gemini/Claude) | `x-litellm-api-key: Bearer sk-…` | `/vertex_ai/…:generateContent` / `:rawPredict` | **Full** | **Reduced** | C4, C5 |

> **`AnthropicVertex` SDK is *not* supported** against the gateway. Use the plain
> `anthropic.Anthropic(base_url=…)` client → `/v1/messages` to reach Claude-on-Vertex
> in Anthropic format (verified, C3/C10).

All calls authenticate with a **LiteLLM key** (master key or a virtual key). The
gateway holds the Google credentials (runtime service account, keyless ADC) — clients
never send a Google OAuth token.

---

## 3. Quickstarts

Resolve the endpoint + a key first:

```bash
BASE_URL=$(terraform output -raw lb_url)              # e.g. https://<ip>.nip.io
MK=$(gcloud secrets versions access latest \
      --secret="$(terraform output -raw master_key_secret_id)" \
      --project="$(terraform output -raw project_id)")
```

### 3a. OpenAI format (any model) — Tier 1

```bash
curl -s "$BASE_URL/v1/chat/completions" -H "Authorization: Bearer $MK" \
  -H "Content-Type: application/json" \
  -d '{"model":"claude-opus","messages":[{"role":"user","content":"hi"}]}'
```
```python
from openai import OpenAI
c = OpenAI(base_url=f"{BASE_URL}/v1", api_key=MK)
c.chat.completions.create(model="gemini-3.5-flash",
                          messages=[{"role":"user","content":"hi"}])
```
Model names are whatever you registered: `gemini-3.5-flash`, `gemini-3.1-pro-preview`,
`claude-opus`, `deepseek` (see §6).

### 3b. Anthropic Messages format — Tier 2

```python
import anthropic
c = anthropic.Anthropic(base_url=BASE_URL, api_key=MK)   # -> /v1/messages
c.messages.create(model="claude-opus", max_tokens=256,
                  messages=[{"role":"user","content":"hi"}])
# Cross-provider: the same client can target model="gemini-3.5-flash" (C3).
```

### 3c. Native Gemini via the Google GenAI SDK — Tier 3 (passthrough)

```python
from google import genai
from google.genai import types
client = genai.Client(
    vertexai=True, project=PROJECT, location="us-central1",
    http_options=types.HttpOptions(
        base_url=f"{BASE_URL}/vertex_ai",
        headers={"x-litellm-api-key": f"Bearer {MK}"}))   # gateway auth
client.models.generate_content(model="gemini-3.5-flash",
                               contents="hi")               # native generateContent (C6)
```

### 3d. Native `curl` passthrough (Gemini `generateContent`, Claude `rawPredict`)

```bash
curl -s "$BASE_URL/vertex_ai/v1/projects/$PROJECT/locations/global/publishers/google/models/gemini-3.5-flash:generateContent" \
  -H "x-litellm-api-key: Bearer $MK" -H "Content-Type: application/json" \
  -d '{"contents":[{"role":"user","parts":[{"text":"hi"}]}]}'          # C4
```

---

## 4. Native features (through the unified path)

Any non-OpenAI param is forwarded to the provider, so Gemini/Claude features work
over `/v1/chat/completions` ([provider params](https://docs.litellm.ai/docs/completion/provider_specific_params)).

- **Gemini `google_search` grounding** — `tools:[{"googleSearch":{}}]` (older models
  `googleSearchRetrieval`); response carries `groundingMetadata` (C7). **Cannot be
  combined with function-calling tools** in the same request — LiteLLM silently drops
  the search tool ([web_search](https://docs.litellm.ai/docs/completion/web_search)).
- **Structured output** — `response_format:{"type":"json_schema","json_schema":{…}}`
  (verified on Gemini, Claude, *and* DeepSeek, C8).
- **Reasoning** — `reasoning_effort` (Gemini thinking budget) / Anthropic `thinking`
  (Claude). Verified Gemini + Claude (C9); **DeepSeek MaaS: not mapped** — see §5.
- **Gemini `safety_settings`** — passed inline per request (C9).
- **Anthropic tool use / prompt caching** — via `/v1/messages` (tool use verified on
  Claude, C10).

---

## 5. Limitations & assumptions (read this)

### 5a. Governance vs. passthrough — the core trade-off

On **Tier 3 passthrough** (`/vertex_ai/*`), LiteLLM applies **key auth + logging**,
but per the upstream docs it does **not** apply budgets, rate-limits, load-balancing,
fallbacks, or end-user tracking, and **cost tracking is only asserted for
`generateContent`** (not `rawPredict`/`predict`). Use Tier 1/2 when you need spend
controls or routing. Source: [pass_through/vertex_ai](https://docs.litellm.ai/docs/pass_through/vertex_ai).

| Capability | Tier 1/2 (unified, `/v1/messages`) | Tier 3 (passthrough) |
|---|---|---|
| Virtual-key auth | ✅ | ✅ |
| Logging / tracing | ✅ | ✅ |
| Cost / spend tracking | ✅ | ⚠️ `generateContent` only |
| Budgets / rate-limits | ✅ | ❌ |
| Routing / load-balancing / fallbacks | ✅ | ❌ |
| End-user tracking | ✅ | ❌ |

> **Passthrough requires `use_in_pass_through: true`.** For the proxy to inject the
> service account's ADC on a passthrough call, a registered model must have
> `use_in_pass_through: true` matching the request's **project + location** — otherwise
> Vertex returns `401 CREDENTIALS_MISSING`. This module enables it on all
> auto-registered Vertex models, so passthrough works out of the box for the
> project/regions you register (C4/C5). Credential match is by project+region, not by
> model id.

### 5b. Feature support — where the limit is the *model* vs *LiteLLM*

Legend: ✅ verified · ⚠️ conditional · ❌ unsupported · ➖ n/a · *D* doc-based (not auto-tested).

| Feature | Gemini | Claude Opus | DeepSeek v3.2 | Where the limit is |
|---|---|---|---|---|
| `/chat/completions` (unified) | ✅ | ✅ | ✅ | — |
| Streaming (SSE) | ✅ | ✅ *D* | ✅ *D* | — |
| Anthropic `/v1/messages` | ✅ (x-prov) | ✅ | ✅ *D* (x-prov) | — |
| `google_search` grounding | ✅ | ❌ | ❌ | **Model** — Gemini-only feature |
| Structured output (`json_schema`) | ✅ | ✅ | ✅ | — |
| Reasoning (`reasoning_effort`) | ✅ | ✅ | ⚠️ | **LiteLLM** — not mapped for DeepSeek MaaS |
| `safety_settings` | ✅ | ➖ | ➖ | **Model** — Gemini param |
| Tool use / function calling | ✅ *D* | ✅ | ✅ *D* | — |
| Prompt caching | ✅ *D* (Gemini caching) | ✅ *D* | ❓ | **Model** |
| Native passthrough | ✅ `generateContent` | ✅ `rawPredict` | ➖ | **Route** — DeepSeek is OpenAI-compatible MaaS (no native passthrough); use Tier 1 |

Notes on the two confirmed gaps:
- **DeepSeek + `reasoning_effort`** → LiteLLM raises `UnsupportedParamsError` (the
  provider mapping doesn't accept it). To send it anyway, add
  `extra_body={"allowed_openai_params":["reasoning_effort"]}` per request, or set
  `drop_params: true`. (DeepSeek's own thinking mode may still be reachable via native
  params; validate against your model version.)
- **`google_search` is Gemini-only** — Claude/DeepSeek on Vertex do not expose it.

### 5c. Assumptions
- All models are on **Vertex AI**, keyless via the runtime SA (ADC). Partner/MaaS
  models (Claude, DeepSeek) must be **enabled in Vertex Model Garden** (terms/quota)
  and registered — see §6. DeepSeek MaaS is **region-limited** and has **no outbound
  internet egress**.
- Clients hold a **LiteLLM key**, never a Google credential.

---

## 6. Registering models

Gemini is auto-registered from `vertex_gemini_models` (default global). Partner/MaaS
models use `vertex_partner_models` (per-model region), since they are region-specific:

```hcl
vertex_partner_models = [
  { model_name = "claude-opus", model = "vertex_ai/claude-opus-4-7",              vertex_location = "global" },
  { model_name = "deepseek",    model = "vertex_ai/deepseek-ai/deepseek-v3.2-maas", vertex_location = "us-central1" },
]
```
`model_name` is the name clients call; `model` is the full LiteLLM id. Both Gemini and
partner entries get `use_in_pass_through = true` automatically. Model-name conventions:
Gemini `vertex_ai/gemini-…`, Claude `vertex_ai/claude-…`, DeepSeek
`vertex_ai/deepseek-ai/<model>-maas`
([vertex](https://docs.litellm.ai/docs/providers/vertex),
[vertex_partner](https://docs.litellm.ai/docs/providers/vertex_partner)).

---

## 7. Reproduce the tests

```bash
# from terraform/ after apply
examples/client-tests/api-smoke.sh          # core: curl + stdlib (C0–C5, C7–C9, C11)
examples/client-tests/sdk/run.sh            # vendor SDKs: OpenAI/Anthropic/google-genai (C1,C3,C6,C7,C10)
```
Last verified run: **17 passed, 0 failed, 2 skipped (Gemini-only grounding), 1
documented-limit (DeepSeek reasoning)**. See
[`terraform/examples/client-tests/README.md`](../terraform/examples/client-tests/README.md).

Related: [`ARCHITECTURE.md`](./ARCHITECTURE.md) (request lifecycle, security),
[`terraform/README.md`](../terraform/README.md) (deploy + Vertex easy-button).
