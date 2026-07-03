#!/usr/bin/env bash
# Client-facing API smoke suite for the LiteLLM gateway (Vertex-hosted models).
#
# Proves, one check per claim, what a CLIENT can send through the gateway:
#   - Unified OpenAI format (/v1/chat/completions, /v1/models, streaming)
#   - Native Gemini features via the unified path (google_search grounding,
#     structured output, reasoning + safety_settings)
#   - Anthropic Messages format (/v1/messages) — cross-provider + Claude
#   - Vertex passthrough (/vertex_ai/...:generateContent, :rawPredict) native payloads
#   - Virtual-key governance on the unified path
#
# Zero pip dependencies (curl + stdlib python3). For the vendor-SDK proofs
# (openai / anthropic / google-genai clients) see ./sdk/.
#
# Usage (from terraform/ after apply):   examples/client-tests/api-smoke.sh
# Or point at any deployment:            BASE_URL=https://host MASTER_KEY=sk-... examples/client-tests/api-smoke.sh
#
# Model names (override via env to match what you registered / enabled):
#   GEMINI_MODEL   (default gemini-3.5-flash)
#   CLAUDE_MODEL   (default claude-sonnet)      # from vertex_partner_models
#   DEEPSEEK_MODEL (default deepseek)           # from vertex_partner_models
# Partner-model checks SKIP (not fail) when the model is not in /v1/models.
set -uo pipefail

GEMINI_MODEL="${GEMINI_MODEL:-gemini-3.5-flash}"
CLAUDE_MODEL="${CLAUDE_MODEL:-claude-opus}"       # model_name from vertex_partner_models
DEEPSEEK_MODEL="${DEEPSEEK_MODEL:-deepseek}"
# Vertex passthrough targets (native REST). Must match a registered model's
# project+location (use_in_pass_through) so the proxy injects its SA credentials.
PT_LOCATION="${PT_LOCATION:-global}"
PT_GEMINI="${PT_GEMINI:-$GEMINI_MODEL}"
PT_CLAUDE="${PT_CLAUDE:-claude-opus-4-7}"
PT_CLAUDE_LOCATION="${PT_CLAUDE_LOCATION:-global}"

# ---- resolve endpoint + credentials (same pattern as examples/smoke-test.sh) ----
have() { command -v "$1" >/dev/null 2>&1; }
if [[ -z "${BASE_URL:-}" ]]; then BASE_URL="$(terraform output -raw lb_url 2>/dev/null)"; fi
PROJECT="${PROJECT:-$(terraform output -raw project_id 2>/dev/null)}"
if [[ -z "${MASTER_KEY:-}" ]]; then
  SECRET="$(terraform output -raw master_key_secret_id 2>/dev/null)"
  if [[ -n "$SECRET" && -n "$PROJECT" ]]; then
    MASTER_KEY="$(gcloud secrets versions access latest --secret="$SECRET" --project="$PROJECT" 2>/dev/null)"
  fi
fi
if [[ -z "${BASE_URL:-}" || -z "${MASTER_KEY:-}" ]]; then
  echo "ERROR: set BASE_URL and MASTER_KEY (or run from terraform/ after apply)." >&2
  exit 2
fi
CURL=(curl -sk --max-time 60)
AUTH=(-H "Authorization: Bearer ${MASTER_KEY}")
JSON=(-H "Content-Type: application/json")

