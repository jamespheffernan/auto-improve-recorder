#!/bin/zsh
set -euo pipefail

script_dir=${0:A:h}
repo_dir=${script_dir:h:h}
build_dir=${TMPDIR:-/tmp}/auto-send-delivery-fixture-build
evidence_dir=${1:-${repo_dir}/.autoresearch/asr-fast-delivery/live-gate}
iterations=${DELIVERY_FIXTURE_ITERATIONS:-20}
controller_mode=()
if [[ ${DELIVERY_FIXTURE_TEXTEDIT_PROBE:-0} == 1 ]]; then
  controller_mode=(--textedit-probe)
fi

mkdir -p "$build_dir" "$evidence_dir"
fixture_app="$build_dir/DeliveryFixture.app"
mkdir -p "$fixture_app/Contents/MacOS"
cp "$script_dir/FixtureInfo.plist" "$fixture_app/Contents/Info.plist"

xcrun swiftc -O -warnings-as-errors \
  -framework AppKit \
  "$script_dir/FixtureApp.swift" \
  -o "$fixture_app/Contents/MacOS/DeliveryFixtureApp"

xcrun swiftc -O -warnings-as-errors \
  -framework AppKit \
  -framework ApplicationServices \
  "$script_dir/DeliveryController.swift" \
  -o "$build_dir/DeliveryController"

set +e
"$build_dir/DeliveryController" \
  --fixture "$fixture_app" \
  --evidence "$evidence_dir" \
  --iterations "$iterations" \
  "${controller_mode[@]}"
run_status=$?
set -e

pushd "$evidence_dir" >/dev/null
shasum -a 256 unit-goldens.json > golden_checksums.txt
shasum -a 256 -c golden_checksums.txt
popd >/dev/null

if [[ $run_status -eq 77 ]]; then
  print -u2 "Live gate blocked. See $evidence_dir/verdict.md and $evidence_dir/ax-diagnostics.txt. If diagnostics say AXIsProcessTrusted=false, add $build_dir/DeliveryController to System Settings > Privacy & Security > Accessibility, then rerun the same command."
fi

exit $run_status
