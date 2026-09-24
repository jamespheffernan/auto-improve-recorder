#!/bin/bash
# Add the verified runtime to an existing archive, sign it, then submit for notarization.
set -euo pipefail
if [[ $# != 3 ]]; then
  echo "Usage: $0 ARCHIVE RUNTIME_DIRECTORY OUTPUT_DIRECTORY" >&2
  exit 2
fi
archive="$1"
runtime="$2"
output="$3"
app="$archive/Products/Applications/Auto Send Recorder.app"
identity='Developer ID Application: Turf Terrace Ltd (7W38KL8969)'
[[ -d "$app" && -f "$runtime/models.json" && -f "$runtime/licenses/parakeet-MIT.txt" ]] || exit 2
mkdir -p "$output"
/usr/bin/ditto "$runtime" "$app/Contents/Resources/SpeechRuntime"
/usr/bin/codesign --force --options runtime --timestamp --sign "$identity" "$app/Contents/Resources/SpeechRuntime/capi/libparakeet.dylib"
/usr/bin/codesign --force --options runtime --timestamp --sign "$identity" "$app/Contents/Resources/SpeechRuntime/bin/parakeet-cli"
cat > "$output/entitlements.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>com.apple.security.cs.disable-library-validation</key><true/><key>com.apple.security.device.audio-input</key><true/></dict></plist>
PLIST
/usr/bin/codesign --force --options runtime --timestamp --entitlements "$output/entitlements.plist" --sign "$identity" "$app"
/usr/bin/codesign --verify --deep --strict "$app"
cat > "$output/export-options.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>method</key><string>developer-id</string><key>destination</key><string>upload</string><key>signingStyle</key><string>automatic</string><key>teamID</key><string>7W38KL8969</string></dict></plist>
PLIST
/usr/bin/xcodebuild -exportArchive -archivePath "$archive" -exportOptionsPlist "$output/export-options.plist" -exportPath "$output/export" -allowProvisioningUpdates
/bin/bash "$(dirname "$0")/finish-notarization.sh" "$archive" "$output"
