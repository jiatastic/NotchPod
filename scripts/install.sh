#!/bin/bash
# Installs the latest NotchPod release:
#   curl -fsSL https://raw.githubusercontent.com/jiatastic/NotchPod/main/scripts/install.sh | bash
set -euo pipefail

URL="https://github.com/jiatastic/NotchPod/releases/latest/download/NotchPod.zip"
DEST="${NOTCHPOD_INSTALL_DIR:-/Applications}"
[[ -w "$DEST" || -n "${NOTCHPOD_INSTALL_DIR:-}" ]] || DEST="$HOME/Applications"
mkdir -p "$DEST"

if [[ "$(uname -m)" != "arm64" ]]; then
    echo "NotchPod needs an Apple Silicon Mac." >&2; exit 1
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
echo "Downloading NotchPod…"
curl -fsSL "$URL" -o "$TMP/NotchPod.zip"
ditto -x -k "$TMP/NotchPod.zip" "$TMP"

# Replace a running or older copy.
[[ -n "${NOTCHPOD_NO_OPEN:-}" ]] || pkill -x QuietCast 2>/dev/null || true
rm -rf "$DEST/NotchPod.app"
ditto "$TMP/NotchPod.app" "$DEST/NotchPod.app"
# The app isn't notarized; downloaded copies must not carry the quarantine flag.
xattr -dr com.apple.quarantine "$DEST/NotchPod.app" 2>/dev/null || true

echo "Installed to $DEST/NotchPod.app"
[[ -n "${NOTCHPOD_NO_OPEN:-}" ]] || open "$DEST/NotchPod.app"
