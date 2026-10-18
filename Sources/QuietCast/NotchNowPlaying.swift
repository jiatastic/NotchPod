import SwiftUI
import Translation

/// The only player surface. No preview layer, notes, toolbar or duplicate controls.
struct NotchNowPlayingView: View {
    @EnvironmentObject private var notch: NotchController
    @EnvironmentObject private var player: PodcastPlayer
    @EnvironmentObject private var captions: CaptionModel

    var body: some View {
        if let episode = player.episode {
            VStack(spacing: 0) {
                if player.hasVideo {
                    NativeVideoSurface(player: player.videoPlayer)
                        .frame(height: player.videoVisible ? 154 : 0)
                        .background(Color.black).clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .opacity(player.videoVisible ? 1 : 0).clipped()
                        .allowsHitTesting(player.videoVisible).accessibilityHidden(!player.videoVisible)
                        .padding(.bottom, player.videoVisible ? 12 : 0)
                }
                HStack(spacing: 12) {
                    Artwork(url: episode.artworkURL, fallbackURL: episode.podcast.artworkURL, size: 48)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(episode.title).font(.system(size: 13, weight: .semibold)).lineLimit(2).help(episode.title)
                        Text(player.buffering ? "Buffering…" : episode.podcast.title)
                            .font(.system(size: 12)).foregroundStyle(Palette.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    CaptionMenu()
                    Button { notch.showSearch() } label: {
                        Image(systemName: "magnifyingglass").font(.system(size: 13, weight: .medium))
                            .frame(width: 30, height: 30).contentShape(Rectangle())
                    }.buttonStyle(PressableStyle()).foregroundStyle(Palette.secondary)
                        .help("Search episodes or shows").accessibilityLabel("Search episodes or shows")
                }
                if let error = player.error {
                    HStack {
                        Text(error).font(.system(size: 11)).foregroundStyle(Palette.secondary).lineLimit(2)
                        Spacer()
                        Button("Retry") { player.play(episode) }.font(.system(size: 11, weight: .medium)).buttonStyle(PressableStyle())
                    }.padding(.top, 10)
                }
                if captions.showsCaptionArea {
                    Group {
                        if captions.hasTrack {
                            CaptionView(cue: captions.current, bilingual: captions.mode == .bilingual)
                        } else if let status = captions.status {
                            Text(status).font(.system(size: 12)).foregroundStyle(Palette.tertiary).lineLimit(2)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .frame(height: captions.mode.playerHeight, alignment: .topLeading)
                    // Without a translation (pack missing), the notice takes the translation's lines.
                    .overlay(alignment: .bottomLeading) {
                        if captions.hasTrack, let notice = captions.notice {
                            HStack(spacing: 12) {
                                Text(captions.downloadingPack == nil ? notice : "Downloading…")
                                    .font(.system(size: 11)).foregroundStyle(Palette.tertiary).lineLimit(1)
                                Spacer(minLength: 0)
                                if captions.missingPack != nil, captions.downloadingPack == nil {
                                    Button("Download") { captions.downloadMissingPack() }
                                        .font(.system(size: 11, weight: .semibold)).foregroundStyle(Palette.text)
                                        .buttonStyle(PressableStyle())
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading).background(Palette.surface)
                        }
                    }
                    .clipped()
                    .padding(.top, Metrics.captionSpacing)
                }
                NotchTimeline().padding(.top, 14)
                HStack(spacing: 36) {
                    // With a transcript, back means "the sentence I just missed".
                    control(captions.hasTrack ? "gobackward" : "gobackward.15",
                            label: captions.hasTrack ? "Back one sentence" : "Back 15 seconds") { notch.rewind() }
                    Button { player.toggle() } label: {
                        Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 16)).foregroundStyle(Palette.onText)
                            .frame(width: 44, height: 44).background(Palette.text, in: Circle())
                    }.buttonStyle(PressableStyle(scale: 0.92)).accessibilityLabel(player.isPlaying ? "Pause" : "Play")
                    control("goforward.30", label: "Forward 30 seconds") { player.skip(30) }
                }.frame(maxWidth: .infinity).padding(.top, 8)
            }.padding(.horizontal, Metrics.gutter).padding(.top, 14).padding(.bottom, 18)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                // The system's download prompt is anchored here; don't tuck under it.
                .onChange(of: captions.downloadingPack != nil) { _, downloading in notch.isInteracting = downloading }
        } else {
            Button { notch.showSearch() } label: {
                Label("Search episodes or shows", systemImage: "magnifyingglass")
                    .font(.system(size: 13)).foregroundStyle(Palette.secondary)
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .background(Palette.hover, in: Capsule())
                    .contentShape(Capsule())
            }.buttonStyle(PressableStyle(scale: 0.97)).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
    private func control(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 19)).foregroundStyle(Palette.text.opacity(0.75))
                .frame(width: 36, height: 36).contentShape(Rectangle())
        }.buttonStyle(PressableStyle(scale: 0.9)).help(label).accessibilityLabel(label)
    }
}

/// A thin scrubber: 4pt at rest, thickens with a knob on hover or drag.
/// The native Slider's permanent knob reads as heavy chrome inside the notch.
struct NotchTimeline: View {
    @EnvironmentObject private var notch: NotchController
    @EnvironmentObject private var player: PodcastPlayer
    @State private var hovering = false
    // Gesture state resets on cancellation (tuck, menu, resign key), so the
    // timeline can never stay frozen on an abandoned drag.
    @GestureState private var scrub: Double?

