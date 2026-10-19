#!/bin/bash
# End-to-end tests: real directory, feed, streaming, on-device captions, the
# notch UI rendered offscreen (screenshots in e2e-shots/), and the installer.
#   bash scripts/e2e.sh    E2E_VIDEO=1 (video)    E2E_DEMO=1 (record e2e-shots/demo.gif)
set -euo pipefail
cd "$(dirname "$0")/.."
bash scripts/swift.sh build -j 2 >/dev/null
FLAGS=()
[[ -f .build/sdk-overlay.json ]] && FLAGS=(-vfsoverlay "$PWD/.build/sdk-overlay.json")
SOURCES=$(ls Sources/QuietCast/*.swift | grep -v QuietCastApp.swift)
# An embedded Info.plist lets the harness ask for Speech Recognition like the app.
xcrun swiftc -swift-version 5 -parse-as-library "${FLAGS[@]}" $SOURCES scripts/e2e/*.swift \
    -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker scripts/e2e/Info.plist \
    -o .build/e2e
codesign -s - -f .build/e2e 2>/dev/null

CACHE="$(mktemp -d)"; INSTALL="$(mktemp -d)"
trap 'rm -rf "$CACHE" "$INSTALL"' EXIT
QUIETCAST_CACHE_DIR="$CACHE" E2E_SHOTS="$PWD/e2e-shots" .build/e2e

# The published installer, end to end, into a throwaway folder.
NOTCHPOD_INSTALL_DIR="$INSTALL" NOTCHPOD_NO_OPEN=1 bash scripts/install.sh >/dev/null
codesign --verify --deep --strict "$INSTALL/NotchPod.app"
if xattr "$INSTALL/NotchPod.app" | grep -q com.apple.quarantine; then echo "FAIL: installer left quarantine" >&2; exit 1; fi
echo "PASS install.sh: latest release installs, signed, no quarantine"
