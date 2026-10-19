# Development

```bash
bash scripts/build-app.sh && open dist/NotchPod.app   # build + run
bash scripts/e2e.sh                                   # e2e: real feed, playback, captions, UI shots, installer
python3 scripts/pixel_icon.py <dir>.iconset           # regenerate the pixel icon
```

macOS 14+, Swift 6 (Command Line Tools are enough), no dependencies. `scripts/swift.sh` patches this toolchain locally.

> Internals keep the original name **QuietCast** (package, bundle ID `com.quietcast.mac`, `~/Library/Application Support/QuietCast`) so existing data keeps loading.

## Layout

| File | Role |
| --- | --- |
| `NotchController` | Panel, notch geometry, hover timing, menu bar |
| `NotchMotion` | Frame spring, black silhouette, hover tracking |
| `NotchView`, `NotchNowPlaying`, `SearchPanel` | The notch UI |
| `Captions`, `Transcription` | Caption timing, on-device transcription + translation |
| `Player`, `Library`, `PodcastService`, `DirectorySearch` | Playback, persistence, RSS, Apple directory |
| `Appearance`, `Artwork` | Palette, metrics, button styles, image loading |

`ContentView`, `PlayerBar` and `VideoPane` are a legacy windowed UI; only `VideoPane` is still used.

## Behavior worth knowing

- **Notch:** shown only when `NSScreen` reports a real cutout; otherwise a menu-bar popover.
- **Hover:** opens after 225ms; closes 250ms after leaving (12pt tolerance). The caption strip is click-through and never opens the player.
- **Motion:** damped window spring (open 0.5s with a slight settle, close 0.45s). Content scales, fades and un-blurs with the live frame, so reversals are seamless.
- **Captions:** 45s chunks are transcribed from the playhead outward, cached in `~/Library/Caches/QuietCast/Transcripts`, and translated only once the language pack is installed.
- **Privacy:** speech and translation run on-device. The network is used only for the Apple directory and publisher feeds and media.
