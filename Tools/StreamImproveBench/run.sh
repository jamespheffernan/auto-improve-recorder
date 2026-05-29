#!/bin/bash
# Tools/StreamImproveBench/run.sh
#
# Compile + execute the OpenAI improve streaming bench.
#
# Usage:
#   ./Tools/StreamImproveBench/run.sh [--trials=N] [--log=PATH] [--baseline-only]
#
# Output: pretty JSON summary on stdout; full per-trial JSONL appended to
# .autoresearch/air-streaming-improve.jsonl (or --log path).
set -euo pipefail
cd "$(dirname "$0")/../.."

BIN="$(mktemp -t air-stream-bench-XXXXXX)"
trap 'rm -f "$BIN"' EXIT

# We compile:
#   - bench harness + stubs (Tools/StreamImproveBench/*.swift)
#   - the four engine support files (Engines/{ImproveEngine,OpenAIImproveEngine,SharedNetworkClient}.swift)
#   - the MockServer (Bench/Sources/IOSNetworkBench/MockServer.swift)
#
# We exclude AppKit-heavy code (AppState, AlternativeImproveEngines, etc).
swiftc -O -parse-as-library \
  -o "$BIN" \
  Tools/StreamImproveBench/StreamImproveBench.swift \
  Tools/StreamImproveBench/BenchModelsStub.swift \
  AutoImproveRecorder/Engines/ImproveEngine.swift \
  AutoImproveRecorder/Engines/OpenAIImproveEngine.swift \
  AutoImproveRecorder/Engines/SharedNetworkClient.swift \
  Bench/Sources/IOSNetworkBench/MockServer.swift

"$BIN" "$@"
