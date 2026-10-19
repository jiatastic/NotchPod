import AVFoundation
import Combine
import Foundation
import Translation

struct CaptionCue: Identifiable, Equatable, Codable, Sendable {
    let id: Int
    let start: Double
    let end: Double
    let text: String
    var translation: String?
}

enum CaptionMode: String, CaseIterable {
    case off, original, bilingual
    var title: String {
        switch self { case .off: return "Off"; case .original: return "Original"; case .bilingual: return "Bilingual" }
    }
    /// Fixed caption height in the open player, so sentence changes never reflow it.
    var playerHeight: CGFloat {
        switch self { case .off: return 0; case .original: return 40; case .bilingual: return 78 }
    }
}

/// Timed captions for the current episode: cues from CaptionTranscriber,
/// translations from CaptionTranslator. Publishes on cue boundaries, not on
/// every clock tick.
@MainActor
final class CaptionModel: ObservableObject {
    private enum Key {
        static let mode = "captionMode"
        static let target = "captionTarget"
        // Demo transcript until a transcription engine is connected:
        // defaults write com.quietcast.mac captionDemo -bool true
        static let demo = "captionDemo"
    }
    @Published var mode: CaptionMode {
        didSet { UserDefaults.standard.set(mode.rawValue, forKey: Key.mode); refresh() }
    }
    /// Translation target as a BCP-47 identifier; nil follows the system language.
    @Published var target: String? {
        didSet {
            guard target != oldValue else { return }
            UserDefaults.standard.set(target, forKey: Key.target)
            // Translations belong to the old language.
            cues = cues.map { var cue = $0; cue.translation = nil; return cue }
            requestedTranslation = nil; refresh()
        }
    }
    /// Languages Apple's on-device Translation offers, for the picker.
    @Published private(set) var targets: [Locale.Language] = []
    @Published private(set) var cues: [CaptionCue] = []
    @Published private(set) var current: CaptionCue?
    /// Track + playing, not "a sentence is being spoken": gaps between cues
    /// must not shrink and regrow the tucked panel every few seconds.
    @Published private(set) var showsTuckedStrip = false
    /// Preparation or failure message shown in place of captions.
    @Published private(set) var status: String?
    /// nil when no translation is needed (Original mode, or already in the listener's language).
    @Published private(set) var translation: TranslationPair?
    /// One quiet line under the captions, e.g. a missing translation pack.
    @Published private(set) var notice: String?
    /// The pair whose language pack is missing; the player offers to download it.
    @Published private(set) var missingPack: TranslationPair?
    /// Set while the system download prompt for `missingPack` is running.
    @Published private(set) var downloadingPack: TranslationPair?
    private var requestedTranslation: TranslationPair?
    private let transcriber = CaptionTranscriber()
    private var transcribing: String?
    private var sourceLocale: Locale?
    private let player: PodcastPlayer
    private var timeObserver: Any?
    private var subscriptions = Set<AnyCancellable>()
    private var now = 0.0
    // Tracked here because @Published emits before player.episode is assigned.
    private var episodeID: String?

    var hasTrack: Bool { mode != .off && !cues.isEmpty }
    var showsCaptionArea: Bool { mode != .off && (hasTrack || status != nil) }

