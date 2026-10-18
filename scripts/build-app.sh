#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
bash scripts/swift.sh build -c release -j 2
BIN="$(bash scripts/swift.sh build -c release --show-bin-path)"
APP="$PWD/dist/NotchPod.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/QuietCast" "$APP/Contents/MacOS/QuietCast"
cp Resources/Info.plist "$APP/Contents/Info.plist"
if [[ -f Resources/AppIcon.icns ]]; then
  cp Resources/AppIcon.icns "$APP/Contents/Resources/"
fi
codesign --force --sign - "$APP"
printf '\nBuilt: %s\nLaunch: open "%s"\n' "$APP" "$APP"
