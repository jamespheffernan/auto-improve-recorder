#!/bin/bash
set -euo pipefail
archive="$1"
output="$2"
for attempt in {1..20}; do
  if /usr/bin/xcodebuild -exportNotarizedApp -archivePath "$archive" -exportPath "$output/notarized" > "$output/notary-status.log" 2>&1; then
    /usr/bin/xcrun stapler validate "$output/notarized/Auto Send Recorder.app"
    /usr/bin/codesign --verify --deep --strict "$output/notarized/Auto Send Recorder.app"
    /usr/sbin/spctl --assess --type execute --verbose=2 "$output/notarized/Auto Send Recorder.app"
    /usr/bin/ditto -c -k --sequesterRsrc --keepParent "$output/notarized/Auto Send Recorder.app" "$output/Auto-Send-Recorder-1.1-2.zip"
    /usr/bin/shasum -a 256 "$output/Auto-Send-Recorder-1.1-2.zip" > "$output/SHA256SUMS.txt"
    echo 'NOTARIZED RELEASE READY'
    exit 0
  fi
  cat "$output/notary-status.log"
  /usr/bin/grep -q 'processing and not ready' "$output/notary-status.log" || exit 1
  /bin/sleep 15
done
exit 1
