#!/bin/bash
# run.sh -- Compile + execute the pipeline scheduling bench for one variant.
#
# Usage: AIR_BENCH_VARIANT=baseline ./Tools/PipelineBench/run.sh
#
# Exits 0 with JSON-array result on stdout, non-zero on compile/run failure.
set -euo pipefail
cd "$(dirname "$0")/../.."

VARIANT="${AIR_BENCH_VARIANT:-baseline}"
BIN="$(mktemp -t air-bench-${VARIANT}-XXXXXX)"
trap 'rm -f "$BIN"' EXIT

# Compile main.swift + sim + orchestrator. main.swift defines the entry point
# and must be listed last so its top-level statements run.
swiftc -O \
  -o "$BIN" \
  Tools/PipelineBench/PipelineSim.swift \
  Tools/PipelineBench/PipelineOrchestrator.swift \
  Tools/PipelineBench/main.swift

AIR_BENCH_VARIANT="$VARIANT" "$BIN"
