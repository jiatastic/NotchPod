#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
bash scripts/swift.sh build -j 2
FLAGS=()
if [[ -f .build/sdk-overlay.json ]]; then FLAGS=(-vfsoverlay "$PWD/.build/sdk-overlay.json"); fi
xcrun swiftc -swift-version 5 -parse-as-library "${FLAGS[@]}" \
    Sources/QuietCast/Models.swift Sources/QuietCast/PodcastService.swift \
    Sources/QuietCast/Library.swift Sources/QuietCast/Player.swift \
    Sources/QuietCast/ContentView.swift Sources/QuietCast/VideoPane.swift Sources/QuietCast/Appearance.swift \
    Sources/QuietCast/Artwork.swift Sources/QuietCast/SearchPanel.swift Sources/QuietCast/PlayerBar.swift \
    scripts/Snapshot.swift -o .build/snapshot
.build/snapshot "$@"
