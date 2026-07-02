#!/usr/bin/env bash
#
# End-to-end smoke test for the deployed LiteLLM gateway.
#
# Reads the LB URL, project, and master-key secret straight from Terraform
# outputs, then:
#   1) GET  /health/liveliness         (no auth)
#   2) GET  /v1/models                 (auth — lists configured models)
#   3) POST /v1/chat/completions       (auth — calls the chosen model)
#
# Usage (from the terraform/ directory, after `terraform apply`):
#   ./examples/smoke-test.sh [MODEL_NAME]
#
# MODEL_NAME defaults to "gemini-flash" (the model_name you gave the Vertex
# entry in proxy_config). Override BASE_URL / MASTER_KEY to skip the Terraform
# and gcloud lookups.
#
# Requires: terraform, gcloud, curl, python3.

set -euo pipefail

MODEL="${1:-gemini-3.5-flash}"

# --- Resolve connection details from Terraform state (unless overridden) ---
BASE_URL="${BASE_URL:-$(terraform output -raw lb_url)}"
if [[ -z "${MASTER_KEY:-}" ]]; then
  PROJECT="$(terraform output -raw project_id)"
  SECRET="$(terraform output -raw master_key_secret_id)"
  MASTER_KEY="$(gcloud secrets versions access latest --secret="$SECRET" --project="$PROJECT")"
fi

echo "Gateway : $BASE_URL"
echo "Model   : $MODEL"
echo

# --- 1) Liveness (no auth) ---------------------------------------------------
echo "[1/3] GET /health/liveliness"
code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 20 "$BASE_URL/health/liveliness")
echo "      -> HTTP $code"
[[ "$code" == "200" ]] || { echo "gateway not healthy yet (LB can take a few minutes to warm)"; exit 1; }

# --- 2) List models (auth) ---------------------------------------------------
echo "[2/3] GET /v1/models"
curl -s --max-time 20 -H "Authorization: Bearer $MASTER_KEY" "$BASE_URL/v1/models" \
  | python3 -c "import sys,json; d=json.load(sys.stdin); print('      models:', [m.get('id') for m in d.get('data',[])])"

# --- 3) Chat completion (auth) ----------------------------------------------
echo "[3/3] POST /v1/chat/completions  (model=$MODEL)"
resp=$(curl -s --max-time 60 -H "Authorization: Bearer $MASTER_KEY" -H "Content-Type: application/json" \
  -d "{\"model\":\"$MODEL\",\"messages\":[{\"role\":\"user\",\"content\":\"Reply with exactly: gateway ok\"}]}" \
  "$BASE_URL/v1/chat/completions")

echo "$resp" | python3 -c "
import sys,json
d=json.load(sys.stdin)
if 'error' in d:
    print('      ERROR:', json.dumps(d['error'])[:400]); sys.exit(1)
msg=d['choices'][0]['message']['content']
usage=d.get('usage',{})
print('      model :', d.get('model'))
print('      reply :', msg.strip()[:200])
print('      usage :', usage)
print()
print('SMOKE TEST PASSED')
"
