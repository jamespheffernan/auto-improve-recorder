#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

ROOT="../.."
APP_SET="$ROOT/AutoSendRecorder/Assets.xcassets/AppIcon.appiconset"
MENU_SET="$ROOT/AutoSendRecorder/Assets.xcassets/MenuBarIcon.imageset"
APP_SVG="autosend-icon-macos.svg"
MENU_SVG="autosend-menubar-template.svg"

r() { node render.js "$1" "$2" "$3"; }

r "$APP_SVG" "$APP_SET/AppIcon-16x16.png" 16
r "$APP_SVG" "$APP_SET/AppIcon-16x16@2x.png" 32
r "$APP_SVG" "$APP_SET/AppIcon-32x32.png" 32
r "$APP_SVG" "$APP_SET/AppIcon-32x32@2x.png" 64
r "$APP_SVG" "$APP_SET/AppIcon-128x128.png" 128
r "$APP_SVG" "$APP_SET/AppIcon-128x128@2x.png" 256
r "$APP_SVG" "$APP_SET/AppIcon-256x256.png" 256
r "$APP_SVG" "$APP_SET/AppIcon-256x256@2x.png" 512
r "$APP_SVG" "$APP_SET/AppIcon-512x512.png" 512
r "$APP_SVG" "$APP_SET/AppIcon-512x512@2x.png" 1024
r "$MENU_SVG" "$MENU_SET/menubar-18.png" 18
r "$MENU_SVG" "$MENU_SET/menubar-36.png" 36

echo "Auto Send Recorder icons rendered."
