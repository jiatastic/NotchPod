#!/bin/bash
# Project-local workarounds for mixed Command Line Tools installations.
# No system SDK/toolchain files are modified.
set -euo pipefail
cd "$(dirname "$0")/.."
TOOLCHAIN="$(xcode-select -p)/usr"
mkdir -p .build
MANIFEST="$TOOLCHAIN/lib/swift/pm/ManifestAPI"
PUBLIC="$MANIFEST/PackageDescription.swiftmodule/arm64-apple-macos.swiftinterface"
PRIVATE="$MANIFEST/PackageDescription.swiftmodule/arm64-apple-macos.private.swiftinterface"
if [[ -f "$PRIVATE" ]] && grep -q 'enum SwiftLanguageMode' "$PUBLIC" && ! grep -q 'enum SwiftLanguageMode' "$PRIVATE"; then
    DEST="$PWD/.build/swiftpm-libs/ManifestAPI"
    mkdir -p "$DEST/PackageDescription.swiftmodule"
    for ARCH in arm64 x86_64; do
        cp "$MANIFEST/PackageDescription.swiftmodule/$ARCH-apple-macos.swiftinterface" "$DEST/PackageDescription.swiftmodule/$ARCH-apple-macos.swiftinterface"
        cp "$MANIFEST/PackageDescription.swiftmodule/$ARCH-apple-macos.swiftinterface" "$DEST/PackageDescription.swiftmodule/$ARCH-apple-macos.private.swiftinterface"
    done
    ln -sf "$MANIFEST/libPackageDescription.dylib" "$DEST/libPackageDescription.dylib"
    export SWIFTPM_CUSTOM_LIBS_DIR="$PWD/.build/swiftpm-libs"
fi
FLAGS=()
if [[ -f "$TOOLCHAIN/include/swift/module.modulemap" && -f "$TOOLCHAIN/include/swift/bridging.modulemap" ]] && grep -q 'module SwiftBridging' "$TOOLCHAIN/include/swift/module.modulemap"; then
    printf '// Legacy duplicate module map suppressed locally.\n' > .build/empty.modulemap
    python3 - "$TOOLCHAIN" <<'PY'
import json,os,sys
json.dump({'version':0,'roots':[{'type':'file','name':sys.argv[1]+'/include/swift/module.modulemap','external-contents':os.path.abspath('.build/empty.modulemap')}]},open('.build/sdk-overlay.json','w'))
PY
    FLAGS=(-Xswiftc -vfsoverlay -Xswiftc "$PWD/.build/sdk-overlay.json")
fi
exec swift "$@" "${FLAGS[@]}"