    init(player: PodcastPlayer) {
        self.player = player
        mode = CaptionMode(rawValue: UserDefaults.standard.string(forKey: Key.mode) ?? "") ?? .off
        target = UserDefaults.standard.string(forKey: Key.target)
        if #available(macOS 15, *) {
            Task { targets = await LanguageAvailability().supportedLanguages.sorted { Self.name($0) < Self.name($1) } }
        }
        player.$episode.removeDuplicates { $0?.id == $1?.id }
            .sink { [weak self] in self?.load(for: $0) }.store(in: &subscriptions)
        // Seeks update position synchronously; follow them between clock ticks.
        player.$position.sink { [weak self] in self?.tick($0) }.store(in: &subscriptions)
        player.$isPlaying.sink { [weak self] in self?.refresh(playing: $0) }.store(in: &subscriptions)
    }

    func attach(_ cues: [CaptionCue], episodeID: String) {
        guard self.episodeID == episodeID else { return }
        // Keep translations already applied to cues that arrive again.
        let translated = Dictionary(self.cues.compactMap { cue in cue.translation.map { (cue.id, $0) } }, uniquingKeysWith: { a, _ in a })
        self.cues = Self.normalized(self.cues.filter { old in !cues.contains { $0.id == old.id } } + cues).map {
            var cue = $0; cue.translation = cue.translation ?? translated[cue.id]; return cue
        }
        refresh()
    }
    func shutdown() {
        transcriber.cancel(); stopClock(); subscriptions.removeAll()
    }

    /// "Chinese (Simplified)", "Chinese (Taiwan)", "English": English like the rest of
    /// the UI, and never the listener's region ("zh-Hans-US" is not "Chinese (US)").
    static func name(_ language: Locale.Language) -> String {
        let english = Locale(identifier: "en_US")
        let code = language.languageCode?.identifier ?? language.minimalIdentifier
        let base = english.localizedString(forLanguageCode: code) ?? code
        let qualifier: String? = switch language.script?.identifier {
        case "Hans": "Simplified"
        case "Hant": "Traditional"
        default: language.region.flatMap { english.localizedString(forRegionCode: $0.identifier) }
        }
        return qualifier.map { "\(base) (\($0))" } ?? base
    }
    /// Untranslated cues nearest ahead of the playhead first.
    func untranslated(limit: Int) -> [CaptionCue] {
        cues.filter { $0.translation == nil && $0.end > now - 5 }.prefix(limit).map { $0 }
    }
    func apply(translations: [Int: String]) {
        guard !translations.isEmpty else { return }
        cues = cues.map { var cue = $0; cue.translation = translations[cue.id] ?? cue.translation; return cue }
        if let current { self.current = cues.first { $0.id == current.id } }
    }
    func downloadMissingPack() {
        guard let missingPack else { return }
        downloadingPack = missingPack
    }
    /// After the system prompt: re-check, since the person may have declined.
    func finishPackDownload() {
        downloadingPack = nil
        requestedTranslation = nil
        updateTranslation()
    }
    func translationFailed(_ message: String) {
        translation = nil; notice = message
    }

    /// Start of the sentence being spoken, or the previous one when we are
    /// already near its start. nil when there is no track to align to.
    func rewindTarget() -> Double? { hasTrack ? Self.rewindTarget(from: player.position, in: cues) : nil }

    /// nil before the first sentence, so rewinding never moves forward.
    static func rewindTarget(from time: Double, in cues: [CaptionCue]) -> Double? {
        guard let index = cues.lastIndex(where: { $0.start <= time }) else { return nil }
        if time - cues[index].start > 1.5 { return cues[index].start }
        return cues[max(0, index - 1)].start
    }
    /// Binary search over normalized cues; gaps between sentences return nil.
    static func cue(at time: Double, in cues: [CaptionCue]) -> CaptionCue? {
        var low = 0, high = cues.count - 1
        while low <= high {
            let mid = (low + high) / 2
            if cues[mid].end <= time { low = mid + 1 }
            else if cues[mid].start > time { high = mid - 1 }
            else { return cues[mid] }
        }
        return nil
    }
    /// Sorted, non-empty and non-overlapping, which the binary search requires.
    static func normalized(_ cues: [CaptionCue]) -> [CaptionCue] {
        let sorted = cues.filter { $0.start.isFinite && $0.end.isFinite && $0.end > $0.start }.sorted { $0.start < $1.start }
        return sorted.enumerated().compactMap { index, cue in
            let end = index + 1 < sorted.count ? min(cue.end, sorted[index + 1].start) : cue.end
            guard end > cue.start else { return nil }
            return CaptionCue(id: cue.id, start: cue.start, end: end, text: cue.text, translation: cue.translation)
        }
    }

    private func load(for episode: Episode?) {
        episodeID = episode?.id
        transcriber.cancel(); transcribing = nil
        cues = []; current = nil; status = nil; translation = nil; requestedTranslation = nil; notice = nil
        missingPack = nil; downloadingPack = nil
        sourceLocale = nil; now = player.position
        if let episode, UserDefaults.standard.bool(forKey: Key.demo) {
            attach(CaptionDemo.cues(duration: max(episode.duration, 600)), episodeID: episode.id)
            translation = nil
        } else { refresh(episode: episode) }
    }
    /// Transcription starts on demand: never while captions are off.
    private func transcribeIfNeeded(_ episode: Episode?) {
        guard mode != .off, let episode, transcribing != episode.id, !UserDefaults.standard.bool(forKey: Key.demo) else { return }
        transcribing = episode.id
        let id = episode.id
        transcriber.start(episode, position: { [weak self] in self?.player.position ?? 0 },
            status: { [weak self] message in
                guard let self, self.episodeID == id else { return }
                self.status = message
            },
            deliver: { [weak self] found, locale in
                guard let self, self.episodeID == id else { return }
                self.sourceLocale = locale
                self.attach(found, episodeID: id)
            })
    }
    /// Translation runs only once both language packs are on this Mac; a
    /// missing pack gets a pointer to Settings instead of a hidden download prompt.
    private func updateTranslation() {
        let target = Locale.Language(identifier: self.target ?? Locale.preferredLanguages.first ?? Locale.current.identifier)
        let pair = sourceLocale.flatMap { source in
            mode == .bilingual && source.language.languageCode != target.languageCode
                ? TranslationPair(source: source.language, target: target) : nil
        }
        guard pair != requestedTranslation else { return }
        requestedTranslation = pair
        translation = nil; notice = nil; missingPack = nil
        guard let pair, #available(macOS 15, *) else { return }
        Task {
            let status = await LanguageAvailability().status(from: pair.source, to: pair.target)
            guard requestedTranslation == pair else { return }
            switch status {
            case .installed: translation = pair
            case .supported:
                notice = "\(Self.name(pair.target)) isn't downloaded yet."
                missingPack = pair
            default: notice = "Translation isn't available for this language pair."
            }
        }
    }
    private func tick(_ seconds: Double) {
        guard seconds.isFinite else { return }
        now = seconds
        let cue = Self.cue(at: now, in: cues)
        if hasTrack, cue != current { current = cue }
    }
    private func refresh(playing: Bool? = nil, episode: Episode? = nil) {
        transcribeIfNeeded(episode ?? player.episode)
        updateTranslation()
        current = hasTrack ? Self.cue(at: now, in: cues) : nil
        let strip = hasTrack && (playing ?? player.isPlaying)
        if strip != showsTuckedStrip { showsTuckedStrip = strip }
        hasTrack ? startClock() : stopClock()
    }
    // 10 Hz only while a track is shown; the player's own clock is 1 Hz.
    private func startClock() {
        guard timeObserver == nil else { return }
        timeObserver = player.videoPlayer.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.1, preferredTimescale: 600),
                                                                  queue: .main) { [weak self] time in
            MainActor.assumeIsolated { self?.tick(time.seconds) }
        }
    }
    private func stopClock() {
        if let timeObserver { player.videoPlayer.removeTimeObserver(timeObserver) }
        timeObserver = nil
    }
}

