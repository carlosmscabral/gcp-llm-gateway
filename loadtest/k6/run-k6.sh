#!/bin/sh
# Cloud Run Job entrypoint for the k6 image.
#
# Splits total load across tasks via k6 execution segments derived from the
# Cloud Run task index/count, reads the per-run config from the mounted results
# bucket, and points k6's summary at a per-task file in that bucket.
set -eu

IDX="${CLOUD_RUN_TASK_INDEX:-0}"
CNT="${CLOUD_RUN_TASK_COUNT:-1}"
WORK="${WORK_DIR:-/work}"
CONF="$WORK/runs/current/config.json"

if [ ! -f "$CONF" ]; then
  echo "config not found at $CONF (did run.sh upload it?)" >&2
  exit 1
fi

# run_id from config (fallback: current)
RUN_ID="$(sed -n 's/.*"run_id"[ ]*:[ ]*"\([^"]*\)".*/\1/p' "$CONF" | head -1)"
[ -n "$RUN_ID" ] || RUN_ID="current"
OUT_DIR="$WORK/runs/$RUN_ID"
mkdir -p "$OUT_DIR"

# execution segment: task IDX owns [IDX/CNT, (IDX+1)/CNT)
# sequence must partition [0,1]: 0,1/CNT,2/CNT,...,CNT/CNT
SEQ="0"; i=1
while [ "$i" -le "$CNT" ]; do SEQ="$SEQ,$i/$CNT"; i=$((i + 1)); done
SEG="$IDX/$CNT:$((IDX + 1))/$CNT"

CONFIG_JSON="$(cat "$CONF")"
export CONFIG_JSON
export K6_SUMMARY_PATH="$OUT_DIR/summary-$IDX.json"

echo "task $IDX/$CNT  run_id=$RUN_ID  segment=$SEG"
exec k6 run --no-color \
  --execution-segment "$SEG" \
  --execution-segment-sequence "$SEQ" \
  --tag testid="$RUN_ID" \
  /loadtest.js
