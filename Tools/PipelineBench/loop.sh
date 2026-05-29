#!/bin/bash
# loop.sh -- Karpathy-style autoresearch loop runner.
#
# For each variant:
#   1. Run the bench
#   2. Append a JSONL trial entry to .autoresearch/air-pipeline-scheduling.jsonl
#   3. Compare to incumbent and report keep/revert
#
# Acceptance rule: keep variant if it improves final time by >=10% OR
# first-result by >=20% with no correctness regressions.
#
# Usage: ./Tools/PipelineBench/loop.sh

set -euo pipefail
cd "$(dirname "$0")/../.."

LOG=".autoresearch/air-pipeline-scheduling.jsonl"
mkdir -p .autoresearch

VARIANTS=(
  "baseline"
  "defer_persist"
  "defer_persist_fnf"
  "prewarm_improve"
  "partial_prewarm_defer"
  "speculative"
)

# Hypotheses for the JSONL log.
declare -A HYPOTHESES
HYPOTHESES["baseline"]="reproduce AppState.processRecording today: serial finalize -> transcribe -> persist -> improve -> finalize"
HYPOTHESES["defer_persist"]="run improve and main-thread persistence in parallel; both must complete before finalize"
HYPOTHESES["defer_persist_fnf"]="persistence is non-critical to user delivery; fire-and-forget after improve so finalize is unblocked"
HYPOTHESES["prewarm_improve"]="open improve URLSession during transcribe so connection is warm by the time raw is ready (~200ms saved)"
HYPOTHESES["partial_prewarm_defer"]="partial first-result mid-transcribe + prewarm improve + deferred persist (combined wins)"
HYPOTHESES["speculative"]="speculative improve on partial transcript, validated against final transcript when it arrives"

declare -A FILES
FILES["baseline"]="Tools/PipelineBench/PipelineOrchestrator.swift"
FILES["defer_persist"]="Tools/PipelineBench/PipelineOrchestrator.swift"
FILES["defer_persist_fnf"]="Tools/PipelineBench/PipelineOrchestrator.swift"
FILES["prewarm_improve"]="Tools/PipelineBench/PipelineOrchestrator.swift"
FILES["partial_prewarm_defer"]="Tools/PipelineBench/PipelineOrchestrator.swift"
FILES["speculative"]="Tools/PipelineBench/PipelineOrchestrator.swift"

incumbent_first=""
incumbent_final=""

for variant in "${VARIANTS[@]}"; do
  echo "=== Trial: $variant ==="
  out_json="$(AIR_BENCH_VARIANT=$variant ./Tools/PipelineBench/run.sh)"
  # Extract realistic+streaming numbers via python json.
  read -r realistic_first realistic_final streaming_first streaming_final raw_ok improved_ok <<<"$(python3 - <<PY
import json, sys
d = json.loads('''$out_json''')
realistic = next(x for x in d if x['profile'] == 'realistic')
streaming = next(x for x in d if x['profile'] == 'streaming')
raw_ok = realistic['rawDelivered'] or realistic['improvedDelivered']
improved_ok = realistic['improvedDelivered'] and streaming['improvedDelivered']
ordering_ok = realistic['orderingValid'] and streaming['orderingValid']
print(f"{realistic['firstResultMs']} {realistic['finalMs']} {streaming['firstResultMs']} {streaming['finalMs']} {1 if (raw_ok and ordering_ok) else 0} {1 if improved_ok else 0}")
PY
)"

  # Set incumbent on baseline.
  if [ "$variant" = "baseline" ]; then
    incumbent_first="$realistic_first"
    incumbent_final="$realistic_final"
    decision="incumbent"
    rationale="initial baseline"
  else
    final_delta=$(python3 -c "print(($incumbent_final - $realistic_final) / $incumbent_final)")
    first_delta=$(python3 -c "print(($incumbent_first - $realistic_first) / $incumbent_first)")
    if [ "$improved_ok" = "0" ]; then
      decision="revert"
      rationale="correctness regression: improved text not delivered"
    elif python3 -c "import sys; sys.exit(0 if $final_delta >= 0.10 else 1)" 2>/dev/null; then
      decision="keep"
      rationale="final time reduced by $(python3 -c "print(round($final_delta*100,1))")%"
      incumbent_first="$realistic_first"
      incumbent_final="$realistic_final"
    elif python3 -c "import sys; sys.exit(0 if $first_delta >= 0.20 else 1)" 2>/dev/null; then
      decision="keep"
      rationale="first-result time reduced by $(python3 -c "print(round($first_delta*100,1))")%"
      incumbent_first="$realistic_first"
      incumbent_final="$realistic_final"
    else
      decision="revert"
      rationale="below acceptance threshold (final delta=$final_delta, first delta=$first_delta)"
    fi
  fi

  # Append JSONL entry.
  python3 - <<PY >>"$LOG"
import json, datetime
entry = {
    "ts": datetime.datetime.utcnow().isoformat() + "Z",
    "variant": "$variant",
    "hypothesis": "${HYPOTHESES[$variant]}",
    "files": ["${FILES[$variant]}"],
    "command": "AIR_BENCH_VARIANT=$variant ./Tools/PipelineBench/run.sh",
    "metrics": {
        "realistic_firstResult_ms": $realistic_first,
        "realistic_final_ms": $realistic_final,
        "streaming_firstResult_ms": $streaming_first,
        "streaming_final_ms": $streaming_final,
    },
    "guardrails": {
        "raw_or_improved_delivered": bool($raw_ok),
        "improved_delivered_both_profiles": bool($improved_ok),
    },
    "decision": "$decision",
    "rationale": "$rationale",
    "incumbent_after": {
        "realistic_firstResult_ms": $incumbent_first,
        "realistic_final_ms": $incumbent_final,
    },
}
print(json.dumps(entry))
PY

  printf "  realistic: tFirst=%sms tFinal=%sms (decision=%s) -- %s\n" \
    "$realistic_first" "$realistic_final" "$decision" "$rationale"
  printf "  streaming: tFirst=%sms tFinal=%sms\n\n" \
    "$streaming_first" "$streaming_final"
done

echo "=== Loop complete. Log: $LOG ==="
