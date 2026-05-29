#!/usr/bin/env bash
# Helper: run benchmark for given variant, append a JSONL row to log.
# Usage: ./log_trial.sh <variant> <hypothesis> [<notes>]

set -euo pipefail
cd "$(dirname "$0")"

VARIANT="$1"
HYPOTHESIS="${2:-}"
NOTES="${3:-}"
LOG=".autoresearch/transcription-latency.jsonl"
mkdir -p "../$(dirname $LOG)" || true
LOG_PATH="../.autoresearch/transcription-latency.jsonl"

OUT=$(BENCH_VARIANT="$VARIANT" RUNS="${RUNS:-20}" SERVER_DELAY_MS="${SERVER_DELAY_MS:-30}" ./run_bench.sh)
TS=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

# Build a single-line JSONL entry by inlining the bench output as bench_summary.
python3 - "$VARIANT" "$HYPOTHESIS" "$NOTES" "$TS" "$OUT" <<'PY' >> "$LOG_PATH"
import json, sys
variant, hyp, notes, ts, out = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5]
summary = json.loads(out)
row = {
    "ts": ts,
    "variant": variant,
    "hypothesis": hyp,
    "notes": notes,
    "summary": summary,
}
print(json.dumps(row))
PY

# Also echo headline metrics so the loop driver can decide.
echo "$OUT"
