#!/usr/bin/env bash
# Interleaved sweep: run each variant once, repeated PASSES times.
# Output: aggregated JSONL written to .autoresearch/transcription-latency.jsonl
# plus a final summary table on stderr.

set -euo pipefail
cd "$(dirname "$0")"

VARIANTS=("$@")
if [[ ${#VARIANTS[@]} -eq 0 ]]; then
  VARIANTS=(baseline plain-text dedicated-session stream-upload downsample-16k)
fi
PASSES="${PASSES:-3}"
RUNS="${RUNS:-20}"
SERVER_DELAY_MS="${SERVER_DELAY_MS:-30}"
LOG="../.autoresearch/transcription-latency.jsonl"

swift build -c release --product TranscriptionBench >&2
BIN=".build/release/TranscriptionBench"

for ((pass=1; pass<=PASSES; pass++)); do
  echo "PASS $pass/$PASSES" >&2
  for v in "${VARIANTS[@]}"; do
    OUT=$(BENCH_VARIANT="$v" "$BIN" --runs "$RUNS" --server-delay-ms "$SERVER_DELAY_MS")
    TS=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    python3 - "$v" "$pass" "$TS" "$OUT" <<'PY' >> "$LOG"
import json, sys
v, p, ts, out = sys.argv[1], int(sys.argv[2]), sys.argv[3], sys.argv[4]
summary = json.loads(out)
print(json.dumps({"ts": ts, "variant": v, "pass": p, "summary": summary}))
PY
    echo "  $v: $(echo $OUT | python3 -c 'import json,sys;d=json.loads(sys.stdin.read())["overall"];print(f"p50={d[\"p50ms\"]:.1f} p95={d[\"p95ms\"]:.1f}")')" >&2
  done
done

# Aggregate the latest PASSES rows per variant: median of overall p50 + median of overall p95.
python3 - "$LOG" "$PASSES" "${VARIANTS[@]}" <<'PY' >&2
import json, sys
log_path, passes = sys.argv[1], int(sys.argv[2])
variants = sys.argv[3:]
rows = []
with open(log_path) as f:
    for line in f:
        rows.append(json.loads(line))
print()
print(f"{'variant':22} {'p50_med':>9} {'p95_med':>9} {'p50_min':>9} {'p95_min':>9}")
print("-" * 64)
for v in variants:
    sel = [r for r in rows if r.get("variant") == v and "pass" in r][-passes:]
    p50s = sorted(r["summary"]["overall"]["p50ms"] for r in sel)
    p95s = sorted(r["summary"]["overall"]["p95ms"] for r in sel)
    if not p50s:
        continue
    p50_med = p50s[len(p50s)//2]
    p95_med = p95s[len(p95s)//2]
    print(f"{v:22} {p50_med:9.2f} {p95_med:9.2f} {p50s[0]:9.2f} {p95s[0]:9.2f}")
PY
