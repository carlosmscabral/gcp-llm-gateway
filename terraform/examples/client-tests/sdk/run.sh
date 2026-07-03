#!/usr/bin/env bash
# Optional vendor-SDK smoke tests: prove the real OpenAI / Anthropic / google-genai
# clients work against the gateway. Creates a local venv (pip deps) — this is the
# one part of the repo that is NOT dependency-free.
#
# Usage (from terraform/ after apply):  examples/client-tests/sdk/run.sh
# Or:                                   BASE_URL=... MASTER_KEY=sk-... .../sdk/run.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"

: "${BASE_URL:=$(terraform output -raw lb_url 2>/dev/null)}"
: "${PROJECT:=$(terraform output -raw project_id 2>/dev/null)}"
if [[ -z "${MASTER_KEY:-}" && -n "${PROJECT:-}" ]]; then
  MASTER_KEY="$(gcloud secrets versions access latest \
    --secret="$(terraform output -raw master_key_secret_id 2>/dev/null)" \
    --project="$PROJECT" 2>/dev/null)"
fi
export BASE_URL PROJECT MASTER_KEY
: "${GEMINI_MODEL:=gemini-3.5-flash}"; export GEMINI_MODEL
: "${CLAUDE_MODEL:=claude-opus}";     export CLAUDE_MODEL
: "${PT_LOCATION:=us-central1}";      export PT_LOCATION
if [[ -z "${BASE_URL:-}" || -z "${MASTER_KEY:-}" ]]; then
  echo "ERROR: set BASE_URL and MASTER_KEY (or run from terraform/ after apply)." >&2
  exit 2
fi

VENV="$HERE/.venv"
[[ -d "$VENV" ]] || python3 -m venv "$VENV"
"$VENV/bin/pip" -q install --disable-pip-version-check -r "$HERE/requirements.txt"

rc=0
for t in test_openai test_anthropic test_genai; do
  echo "== $t =="
  "$VENV/bin/python" "$HERE/$t.py" || rc=1
  echo
done
echo "== SDK suite done (rc=$rc) =="
exit $rc
