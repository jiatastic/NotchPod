# Development notes

Technical behavior, privacy details and verification status. For the overview, see the [README](../README.md); for version history, see the [changelog](../CHANGELOG.md).

The package, executable, bundle ID (`com.quietcast.mac`) and data folder still use the original `QuietCast` name so existing listening history and settings keep loading.

## Build and run

Requires macOS 14+ and Swift 6+ Command Line Tools or Xcode. No third-party dependencies.

```sh
bash scripts/build-app.sh
open dist/NotchPod.app
```

The bundle is locally ad-hoc signed, not notarized for distribution. The package/executable and project directory still use QuietCast internally to preserve existing data and tooling.

## How it works

1. **Hover the physical notch:** the only player opens directly. No click-through to a larger player, brand header, toolbar, pin or collapse button. The camera area is left empty. When an episode is loaded, narrow side wings show artwork and playing/paused/buffering status while tucked; these are indicators, not a second set of controls.
2. **Listen:** artwork, episode title, one play/pause button, 15-second rewind, 30-second forward and a seek bar. No episode notes or clickable title leading to another screen.
3. **Find another podcast:** the single search icon opens search, following and recent listening together. An empty search field shows the local library; typing automatically searches Apple's directory after a 350ms pause. Episode results show their title, show and duration; a click plays the episode without first opening the show. Follow a show from its episode list.
4. **Leave:** collapse starts 250ms after leaving the expanded retention region, which includes 12pt edge tolerance; returning cancels the pending close. Audio continues. Editing, dragging and menus are protected. Esc or an outside click closes the surface. There is no pin setting.
5. **Advanced options:** the menu-bar waveform holds RSS entry, speed, video visibility, display selection and Quit. There is no main window or Dock icon.

On a display without a verified camera notch, the app uses a **native menu-bar popover**, not a fake black notch at the top center. Click the waveform and choose **Show Player** or **Search Episodes & Shows**. It uses normal system outside-click dismissal.

Notch geometry uses `NSScreen.safeAreaInsets` and the two auxiliary top-area rectangles in global points. The panel is only shown when these identify a real cutout; there is no guessed camera width. On notched displays, expansion stays centered and attached to the physical top, without taking keyboard focus on hover. Native active-always tracking areas and local/global mouse-only monitors prompt coordinate checks; a low-frequency pointer fallback covers the camera area. Hover entry waits 225ms inside the fixed tucked-body trigger and departure waits 250ms outside the fixed expanded region plus 12pt padding. Neither region follows the animated window frame. Pending entry is cancelled on departure and rechecks actual coordinates before opening; no keyboard focus is taken on hover. Frame updates use a critically damped spring (open frequency 48/s, close 58/s), preserving current size/velocity on reversal. Keyboard actions and Reduce Motion are immediate. The artwork/status indicator fades with actual viewport expansion; only its three small Core Animation bars loop during active playback, with a static equivalent for Reduce Motion.

## Playback and discovery

