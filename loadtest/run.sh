#!/usr/bin/env bash
# Repeatable load-test orchestrator for the LiteLLM gateway.
#
#   ./run.sh build      build+push the k6 image to the STANDARD AR repo (once)
#   ./run.sh setup      mint virtual keys, upload per-run config to GCS
#   ./run.sh run        set task count + execute the k6 Cloud Run Job (--wait)
#   ./run.sh collect    pull k6 summaries + query Cloud Monitoring -> report.md
#   ./run.sh teardown   delete the run's virtual keys + per-run config
#   ./run.sh all        setup -> run -> collect -> teardown
#
# Scale/shape live in config.json. Requires terraform, gcloud, python3, and the
# stack deployed with enable_loadtest=true. Base LiteLLM setup is never touched.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
TFDIR="$HERE/../terraform"
CFG="${CONFIG:-$HERE/config.json}"
RESULTS="$HERE/results"
CURRENT="$HERE/.current_run"
export PATH="$HOME/.local/bin:$PATH"

tfout() { terraform -chdir="$TFDIR" output -raw "$1" 2>/dev/null; }

resolve() {
  PROJECT="$(tfout project_id)"
  REGION="$(tfout region)"
  BASE_URL="$(tfout lb_url)"
  JOB="$(tfout loadtest_job_name)"
  BUCKET="$(tfout loadtest_results_bucket)"
  REPO="$(tfout loadtest_ar_repo)"
  SQLCONN="$(tfout cloudsql_connection_name)"
  if [ -z "${JOB:-}" ]; then
    echo "load-test resources not deployed — apply with: terraform apply -var enable_loadtest=true" >&2
    exit 1
  fi
  NAMEPREFIX="${JOB%-loadtest}"
  IMG="${REGION}-docker.pkg.dev/${PROJECT}/${REPO}/k6:latest"
}

masterkey() { gcloud secrets versions access latest --secret="$(tfout master_key_secret_id)" --project="$PROJECT"; }

cmd_build() {
  resolve
  echo "building k6 image -> $IMG"
  gcloud builds submit "$HERE/k6" --tag "$IMG" --project="$PROJECT"
}

cmd_setup() {
  resolve
  RUN_ID="$(date -u +%Y%m%d-%H%M%S)"
  echo "$RUN_ID" >"$CURRENT"
  OUT="$RESULTS/$RUN_ID"; mkdir -p "$OUT"
  echo "run_id=$RUN_ID  base_url=$BASE_URL"
  python3 "$HERE/lib/harness.py" setup \
    --base-url "$BASE_URL" --master-key "$(masterkey)" \
    --config "$CFG" --out "$OUT" --run-id "$RUN_ID"
  gcloud storage cp "$OUT/config.json" "gs://$BUCKET/runs/current/config.json" --project="$PROJECT"
}

cmd_run() {
  resolve
  RUN_ID="$(cat "$CURRENT")"
  OUT="$RESULTS/$RUN_ID"
  TASKS="$(python3 -c "import json;print(json.load(open('$CFG')).get('tasks',1))")"
  echo "executing $JOB with $TASKS task(s)"
  gcloud run jobs update "$JOB" --region "$REGION" --project "$PROJECT" \
    --tasks="$TASKS" --parallelism="$TASKS" --quiet
  date -u +%Y-%m-%dT%H:%M:%SZ >"$OUT/.start"
  gcloud run jobs execute "$JOB" --region "$REGION" --project "$PROJECT" --wait
  date -u +%Y-%m-%dT%H:%M:%SZ >"$OUT/.end"
  echo "window: $(cat "$OUT/.start") -> $(cat "$OUT/.end")"
}

cmd_collect() {
  resolve
  RUN_ID="$(cat "$CURRENT")"
  OUT="$RESULTS/$RUN_ID"
  gcloud storage cp "gs://$BUCKET/runs/$RUN_ID/summary-*.json" "$OUT/" --project="$PROJECT" 2>/dev/null || echo "  (no summaries found in GCS)"
  SQLID="$(echo "$SQLCONN" | awk -F: '{print $1":"$3}')"
  python3 "$HERE/lib/collect.py" \
    --results-dir "$OUT" --project "$PROJECT" --name-prefix "$NAMEPREFIX" \
    --sql-instance-id "$SQLID" --run-id "$RUN_ID" \
    --start "$(cat "$OUT/.start")" --end "$(cat "$OUT/.end")"
  echo "----------------------------------------"
  cat "$OUT/report.md"
}

cmd_teardown() {
  resolve
  RUN_ID="$(cat "$CURRENT")"
  OUT="$RESULTS/$RUN_ID"
  python3 "$HERE/lib/harness.py" teardown \
    --base-url "$BASE_URL" --master-key "$(masterkey)" --out "$OUT" --run-id "$RUN_ID"
  gcloud storage rm "gs://$BUCKET/runs/current/config.json" --project="$PROJECT" 2>/dev/null || true
}

case "${1:-}" in
  build) cmd_build ;;
  setup) cmd_setup ;;
  run) cmd_run ;;
  collect) cmd_collect ;;
  teardown) cmd_teardown ;;
  all) cmd_setup; cmd_run; cmd_collect; cmd_teardown ;;
  *) echo "usage: $0 {build|setup|run|collect|teardown|all}" >&2; exit 1 ;;
esac