PASS=0; FAIL=0; SKIP=0; LIMIT=0
pass()  { printf '  \033[32mPASS\033[0m  %s\n' "$1"; PASS=$((PASS+1)); }
fail()  { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; [[ -n "${2:-}" ]] && printf '        %s\n' "$2"; FAIL=$((FAIL+1)); }
skip()  { printf '  \033[33mSKIP\033[0m  %s\n' "$1"; [[ -n "${2:-}" ]] && printf '        %s\n' "$2"; SKIP=$((SKIP+1)); }
# LIMIT = a confirmed, documented limitation (model or LiteLLM). Informational; does
# not fail the suite. See docs/CLIENT_GUIDE.md feature matrix.
limit() { printf '  \033[35mLIMIT\033[0m %s\n' "$1"; [[ -n "${2:-}" ]] && printf '        %s\n' "$2"; LIMIT=$((LIMIT+1)); }
# jq-free JSON probe: py '<expr>' reads stdin as `d`; prints result, exit 1 on error.
py() { python3 -c "import sys,json
try:
    d=json.load(sys.stdin)
    print($1)
except Exception as e:
    sys.stderr.write(str(e)); sys.exit(1)"; }

echo "== gateway client-API smoke =="
echo "   BASE_URL=$BASE_URL  project=$PROJECT"
echo "   models: gemini=$GEMINI_MODEL claude=$CLAUDE_MODEL deepseek=$DEEPSEEK_MODEL"
echo

# Which models are actually registered? (drives SKIP for partner models)
MODELS_JSON="$(${CURL[@]} "${AUTH[@]}" "$BASE_URL/v1/models" 2>/dev/null)"
model_present() { echo "$MODELS_JSON" | py "'$1' in [m['id'] for m in d.get('data',[])]" 2>/dev/null | grep -q True; }

chat() { # chat <model> <extra-json-fields>
  local model="$1" extra="${2:-}"
  ${CURL[@]} "${AUTH[@]}" "${JSON[@]}" "$BASE_URL/v1/chat/completions" \
    -d "{\"model\":\"$model\",\"messages\":[{\"role\":\"user\",\"content\":\"Reply with exactly: gateway ok\"}]${extra:+,$extra}}"
}

# ---------------------------------------------------------------------------
# C0. Liveness (no auth) + model catalog
# ---------------------------------------------------------------------------
code="$(${CURL[@]} -o /dev/null -w '%{http_code}' "$BASE_URL/health/liveliness")"
[[ "$code" == "200" ]] && pass "C0a liveness 200" || fail "C0a liveness" "HTTP $code"
if echo "$MODELS_JSON" | py "len(d['data'])>=1" >/dev/null 2>&1; then
  pass "C0b GET /v1/models ($(echo "$MODELS_JSON" | py "','.join(m['id'] for m in d['data'])" 2>/dev/null))"
else
  fail "C0b GET /v1/models" "$MODELS_JSON"
fi

# ---------------------------------------------------------------------------
# C1. Unified OpenAI /v1/chat/completions — per model family
# ---------------------------------------------------------------------------
r="$(chat "$GEMINI_MODEL")"
echo "$r" | py "bool(d['choices'][0]['message']['content'])" >/dev/null 2>&1 \
  && pass "C1 gemini /chat/completions" || fail "C1 gemini /chat/completions" "$r"

for pair in "claude:$CLAUDE_MODEL" "deepseek:$DEEPSEEK_MODEL"; do
  label="${pair%%:*}"; m="${pair#*:}"
  if model_present "$m"; then
    r="$(chat "$m")"
    echo "$r" | py "bool(d['choices'][0]['message']['content'])" >/dev/null 2>&1 \
      && pass "C1 $label /chat/completions ($m)" || fail "C1 $label /chat/completions" "$r"
  else
    skip "C1 $label /chat/completions" "model '$m' not in /v1/models — enable in Model Garden + register"
  fi
done

# ---------------------------------------------------------------------------
# C2. Streaming (SSE)
# ---------------------------------------------------------------------------
s="$(${CURL[@]} -N "${AUTH[@]}" "${JSON[@]}" "$BASE_URL/v1/chat/completions" \
      -d "{\"model\":\"$GEMINI_MODEL\",\"stream\":true,\"messages\":[{\"role\":\"user\",\"content\":\"count to 3\"}]}")"
echo "$s" | grep -q "data:" && pass "C2 streaming SSE chunks" || fail "C2 streaming" "no data: chunks"

# ---------------------------------------------------------------------------
# C7. google_search grounding (unified path; NO function tools)
# ---------------------------------------------------------------------------
g="$(${CURL[@]} "${AUTH[@]}" "${JSON[@]}" "$BASE_URL/v1/chat/completions" \
      -d "{\"model\":\"$GEMINI_MODEL\",\"messages\":[{\"role\":\"user\",\"content\":\"Who won the 2022 FIFA World Cup? Use search.\"}],\"tools\":[{\"googleSearch\":{}}]}")"
if echo "$g" | grep -qiE "grounding|webSearchQueries|groundingMetadata"; then
  pass "C7 grounding (groundingMetadata present)"
elif echo "$g" | py "bool(d['choices'][0]['message']['content'])" >/dev/null 2>&1; then
  fail "C7 grounding" "200 with content but no grounding metadata in body"
else
  fail "C7 grounding" "$g"
fi

# ---------------------------------------------------------------------------
# C8. Structured output (response_format json_schema)
# ---------------------------------------------------------------------------
schema='"response_format":{"type":"json_schema","json_schema":{"name":"city","strict":true,"schema":{"type":"object","properties":{"city":{"type":"string"},"country":{"type":"string"}},"required":["city","country"],"additionalProperties":false}}}'
o="$(${CURL[@]} "${AUTH[@]}" "${JSON[@]}" "$BASE_URL/v1/chat/completions" \
      -d "{\"model\":\"$GEMINI_MODEL\",\"messages\":[{\"role\":\"user\",\"content\":\"Return the capital of France as JSON.\"}],$schema}")"
if echo "$o" | py "json.loads(d['choices'][0]['message']['content']).get('city') is not None" >/dev/null 2>&1; then
  pass "C8 structured output (schema-valid JSON)"
else
  fail "C8 structured output" "$o"
fi

# ---------------------------------------------------------------------------
# C9. Reasoning + safety_settings pass-through
# ---------------------------------------------------------------------------
r9="$(chat "$GEMINI_MODEL" '"reasoning_effort":"low","safety_settings":[{"category":"HARM_CATEGORY_DANGEROUS_CONTENT","threshold":"BLOCK_ONLY_HIGH"}]')"
echo "$r9" | py "bool(d['choices'][0]['message']['content'])" >/dev/null 2>&1 \
  && pass "C9 reasoning_effort + safety_settings (gemini)" || fail "C9 reasoning + safety (gemini)" "$r9"

# ---------------------------------------------------------------------------
# Feature x model matrix — documents where a limit is the MODEL vs LiteLLM.
# A FAIL on a partner model here is informative (the model/route may not support
# that feature natively), not necessarily a gateway bug — see docs/CLIENT_GUIDE.md.
# ---------------------------------------------------------------------------
struct_probe() { # struct_probe <model> -> prints JSON with a 'city' field if supported
  ${CURL[@]} "${AUTH[@]}" "${JSON[@]}" "$BASE_URL/v1/chat/completions" \
    -d "{\"model\":\"$1\",\"messages\":[{\"role\":\"user\",\"content\":\"Return the capital of France as JSON.\"}],$schema}"
}
for pair in "claude:$CLAUDE_MODEL" "deepseek:$DEEPSEEK_MODEL"; do
  label="${pair%%:*}"; m="${pair#*:}"
  if ! model_present "$m"; then
    skip "C7/C8/C9 features ($label)" "model '$m' not registered"
    continue
  fi
  # grounding is a Gemini-only capability (google_search): documented, not tested here
  skip "C7 grounding ($label)" "google_search is Gemini-only (not supported by $label)"
  # structured output (native JSON schema)
  os="$(struct_probe "$m")"
  echo "$os" | py "json.loads(d['choices'][0]['message']['content']).get('city') is not None" >/dev/null 2>&1 \
    && pass "C8 structured output ($label)" \
    || fail "C8 structured output ($label)" "no schema-valid JSON (model/route may lack native json_schema)"
  # reasoning (Claude 'thinking' / DeepSeek thinking mode mapped from reasoning_effort)
  rr="$(chat "$m" '"reasoning_effort":"low"')"
  if echo "$rr" | py "bool(d['choices'][0]['message']['content'])" >/dev/null 2>&1; then
    pass "C9 reasoning ($label)"
  elif echo "$rr" | grep -q "UnsupportedParamsError"; then
    limit "C9 reasoning ($label)" "LiteLLM does not map reasoning_effort for this provider — send allowed_openai_params=['reasoning_effort'] or set drop_params"
  else
    fail "C9 reasoning ($label)" "$rr"
  fi
done

# ---------------------------------------------------------------------------
# C3. Anthropic Messages /v1/messages — cross-provider (Gemini) + Claude
# ---------------------------------------------------------------------------
msg() { # msg <model>
  ${CURL[@]} "${AUTH[@]}" "${JSON[@]}" -H "anthropic-version: 2023-06-01" "$BASE_URL/v1/messages" \
    -d "{\"model\":\"$1\",\"max_tokens\":64,\"messages\":[{\"role\":\"user\",\"content\":\"Reply with exactly: gateway ok\"}]}"
}
m3="$(msg "$GEMINI_MODEL")"
echo "$m3" | py "d['content'][0]['text'] is not None" >/dev/null 2>&1 \
  && pass "C3 /v1/messages cross-provider (gemini)" || fail "C3 /v1/messages (gemini)" "$m3"
if model_present "$CLAUDE_MODEL"; then
  mc="$(msg "$CLAUDE_MODEL")"
  echo "$mc" | py "d['content'][0]['text'] is not None" >/dev/null 2>&1 \
    && pass "C3 /v1/messages (claude)" || fail "C3 /v1/messages (claude)" "$mc"
else
  skip "C3 /v1/messages (claude)" "model '$CLAUDE_MODEL' not registered"
fi

# ---------------------------------------------------------------------------
# C4. Vertex passthrough — native Gemini generateContent
# ---------------------------------------------------------------------------
if [[ -n "$PROJECT" ]]; then
  gc_path="/vertex_ai/v1/projects/$PROJECT/locations/$PT_LOCATION/publishers/google/models/$PT_GEMINI:generateContent"
  gc="$(${CURL[@]} -H "x-litellm-api-key: Bearer ${MASTER_KEY}" "${JSON[@]}" "$BASE_URL$gc_path" \
        -d '{"contents":[{"role":"user","parts":[{"text":"Reply with exactly: gateway ok"}]}]}')"
  if echo "$gc" | py "bool(d['candidates'][0]['content']['parts'][0]['text'])" >/dev/null 2>&1; then
    pass "C4 passthrough generateContent (native Gemini, vkey auth)"
  else
    fail "C4 passthrough generateContent" "$gc_path -> $gc"
  fi
else
  skip "C4 passthrough generateContent" "project id unavailable"
fi

# ---------------------------------------------------------------------------
# C5. Vertex passthrough — native Claude rawPredict
# ---------------------------------------------------------------------------
if [[ -n "$PROJECT" ]] && model_present "$CLAUDE_MODEL"; then
  rp_path="/vertex_ai/v1/projects/$PROJECT/locations/$PT_CLAUDE_LOCATION/publishers/anthropic/models/$PT_CLAUDE:rawPredict"
  rp="$(${CURL[@]} -H "x-litellm-api-key: Bearer ${MASTER_KEY}" "${JSON[@]}" "$BASE_URL$rp_path" \
        -d '{"anthropic_version":"vertex-2023-10-16","max_tokens":64,"messages":[{"role":"user","content":"Reply with exactly: gateway ok"}]}')"
  if echo "$rp" | py "d['content'][0]['text'] is not None" >/dev/null 2>&1; then
    pass "C5 passthrough rawPredict (native Claude)"
  else
    fail "C5 passthrough rawPredict" "$rp_path -> $rp"
  fi
else
  skip "C5 passthrough rawPredict (claude)" "claude not registered or project unavailable"
fi

# ---------------------------------------------------------------------------
# C11. Virtual-key governance on the unified path
# ---------------------------------------------------------------------------
kg="$(${CURL[@]} "${AUTH[@]}" "${JSON[@]}" "$BASE_URL/key/generate" \
      -d "{\"key_alias\":\"smoke-$$\",\"models\":[\"$GEMINI_MODEL\"],\"max_budget\":1}")"
VKEY="$(echo "$kg" | py "d.get('key','')" 2>/dev/null)"
if [[ -n "$VKEY" ]]; then
  rv="$(${CURL[@]} -H "Authorization: Bearer $VKEY" "${JSON[@]}" "$BASE_URL/v1/chat/completions" \
        -d "{\"model\":\"$GEMINI_MODEL\",\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}]}")"
  echo "$rv" | py "bool(d['choices'][0]['message']['content'])" >/dev/null 2>&1 \
    && pass "C11 virtual key works on /chat/completions" || fail "C11 virtual key call" "$rv"
  ${CURL[@]} "${AUTH[@]}" "${JSON[@]}" "$BASE_URL/key/delete" -d "{\"keys\":[\"$VKEY\"]}" >/dev/null 2>&1
else
  fail "C11 virtual key mint" "$kg"
fi

echo
echo "== summary: $PASS passed, $FAIL failed, $SKIP skipped, $LIMIT documented-limits =="
[[ "$FAIL" -eq 0 ]]