- iTunes-directory episode/show search (storefront follows the Mac's region setting, falling back to US; there is no region picker) and public RSS feeds, with no account. Search is automatic after a 350ms typing pause; **↑ / ↓** selects results and **Return** plays an episode or opens a show. IME composition keeps normal native text behavior and never sends unfinished marked text.
- Episode discovery uses Apple's `podcastEpisode` entity. Playback uses only its full publisher `episodeUrl` or a matched RSS enclosure, never `previewUrl` or an Apple webpage. When a feed URL is absent, the parent show is resolved via Apple's lookup endpoint. Cached RSS episodes/GUIDs preserve feed-scoped IDs and progress; missing metadata falls back to RSS, and unavailable episodes show an inline error without stopping the current player. Search coverage and availability depend on Apple's regional index and publishers.
- Following, recent listening, local seek progress, media keys and 0.8–2× speed remain. A restored episode is always paused. The 20-feed session cache refreshes in the background and retains cached episodes on errors.
- Public RSS video plays through the same AVPlayer. Use the menu-bar **Show Video / Hide Video** item; hiding the picture does not stop sound or reduce stream bandwidth. A public example is `https://feeds.twit.tv/twit_video_hd.xml`.
- Episode artwork falls back to the show cover, then a waveform placeholder. Shared requests, off-main thumbnail decoding and a bounded image cache avoid unstable artwork/layout.
- The entire app stays dark, regardless of system appearance or old preferences. There is no theme selector. Platform-exclusive media, private feeds requiring authentication and YouTube watch-page URLs are unsupported.

While the player/popover has focus: **⌘K** opens search, **⌘P** toggles playback, **Space** toggles playback outside text editing on the player, **⌘← / ⌘→** skips (⌘← rewinds by sentence when captions are on), and **Esc** closes. These are not global shortcuts.

## Local data and privacy

Existing data stays at `~/Library/Application Support/QuietCast/library.json`, including up to 200 recent listening records. Bundle ID `com.quietcast.mac`, and record compatibility are preserved. Old appearance preferences are ignored. `notchDisplay` selects the display. Previous pin/side-placement preferences are ignored. Historical RSS descriptions may remain in stored records for compatibility, but there is no notes UI.

No accounts, analytics, cloud sync, offline downloads, queues or cloud AI. Captions use only on-device speech recognition and translation; episode audio is cached temporarily for transcription and transcripts are cached locally (see 0.9.0). Apple receives directory queries automatically after the typing pause (not during IME composition), plus show lookups when needed; publishers receive feed, image and media requests. The app requests neither Accessibility nor Screen Recording and does not inspect other apps' content. It manages its own panel and uses pointer position for notch hover.

## Verification status

**Version 0.9.0:** `bash scripts/test.sh` passes (including new caption lookup/rewind checks; the script now also compiles `DirectorySearch.swift` and `Captions.swift`). Notch pages, including bilingual/original captions and the tucked caption strip, were rendered offscreen from live NPR/Apple directory data and reviewed. Physical-notch hover, scrubber dragging, press feedback and caption-strip resizing on hardware remain unverified.

**Version 0.8.0 is compile/package-only at the user's request. No test harnesses, screenshots, live playback checks or notch/popover interaction tests were run for this change.** Build success does not verify live search responses, IME timing, search-to-play resolution, physical alignment, perceived color matching with the hardware notch, hover timing, focus, full-screen Spaces or display-switching behavior. New directory parser/identity fixtures in `Tests/QuietCastTests/DirectorySearchTests.swift` are authored but unrun.

The existing core harness remains available for a later authorized pass:

```sh
bash scripts/test.sh
QUIETCAST_LIVE_TESTS=1 bash scripts/test.sh
QUIETCAST_LIVE_TESTS=1 QUIETCAST_VIDEO_TESTS=1 bash scripts/test.sh
```

Those checks cover parsing, filtering, compatible record decoding, persistence and optional real playback, not native notch/popover interaction. XCTest equivalents require full Xcode; the standalone harness supports Command Line Tools.

`scripts/swift.sh` applies project-local compatibility fixes for this Mac's toolchain without editing system SDK files.

## Source

- `QuietCastApp.swift`, `NotchController.swift`: accessory lifecycle, two-state presentation, verified camera geometry, native popover fallback and menu bar.
- `NotchView.swift`, `NotchNowPlaying.swift`, `SearchPanel.swift`: one compact player, collapsed artwork/status, unified search/library, episode list and RSS entry. `NotchMotion.swift` provides frame springs, the shared native black silhouette, native hover tracking and compositor-driven activity bars.
- `DirectorySearch.swift`, `PodcastService.swift`, `Library.swift`: episode/show directory metadata, debounced/cancellable search, bounded caches, publisher episode resolution and RSS/library handling.
- `Models.swift`, `Player.swift`: backward-compatible persisted records and the shared playback engine.
- `Appearance.swift`, `Artwork.swift`: one dark palette, the shared 20pt gutter, press/row button styles, and shared image loading/fallbacks.
- `Captions.swift`: caption cues, Off/Original/Bilingual mode, cue-boundary publishing, translation gating, sentence-aware rewind and the demo transcript. `Transcription.swift`: on-device look-ahead transcription, cue splitting and the transcript cache. Caption views (`CaptionView`, `CaptionLine`) and `CaptionTranslator` live in `NotchNowPlaying.swift`.
- Legacy `ContentView.swift`, `PlayerBar.swift`, `VideoPane.swift` and snapshot tooling remain for reference/shared media components. The large-window UI is not opened. Old snapshots do not validate the notch or popover.
