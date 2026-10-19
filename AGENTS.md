# AGENTS.md

NotchPod is a minimal macOS podcast player that lives in the notch, with on-device bilingual captions.
It's built with SwiftUI and AppKit, targets macOS 14+, and uses the Swift 6 toolchain in Swift 5 language mode. It has no dependencies.

## Commands
- Build and run: `bash scripts/build-app.sh && open dist/NotchPod.app`
- Test: `bash scripts/e2e.sh`. Add `E2E_VIDEO=1` to include video. Screenshots go to `e2e-shots/`.
- Regenerate the icon: `python3 scripts/pixel_icon.py <dir>.iconset`, then `iconutil -c icns`.

## Verification reality
- This Mac has **Command Line Tools only, no Xcode**. Always build through `scripts/swift.sh`, which patches the toolchain. XCTest isn't available.
- **E2E tests only, no unit tests.** Every change gets a real scenario in `scripts/e2e/E2E.swift`: a real feed, real playback, real transcription, real notch views rendered offscreen.
- After any UI change, run e2e and **look at `e2e-shots/`**. A passing build isn't enough.
- Hover on the physical notch can't be automated. Say so, and ask the user to check it.

## Never break
- Internal names stay **QuietCast**: the package, the bundle ID `com.quietcast.mac`, and `~/Library/Application Support/QuietCast`. Renaming them loses users' history.
- Old `library.json` records must keep decoding.
- Speech and translation stay on-device. Add no network services, analytics or API keys.
- Read notch geometry from `NSScreen` at runtime; never hardcode it.

## Choices we made
- `ObservableObject` + `@EnvironmentObject`, not `@Observable`.
- Captions publish only on cue changes, never per clock tick.
- Notch motion is a damped window spring (open 0.5s, close 0.45s). Content scale, opacity and blur follow `expansionProgress`, so reversals are seamless.

## Gotchas we've hit
- `@Published` emits *before* the value is assigned. Use the value the sink receives; don't read the property back.
- In callbacks already on `.main`, use `MainActor.assumeIsolated`, not `Task { @MainActor }`.
- On-device speech finalizes each utterance after a pause. Collect results with `speechRecognitionMetadata`, or you lose most of the audio.
- Remove AVPlayer time observers and cancel tasks in `shutdown()`.

## Design
- Minimal: every element has to earn its place. No settings windows; controls live in the notch.
- Spacing comes from `Metrics` (20pt gutter) and colors from `Palette`. No magic numbers.
- Animate only transform, opacity and blur. Keyboard actions don't animate. Honor Reduce Motion.

## Writing and git
- Keep the README and docs short. Cut repetition.
- Use Conventional Commits: `feat:`, `fix:`, `chore:`, `docs:`, `refactor:`, `test:`, `perf:`, `style:`, `ci:`, `build:`. Write one imperative line, e.g. `fix: keep the caption strip on one line`.
- **Never add Claude or AI as an author or co-author.**
- Don't push, release or change repo visibility unless asked.
