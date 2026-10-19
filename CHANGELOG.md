# Changelog

## 0.9.2

- Fix: bilingual captions start translating as soon as a language pack is installed, without switching episodes or restarting. Previously a pack downloaded while NotchPod was open was ignored.
- While a translation is on its way, the caption shows "Translating…" instead of a blank line.
- README: a demo GIF recorded from the real app replaces the screenshots.

## 0.9.1

- New minimal pixel icon: a small notch with a sound wave.
- Expand and collapse now feel like the Dynamic Island: a slower damped spring (0.5s open, 0.45s close), with the content growing out of the notch (scale, fade, un-blur) and retracting smoothly when reversed.
- The tucked caption strip is narrower (340pt) and cues are shorter, so each one fits on one line.
- Language names read naturally in English ("Chinese (Simplified)"), and the missing-pack notice is one line with a Download button.
- Install with one line (`curl … | bash`) or from a drag-to-Applications DMG.
- End-to-end tests replace unit tests.

## 0.9.0

First public release, as **NotchPod** (internal identifiers keep the original QuietCast name so existing data loads). Captions are controlled from a captions button in the notch player: Off / Original / Bilingual and **Translate To** any of Apple's on-device translation languages, with a one-click **Download** when a language pack is missing. Licensed GPL-3.0.

Refines the notch and adds the **caption UI**. Every notch page shares one 20pt gutter; buttons scale slightly on press; list rows get a hover fill with the trailing glyph shown only on hover/selection; artwork is larger (48pt in the player) with continuous corners and a faint hairline; the native slider is replaced by a thin scrubber that thickens on hover/drag, with proportional-digit elapsed/remaining time. Search shows one loading indicator (the field spinner), and the region picker is removed: the directory storefront follows the Mac's region. Captions (menu bar **Captions → Off / Original / Bilingual**) follow Immersive Translate's bilingual pattern: the original sentence stays primary and the translation sits beneath it, quieter. While playing and tucked, a single-line, 340pt caption strip hangs under the camera (the translation in Bilingual mode, else the original); it stays put across pauses between sentences, is click-through, and never triggers hover-open. With a transcript, **⟲** and **⌘←** return to the start of the current sentence (or the previous one within 1.5s) instead of 15 seconds. Captions are **transcribed on this Mac** (`SFSpeechRecognizer`, on-device only, punctuation on): the episode audio is cached once, then 45s chunks are recognized nearest-the-playhead first (about 20× real time here), every finalized utterance is kept, and words become short cues (at most 8 words or 3.5s) by punctuation, pauses and length. Language comes from the episode text (`NLLanguageRecognizer`). Bilingual mode translates into the first preferred system language with Apple's on-device Translation (macOS 15+), nearest-the-playhead first, and only once both language packs are installed; otherwise a one-line notice points to System Settings › General › Language & Region › Translation Languages. Transcripts (not translations) are cached in `~/Library/Caches/QuietCast/Transcripts`; the temporary audio is deleted when transcription finishes. First use asks for Speech Recognition permission. `defaults write com.quietcast.mac captionDemo -bool true` substitutes a fixed demo transcript for UI review.

## 0.8.0

Adds **live episode and show search in the same field**. Pause typing for 350ms to query Apple's directory; Return is not required. Results are grouped into Episodes and Shows, with episodes first. Click an episode to play publisher audio/video directly; click a show to open its RSS episodes. IME marked text is held until composition commits. Query changes cancel older work, stale rows cannot play, and closing search cancels pending episode resolution. Ten successful searches are cached in memory for five minutes; partial category failures keep the other category visible with a retry hint. No new search entrance, account, server, theme or notes UI is added.

## 0.7.3

Separates hover intent from animation: 225ms entry dwell, 250ms departure grace and a stable expanded retention region with 12pt edge tolerance. The closed trigger stays at the tucked body's actual size, excluding transparent shoulders; moving over a shrinking panel no longer counts as entering the notch. Dismissal under the pointer requires leaving the trigger before hover can reopen. A single native opaque sRGB-black silhouette now sits behind transparent player/search content, with vibrancy disabled and an explicit sRGB window color space. Physical black matching remains unverified.

## 0.7.2

Introduced one pure-black surface and widens playback to 400pt (search: 420pt). Expand/collapse now retain the same mounted content inside a continuously resized viewport, driven by an interruptible critically damped window-frame spring. Collapsed playback shows an 18pt cover and three tiny status bars beside the camera. Light/System themes and appearance selectors remain removed.

## 0.7

Simplified the app to **tucked / open**. There is one compact player, not a preview and a second full player. Episode notes are removed, including from the legacy window components. Interface copy is English; original podcast titles are preserved.