struct TranslationPair: Equatable {
    let source: Locale.Language
    let target: Locale.Language
}

enum CaptionDemo {
    private static let lines: [(String, String)] = [
        ("This is Planet Money. I'm your host, and today we're going somewhere unusual.", "这里是《金钱星球》。我是主持人，今天我们要去一个不寻常的地方。"),
        ("Every year, buyers fly in from all over the world to bid on films nobody has seen yet.", "每年，买家从世界各地飞来，竞拍还没人看过的电影。"),
        ("It works a bit like an auction, except the product is a promise.", "它有点像拍卖会，只不过卖的是一个承诺。"),
        ("So how do you put a price on a story?", "那么，你要怎样给一个故事定价？"),
        ("That's the question we'll try to answer after the break.", "休息之后，我们会试着回答这个问题。"),
        ("And the answer, it turns out, has a lot to do with risk.", "而事实证明，答案和风险有很大关系。"),
    ]
    static func cues(duration: Double) -> [CaptionCue] {
        var cues: [CaptionCue] = []
        var start = 0.5, index = 0
        while start < duration {
            let line = lines[index % lines.count]
            let length = 2.2 + Double(line.0.count) * 0.055
            cues.append(CaptionCue(id: index, start: start, end: start + length, text: line.0, translation: line.1))
            start += length + 0.35; index += 1
        }
        return cues
    }
}
