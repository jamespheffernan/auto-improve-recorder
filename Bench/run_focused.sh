#!/usr/bin/env bash
# Focused sweep: long-120s fixture only, tight interleaving.
# Each pass runs all variants once with N runs each before repeating.
# Signal-to-noise is best at large N and many passes.

set -euo pipefail
cd "$(dirname "$0")"

VARIANTS=("$@")
if [[ ${#VARIANTS[@]} -eq 0 ]]; then
  VARIANTS=(baseline plain-text dedicated-session plain-text-dedicated)
fi
PASSES="${PASSES:-6}"
RUNS="${RUNS:-25}"
SERVER_DELAY_MS="${SERVER_DELAY_MS:-30}"
FIXTURE="${FIXTURE:-long-120s}"
LOG="../.autoresearch/transcription-latency.jsonl"

swift build -c release --product TranscriptionBench >&2
BIN=".build/release/TranscriptionBench"

for ((pass=1; pass<=PASSES; pass++)); do
  echo "PASS $pass/$PASSES" >&2
  for v in "${VARIANTS[@]}"; do
    OUT=$(BENCH_VARIANT="$v" "$BIN" --runs "$RUNS" --server-delay-ms "$SERVER_DELAY_MS" --only "$FIXTURE")
    TS=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    python3 - "$v" "$pass" "$TS" "$OUT" "$FIXTURE" <<'PY' >> "$LOG"
import json, sys
v, p, ts, out, fx = sys.argv[1], int(sys.argv[2]), sys.argv[3], sys.argv[4], sys.argv[5]
summary = json.loads(out)
print(json.dumps({"ts": ts, "variant": v, "pass": p, "fixture_only": fx, "summary": summary}))
PY
    echo "  $v: $(printf '%s' "$OUT" | python3 -c 'import json, sys; d=json.loads(sys.stdin.read())["overall"]; print("p50=%.1f p95=%.1f" % (d["p50ms"], d["p95ms"]))')" >&2
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
        try: rows.append(json.loads(line))
        except: pass
print()
print("FOCUSED RESULTS (long-120s)")
print(f"{'variant':30} {'p50_med':>9} {'p95_med':>9} {'p50_min':>9} {'p95_min':>9} {'n':>3}")
print("-" * 76)
for v in variants:
    sel = [r for r in rows if r.get("variant") == v and r.get("fixture_only")][-passes:]
    p50s = sorted(r["summary"]["overall"]["p50ms"] for r in sel)
    p95s = sorted(r["summary"]["overall"]["p95ms"] for r in sel)
    if not p50s:
        continue
    p50_med = p50s[len(p50s)//2]
    p95_med = p95s[len(p95s)//2]
    print(f"{v:30} {p50_med:9.2f} {p95_med:9.2f} {p50s[0]:9.2f} {p95s[0]:9.2f} {len(p50s):3d}")
PY
