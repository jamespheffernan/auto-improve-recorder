#!/usr/bin/env bash
# Loop runner for air-opus-upload: AAC-in-M4A on-device-encoded transcription
# under bandwidth-shaped FakeServer. Outputs paired A/B trials at LTE and Wi-Fi.
#
# The "Opus" label in the loop name is aspirational — we ship AAC-LC in .m4a
# instead because Apple's first-party AAC encoder writes a container OpenAI
# accepts (audio/mp4 → .m4a) without bundling a third-party Ogg/Opus muxer.
# AAC@24-32 kbps mono is widely benchmarked as comparable to Opus@24-32k for
# speech intelligibility on Whisper. See trial notes for the trade-off.
#
# Usage: ./run_opus_loop.sh [--passes N] [--runs N]
set -euo pipefail
cd "$(dirname "$0")"

PASSES="${PASSES:-3}"
RUNS="${RUNS:-15}"
SERVER_DELAY_MS="${SERVER_DELAY_MS:-50}"
LOG="../.autoresearch/air-opus-upload.jsonl"
mkdir -p "$(dirname "$LOG")"

# Build once.
swift build -c release --product TranscriptionBench >&2
BIN=".build/release/TranscriptionBench"

# (variant, label) pairs. Same order across both bandwidth profiles.
VARIANTS=(
  "baseline:WAV 48k mono (control)"
  "downsample-16k:WAV 16k mono (loop #1 retest)"
  "aac-32k:AAC@32kbps m4a (quality safety net)"
  "aac-24k:AAC@24kbps m4a (target)"
  "aac-16k:AAC@16kbps m4a"
  "aac-12k:AAC@12kbps m4a (aggressive)"
)

# Two bandwidth profiles.
PROFILES=("lte:5000" "wifi:50000")

for prof in "${PROFILES[@]}"; do
  pname="${prof%:*}"
  pkbps="${prof#*:}"
  for ((pass=1; pass<=PASSES; pass++)); do
    for entry in "${VARIANTS[@]}"; do
      v="${entry%%:*}"
      label="${entry#*:}"
      echo "[$pname pass $pass/$PASSES] $v" >&2
      start_ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
      OUT=$(BENCH_VARIANT="$v" BENCH_UPLINK_KBPS="$pkbps" "$BIN" \
            --runs "$RUNS" --server-delay-ms "$SERVER_DELAY_MS")
      end_ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
      python3 - "$v" "$label" "$pname" "$pkbps" "$pass" "$start_ts" "$end_ts" "$OUT" <<'PY' >> "$LOG"
import json, sys
v, label, pname, pkbps, pas, st, et, out = sys.argv[1:]
s = json.loads(out)
ovr = s["overall"]
fx = {f["fixture"]: f for f in s["perFixture"]}
def get(name, k):
    f = fx.get(name); return f[k] if f else None
print(json.dumps({
  "ts": et, "variant": v, "label": label,
  "profile": pname, "uplinkKbps": int(pkbps), "pass": int(pas),
  "started_at": st, "ended_at": et,
  "overall_p50ms": ovr["p50ms"], "overall_p95ms": ovr["p95ms"], "overall_mean_ms": ovr["meanMs"], "n": ovr["n"],
  "short_p95ms": (get("short-5s","stats") or {}).get("p95ms"),
  "med_p95ms": (get("medium-30s","stats") or {}).get("p95ms"),
  "long_p95ms": (get("long-120s","stats") or {}).get("p95ms"),
  "short_bytes": get("short-5s","bytesP50"),
  "med_bytes": get("medium-30s","bytesP50"),
  "long_bytes": get("long-120s","bytesP50"),
  "failures": s["failures"]
}))
PY
      grep_last=$(printf '%s\n' "$OUT" | python3 -c 'import json,sys; d=json.loads(sys.stdin.read()); print("p50=%.0f p95=%.0f long_bytes=%s" % (d["overall"]["p50ms"], d["overall"]["p95ms"], next((f["bytesP50"] for f in d["perFixture"] if f["fixture"]=="long-120s"), "?")))')
      echo "    -> $grep_last" >&2
    done
  done
done

echo "" >&2
echo "RESULT TABLE (median across passes per profile)" >&2
python3 - "$LOG" "$PASSES" <<'PY' >&2
import json, sys, statistics
log = sys.argv[1]; passes = int(sys.argv[2])
rows = []
with open(log) as f:
    for line in f:
        try: rows.append(json.loads(line))
        except: pass
profs = sorted({r["profile"] for r in rows})
variants_order = ["baseline","downsample-16k","aac-32k","aac-24k","aac-16k","aac-12k"]
for prof in profs:
    print(f"\n--- {prof.upper()} ---")
    print(f"{'variant':18} {'long_p95(ms)':>13} {'long_bytes':>12} {'reduction':>10}")
    print('-'*58)
    base = None
    for v in variants_order:
        sel = [r for r in rows if r["profile"]==prof and r["variant"]==v][-passes:]
        if not sel: continue
        long_p95 = statistics.median(r["long_p95ms"] for r in sel if r["long_p95ms"] is not None)
        long_bytes = statistics.median(r["long_bytes"] for r in sel if r["long_bytes"] is not None)
        if v=="baseline": base = long_bytes
        red = f"{(1 - long_bytes/base)*100:6.1f}%" if base else "—"
        print(f"{v:18} {long_p95:13.1f} {long_bytes:12.0f} {red:>10}")
PY
