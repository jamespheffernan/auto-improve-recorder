#!/bin/zsh
set -euo pipefail

SCRIPT_DIR=${0:A:h}
cd "$SCRIPT_DIR"

swift build -c release --product AudioCaptureProfile
BINARY="$SCRIPT_DIR/.build/release/AudioCaptureProfile"
OUTPUT_DIR=${1:-"$SCRIPT_DIR/../.autoresearch/air-4-audio-profile"}
mkdir -p "$OUTPUT_DIR"

for implementation in baseline candidate; do
  mkdir -p "$OUTPUT_DIR/$implementation"
  for profile_path in archive openai parakeet; do
    for duration in 5 30 120; do
      "$BINARY" \
        --implementation "$implementation" \
        --path "$profile_path" \
        --duration "$duration" \
        --output "$OUTPUT_DIR/$implementation/${profile_path}-${duration}s.json" \
        > "$OUTPUT_DIR/$implementation/${profile_path}-${duration}s.stdout.json"
    done
  done
done

echo "AIR-4 metrics: $OUTPUT_DIR"
