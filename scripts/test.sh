#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
# Prepare local SDK fixes; build ensures app sources compile too.
bash scripts/swift.sh build -j 2
FLAGS=()
if [[ -f .build/sdk-overlay.json ]]; then FLAGS=(-vfsoverlay "$PWD/.build/sdk-overlay.json"); fi
xcrun swiftc -swift-version 5 -parse-as-library "${FLAGS[@]}" \
    Sources/QuietCast/Models.swift Sources/QuietCast/PodcastService.swift Sources/QuietCast/DirectorySearch.swift \
    Sources/QuietCast/Library.swift Sources/QuietCast/Player.swift Sources/QuietCast/VideoPane.swift \
    Sources/QuietCast/Appearance.swift Sources/QuietCast/Captions.swift Sources/QuietCast/Transcription.swift \
    scripts/Verify.swift -o .build/verify
.build/verify
