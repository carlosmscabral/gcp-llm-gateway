# Client-API smoke tests

Prove — one check per claim — how a **client** can call Vertex-hosted models through
the gateway, and where the trade-off between **native fidelity** and **governance**
lands. Companion to [`docs/CLIENT_GUIDE.md`](../../../docs/CLIENT_GUIDE.md), which
explains the results and limitations.

Two layers:

| Layer | File | Deps | Proves |
|---|---|---|---|
| Core | [`api-smoke.sh`](./api-smoke.sh) | `curl` + stdlib `python3` (zero pip) | Endpoints accept OpenAI / Anthropic / native-Vertex payloads; features; virtual-key governance |
| SDK | [`sdk/`](./sdk) | Python venv (`openai`, `anthropic`, `google-genai`) | The real vendor SDK clients work against the gateway |

## Run

From the `terraform/` directory after `apply` (auto-resolves LB URL + master key
from Terraform outputs / Secret Manager):

```bash
examples/client-tests/api-smoke.sh          # core suite
examples/client-tests/sdk/run.sh            # optional vendor-SDK suite (builds a venv)
```

Against any deployment, pass creds explicitly:

```bash
BASE_URL=https://<host> MASTER_KEY=sk-... examples/client-tests/api-smoke.sh
```

## Model names (env overrides)

Defaults match `dev.tfvars`. Override to match what you registered / enabled in
Vertex Model Garden:

| Env | Default | Notes |
|---|---|---|
| `GEMINI_MODEL` | `gemini-3.5-flash` | native Gemini (global) |
| `CLAUDE_MODEL` | `claude-opus` | `model_name` of the Claude `vertex_partner_models` entry |
| `DEEPSEEK_MODEL` | `deepseek` | DeepSeek MaaS `model_name` |
| `PT_GEMINI` / `PT_LOCATION` | `gemini-3.5-flash` / `us-central1` | native passthrough target (publisher id + region) |
| `PT_CLAUDE` / `PT_CLAUDE_LOCATION` | `claude-opus-4-7` / `global` | native `:rawPredict` target |

## Reading the output

- **PASS** — claim holds. **FAIL** — claim broke (or a feature the model/route does
  not support natively — see the note in the guide). **SKIP** — precondition missing
  (model not registered/enabled, or a capability that is model-specific, e.g.
  `google_search` grounding is Gemini-only).
- Partner-model checks (`claude`, `deepseek`) SKIP until those models are enabled in
  Vertex Model Garden and registered via `vertex_partner_models`.

## Checks

`C0` liveness + `/v1/models` · `C1` unified `/chat/completions` per family ·
`C2` streaming · `C3` Anthropic `/v1/messages` (cross-provider + Claude) ·
`C4` Vertex passthrough `:generateContent` · `C5` passthrough `:rawPredict` (Claude) ·
`C6` google-genai SDK via passthrough (SDK suite) · `C7` `google_search` grounding ·
`C8` structured output · `C9` reasoning + `safety_settings` · `C10` Anthropic tool use
(SDK suite) · `C11` virtual-key governance.