    private var enabled: Bool { player.duration > 0 }
    private var shown: Double { scrub ?? min(player.position, max(1, player.duration)) }
    private var fraction: CGFloat { enabled ? CGFloat(shown / player.duration) : 0 }
    private var active: Bool { enabled && (hovering || scrub != nil) }

    var body: some View {
        VStack(spacing: 6) {
            GeometryReader { track in
                let drag = DragGesture(minimumDistance: 0)
                    .updating($scrub) { value, state, _ in
                        guard enabled else { return }
                        state = Double(min(max(0, value.location.x / max(1, track.size.width)), 1)) * player.duration
                    }
                    .onEnded { value in
                        guard enabled else { return }
                        player.seek(Double(min(max(0, value.location.x / max(1, track.size.width)), 1)) * player.duration)
                    }
                ZStack(alignment: .leading) {
                    Capsule().fill(Palette.track)
                    Capsule().fill(active ? Palette.text : Palette.text.opacity(0.8))
                        .frame(width: max(active ? 6 : 4, track.size.width * fraction))
                }
                .frame(height: active ? 6 : 4)
                .overlay(alignment: .leading) {
                    Circle().fill(Palette.text).frame(width: 12, height: 12)
                        .shadow(color: .black.opacity(0.4), radius: 2)
                        .offset(x: min(max(0, track.size.width * fraction - 6), track.size.width - 12))
                        .scaleEffect(active ? 1 : 0.5).opacity(active ? 1 : 0)
                }
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(drag)
                .onHover { hovering = $0 }
                .animation(.easeOut(duration: 0.15), value: active)
            }.frame(height: 14)
            HStack {
                Text(clock(shown))
                Spacer()
                Text(enabled ? "\u{2212}" + clock(max(0, player.duration - shown)) : "—:—")
            }.font(.system(size: 11, weight: .medium).monospacedDigit()).foregroundStyle(Palette.tertiary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Playback progress")
        .accessibilityValue(enabled ? "\(clock(shown)) of \(clock(player.duration))" : "Unknown duration")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: player.skip(30)
            case .decrement: notch.rewind()
            @unknown default: break
            }
        }
        .onChange(of: scrub != nil) { _, dragging in notch.isInteracting = dragging }
        .onDisappear { notch.isInteracting = false }
    }
}

/// Captions on/off and the translation language, where the captions are,
/// instead of only in the menu bar (which the notch can hide).
private struct CaptionMenu: View {
    @EnvironmentObject private var captions: CaptionModel
    var body: some View {
        Menu {
            Picker("Captions", selection: $captions.mode) {
                ForEach(CaptionMode.allCases, id: \.self) { Text($0.title).tag($0) }
            }.pickerStyle(.inline)
            if !captions.targets.isEmpty {
                Picker("Translate To", selection: $captions.target) {
                    Text("System Language").tag(String?.none)
                    Divider()
                    ForEach(captions.targets, id: \.minimalIdentifier) { language in
                        Text(CaptionModel.name(language)).tag(Optional(language.minimalIdentifier))
                    }
                }.pickerStyle(.menu)
            }
        } label: {
            Image(systemName: captions.mode == .off ? "captions.bubble" : "captions.bubble.fill")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(captions.mode == .off ? Palette.secondary : Palette.text)
                .frame(width: 30, height: 30).contentShape(Rectangle())
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
        .help("Captions").accessibilityLabel("Captions")
        .accessibilityValue(captions.mode.title)
    }
}

/// Immersive Translate's bilingual reading pattern: the original line stays
/// primary; the translation sits directly beneath it, quieter, never replacing it.
struct CaptionView: View {
    let cue: CaptionCue?
    var bilingual = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        CaptionTransition(id: cue?.id) {
            if let cue {
                VStack(alignment: .leading, spacing: 4) {
                    Text(cue.text).font(.system(size: 14, weight: .medium)).foregroundStyle(Palette.text).lineLimit(2)
                    if bilingual, let translation = cue.translation {
                        Text(translation).font(.system(size: 13)).foregroundStyle(Palette.secondary).lineLimit(2)
                    }
                }
                .lineSpacing(2)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Caption")
        .accessibilityValue([cue?.text, cue?.translation].compactMap { $0 }.joined(separator: ". "))
        .accessibilityAddTraits(.updatesFrequently)
    }
}

/// The tucked strip: exactly one line, in the listener's language when a
/// translation exists, so a glance at the notch is enough.
struct CaptionLine: View {
    let cue: CaptionCue?
    var bilingual = true
    var body: some View {
        CaptionTransition(id: cue?.id) {
            if let cue {
                Text(bilingual ? cue.translation ?? cue.text : cue.text)
                    .font(.system(size: 13, weight: .medium)).foregroundStyle(Palette.text)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Caption")
        .accessibilityValue(cue.map { bilingual ? $0.translation ?? $0.text : $0.text } ?? "")
        .accessibilityAddTraits(.updatesFrequently)
    }
}

/// Sentence changes crossfade with a slight blur and rise.
private struct CaptionTransition<Content: View>: View {
    let id: Int?
    @ViewBuilder let content: () -> Content
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        ZStack(alignment: .top) {
            content()
                .id(id)
                .transition(reduceMotion ? .opacity : .asymmetric(
                    insertion: .opacity.combined(with: .offset(y: 4)).combined(with: .captionBlur),
                    removal: .opacity.combined(with: .captionBlur)))
        }
        .animation(.easeOut(duration: 0.2), value: id)
    }
}

/// Feeds untranslated cues through Apple's on-device Translation, nearest the
/// playhead first. Lives in the view tree because sessions are SwiftUI-scoped.
@available(macOS 15, *)
struct CaptionTranslator: View {
    @EnvironmentObject private var captions: CaptionModel
    private var configuration: TranslationSession.Configuration? {
        captions.translation.map { TranslationSession.Configuration(source: $0.source, target: $0.target) }
    }
    private var download: TranslationSession.Configuration? {
        captions.downloadingPack.map { TranslationSession.Configuration(source: $0.source, target: $0.target) }
    }
    var body: some View {
        Color.clear.frame(width: 0, height: 0).accessibilityHidden(true)
            .translationTask(configuration) { session in
                while !Task.isCancelled {
                    let batch = captions.untranslated(limit: 12)
                    guard !batch.isEmpty else {
                        try? await Task.sleep(nanoseconds: 400_000_000); continue
                    }
                    do {
                        let responses = try await session.translations(from: batch.map {
                            TranslationSession.Request(sourceText: $0.text, clientIdentifier: String($0.id))
                        })
                        captions.apply(translations: Dictionary(responses.compactMap { response in
                            response.clientIdentifier.flatMap(Int.init).map { ($0, response.targetText) }
                        }, uniquingKeysWith: { a, _ in a }))
                    } catch {
                        if !Task.isCancelled { captions.translationFailed("Translation isn't available: \(error.localizedDescription)") }
                        return
                    }
                }
            }
            // Asks the system to show its own language-pack download prompt.
            .translationTask(download) { session in
                try? await session.prepareTranslation()
                captions.finishPackDownload()
            }
    }
}

private struct BlurModifier: ViewModifier {
    let radius: CGFloat
    func body(content: Content) -> some View { content.blur(radius: radius) }
}

private extension AnyTransition {
    // Blur bridges the crossfade so two sentences never read as overlapping.
    static let captionBlur = AnyTransition.modifier(active: BlurModifier(radius: 3), identity: BlurModifier(radius: 0))
}
