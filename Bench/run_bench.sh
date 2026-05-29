#!/usr/bin/env bash
# Single repeatable benchmark command. Used unchanged for every trial.
# Usage: BENCH_VARIANT=<name> ./run_bench.sh
# Outputs one JSON line on stdout (the run summary) and progress on stderr.

set -euo pipefail
cd "$(dirname "$0")"

VARIANT="${BENCH_VARIANT:-baseline}"
RUNS="${RUNS:-20}"
SERVER_DELAY_MS="${SERVER_DELAY_MS:-30}"

# Build release binary once. Subsequent runs are fast.
swift build -c release --product TranscriptionBench >&2
BIN=".build/release/TranscriptionBench"

BENCH_VARIANT="$VARIANT" "$BIN" --runs "$RUNS" --server-delay-ms "$SERVER_DELAY_MS"
