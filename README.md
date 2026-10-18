<h1 align="center">
  <img src="docs/images/icon.png" alt="Earshot" width="128">
  <br>
  Earshot
</h1>

<p align="center">
  <b>A podcast player that lives in your MacBook's notch, with live bilingual captions.</b>
  <br>
  Hover to listen. Glance to understand. Nothing to manage.
</p>

<p align="center">
  <img src="https://img.shields.io/badge/macOS-14%2B-black?logo=apple" alt="macOS 14+">
  <img src="https://img.shields.io/badge/Swift-6-F05138?logo=swift&logoColor=white" alt="Swift 6">
  <img src="https://img.shields.io/badge/dependencies-none-brightgreen" alt="No dependencies">
  <img src="https://img.shields.io/badge/privacy-on--device-blue" alt="On-device">
</p>

<p align="center">
  <img src="docs/images/player.png" alt="Earshot open in the notch, showing an episode with English and Chinese captions" width="820">
</p>

Earshot turns the notch into a quiet little podcast player. Hover over the camera and the player slides out; move away and it tucks back in while the audio keeps going. It has no main window, no Dock icon and no account.

Turn on captions and Earshot **transcribes the episode on your Mac** a little ahead of where you're listening, then **translates it into your language**. While you work, the current line sits under the notch, so a glance is enough to follow a podcast in a language you're still learning.

<p align="center">
  <img src="docs/images/captions-tucked.png" alt="A one-line translated caption hanging under the tucked notch" width="820">
</p>

## Features

- **Lives in the notch.** Hover to open, move away to tuck. Opening uses an interruptible spring animation and never steals keyboard focus.
- **Live bilingual captions.** The original line stays primary and the translation sits underneath, in the style of [Immersive Translate](https://immersivetranslate.com). While the notch is tucked, one line of caption hangs below the camera. Clicks pass through it to the apps underneath.
- **Look-ahead transcription.** Audio is recognized in 45-second chunks starting at the playhead, about 20× faster than real time on Apple Silicon, so captions are ready before you hear the words.
- **Sentence-aware rewind.** With captions on, ⟲ goes back to the start of the sentence you just missed instead of a blind 15 seconds.
- **Search everything from one field.** Episodes and shows from Apple's podcast directory appear as you type. Click an episode to play it right away. Any public RSS feed works too, including video podcasts.
- **Remembers where you were.** Following, recent listening, per-episode progress, media keys and 0.8–2× speed.

<p align="center">
  <img src="docs/images/search.png" alt="Search results for 'design' showing episodes with artwork" width="420">
</p>

## Private by design

| | |
| --- | --- |
| **Speech recognition** | On-device only (`SFSpeechRecognizer` with `requiresOnDeviceRecognition`). Audio never leaves your Mac. |
| **Translation** | Apple's on-device Translation framework. No API keys, no cloud. |
| **Accounts and analytics** | None. No server, no tracking, no sync. |
| **Network** | Apple's podcast directory for search, and publishers for feeds, artwork and audio. That's all. |
| **Permissions** | Speech Recognition, asked once, the first time you turn on captions. No Accessibility or Screen Recording. |

## Installation

**Requirements**
- A Mac with a notch, running macOS 14 Sonoma or later. On Macs without a notch, Earshot opens as a menu-bar popover instead.
- macOS 15 or later for caption translation. Transcription works on 14.
- Xcode or the Command Line Tools with Swift 6, to build.

There are no prebuilt releases yet, so build it from source:

```bash
git clone https://github.com/jiatastic/Earshot.git
cd Earshot
bash scripts/build-app.sh
open dist/Listen.app
```

> [!NOTE]
> The app is ad-hoc signed and not notarized. If macOS blocks it, run `xattr -dr com.apple.quarantine dist/Listen.app` and open it again.

## Usage

1. **Hover the notch** to open the player. Move away and it tucks back in; the audio keeps playing.
2. **Click 🔍** to search for an episode or show, or to pick from what you follow and listened to recently.
3. **Turn on captions** from the menu-bar waveform: **Captions → Original** or **Bilingual**.
4. **For translations,** download your language once in **System Settings → General → Language & Region → Translation Languages**. Earshot shows a reminder if it's missing.

| Shortcut | Action |
| --- | --- |
| `⌘K` | Search |
| `Space` / `⌘P` | Play / pause |
| `⌘←` | Back one sentence (or 15s without captions) |
| `⌘→` | Forward 30s |
| `Esc` | Tuck the notch |

Shortcuts work while the player has focus.

## Roadmap

- [x] Notch player with hover-to-open spring motion
- [x] Unified episode and show search
- [x] Public RSS, including video podcasts
- [x] On-device look-ahead transcription
- [x] Bilingual captions with on-device translation
- [x] Sentence-aware rewind
- [ ] Notarized releases and a Homebrew cask
- [ ] `SpeechAnalyzer` (macOS 26) for better long-form accuracy and punctuation
- [ ] Choose the translation language in the app
- [ ] Click a word in a caption to look it up
- [ ] Search inside an episode's transcript and jump to that moment

## Development

```bash
bash scripts/test.sh                              # parsing, persistence and caption checks
QUIETCAST_LIVE_TESTS=1 bash scripts/test.sh       # also hits the live directory and plays audio
```

The project has no third-party dependencies. [`docs/DEVELOPMENT.md`](docs/DEVELOPMENT.md) covers architecture, notch geometry, hover timing, privacy details and verification status. Version history is in [`CHANGELOG.md`](CHANGELOG.md).

## Acknowledgments

- [boring.notch](https://github.com/TheBoredTeam/boring.notch) showed how much a notch can do.
- [Immersive Translate](https://immersivetranslate.com) and [Language Reactor](https://www.languagereactor.com) inspired the bilingual caption layout and sentence-level rewind.
- Apple's Speech, Translation and AVFoundation frameworks do the heavy lifting, entirely on-device.
