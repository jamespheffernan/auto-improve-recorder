#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

ROOT="../.."
MAC_SET="$ROOT/AutoImproveRecorder/Assets.xcassets/AppIcon.appiconset"
IOS_SET="$ROOT/AutoImproveRecorderIOS/Assets.xcassets/AppIcon.appiconset"
MAC_SVG="icon-macos.svg"
IOS_SVG="icon-ios.svg"

r() { node render.js "$1" "$2" "$3"; }

echo "== macOS app icon set =="
r "$MAC_SVG" "$MAC_SET/AppIcon-16x16.png" 16
r "$MAC_SVG" "$MAC_SET/AppIcon-16x16@2x.png" 32
r "$MAC_SVG" "$MAC_SET/AppIcon-32x32.png" 32
r "$MAC_SVG" "$MAC_SET/AppIcon-32x32@2x.png" 64
r "$MAC_SVG" "$MAC_SET/AppIcon-128x128.png" 128
r "$MAC_SVG" "$MAC_SET/AppIcon-128x128@2x.png" 256
r "$MAC_SVG" "$MAC_SET/AppIcon-256x256.png" 256
r "$MAC_SVG" "$MAC_SET/AppIcon-256x256@2x.png" 512
r "$MAC_SVG" "$MAC_SET/AppIcon-512x512.png" 512
r "$MAC_SVG" "$MAC_SET/AppIcon-512x512@2x.png" 1024

echo "== .icns =="
ICONSET="AppIcon.iconset"
rm -rf "$ICONSET"; mkdir -p "$ICONSET"
r "$MAC_SVG" "$ICONSET/icon_16x16.png" 16
r "$MAC_SVG" "$ICONSET/icon_16x16@2x.png" 32
r "$MAC_SVG" "$ICONSET/icon_32x32.png" 32
r "$MAC_SVG" "$ICONSET/icon_32x32@2x.png" 64
r "$MAC_SVG" "$ICONSET/icon_128x128.png" 128
r "$MAC_SVG" "$ICONSET/icon_128x128@2x.png" 256
r "$MAC_SVG" "$ICONSET/icon_256x256.png" 256
r "$MAC_SVG" "$ICONSET/icon_256x256@2x.png" 512
r "$MAC_SVG" "$ICONSET/icon_512x512.png" 512
r "$MAC_SVG" "$ICONSET/icon_512x512@2x.png" 1024
iconutil -c icns "$ICONSET" -o "$ROOT/AutoImproveRecorder/AppIcon.icns"
rm -rf "$ICONSET"

echo "== iOS app icon set =="
for s in 20 29 40 58 60 76 80 87 120 152 167 180 1024; do
  r "$IOS_SVG" "$IOS_SET/AppIcon-$s.png" "$s"
done

echo "DONE"
