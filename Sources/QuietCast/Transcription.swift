import AVFoundation
import CryptoKit
import NaturalLanguage
import Speech

/// On-device, look-ahead transcription. The episode audio is fetched once into
/// Caches, then cut into chunks that are recognized nearest-the-playhead first,
/// so captions are ready before the words are heard. Nothing leaves the Mac
/// except the publisher media request the player already makes.
@MainActor
final class CaptionTranscriber {
    static let chunkLength = 45.0
    private var task: Task<Void, Never>?

    /// `position` is read on every chunk so seeks re-prioritize the queue.
    func start(_ episode: Episode, position: @escaping @MainActor () -> Double,
               status: @escaping @MainActor (String?) -> Void,
               deliver: @escaping @MainActor ([CaptionCue], Locale) -> Void) {
        cancel()
        task = Task {
            do {
                if let cached = TranscriptCache.load(episode) {
                    deliver(cached.cues, Locale(identifier: cached.locale))
                    if cached.complete { status(nil); return }
                }
                status("Preparing captions…")
                guard await Self.authorize() else {
                    status("Turn on Speech Recognition for NotchPod in System Settings to see captions."); return
                }
                guard let recognizer = Self.recognizer(for: episode) else {
                    status("On-device captions aren't available for this language."); return
                }
                let audio = try await Self.download(episode)
                defer { try? FileManager.default.removeItem(at: audio) }
                let duration = try await AVURLAsset(url: audio).load(.duration).seconds
                guard duration.isFinite, duration > 0 else { throw PodcastError.noMedia }
                let chunks = Int((duration / Self.chunkLength).rounded(.up))
                var done = Set(TranscriptCache.load(episode)?.chunks ?? [])
                var cues = TranscriptCache.load(episode)?.cues ?? []
                while done.count < chunks, !Task.isCancelled {
                    let playhead = min(chunks - 1, max(0, Int(position() / Self.chunkLength)))
                    let next = (playhead..<chunks).first { !done.contains($0) } ?? (0..<chunks).first { !done.contains($0) }!
                    if cues.isEmpty { status("Transcribing…") }
                    let found = try await Self.transcribe(audio, chunk: next, recognizer: recognizer)
                    guard !Task.isCancelled else { return }
                    done.insert(next); cues += found
                    deliver(found, recognizer.locale); status(nil)
                    TranscriptCache.save(episode, locale: recognizer.locale, cues: cues,
                                         chunks: done.sorted(), complete: done.count == chunks)
                }
            } catch is CancellationError {
            } catch {
                guard !Task.isCancelled else { return }
                status("Captions couldn't be prepared. \(error.localizedDescription)")
            }
        }
    }
    func cancel() { task?.cancel(); task = nil }

    // MARK: Recognition

    private static func authorize() async -> Bool {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: return true
        case .notDetermined:
            return await withCheckedContinuation { done in
                SFSpeechRecognizer.requestAuthorization { done.resume(returning: $0 == .authorized) }
            }
        default: return false
        }
    }
    /// Language comes from the episode's own text; no picker.
    private static func recognizer(for episode: Episode) -> SFSpeechRecognizer? {
        let detector = NLLanguageRecognizer()
        detector.processString([episode.title, episode.podcast.title, String(episode.summary.prefix(600))].joined(separator: "\n"))
        let language = detector.dominantLanguage?.rawValue ?? Locale.current.language.languageCode?.identifier ?? "en"
        let supported = SFSpeechRecognizer.supportedLocales().filter { $0.language.languageCode?.identifier == language.prefix(2).description }
        // Prefer the listener's own region variant, then the most common one.
        let preferred = supported.first { $0.region == Locale.current.region }
            ?? supported.first { ["en-US", "zh-CN", "ja-JP", "es-ES", "fr-FR", "de-DE"].contains($0.identifier(.bcp47)) }
            ?? supported.first
        guard let preferred, let recognizer = SFSpeechRecognizer(locale: preferred),
              recognizer.supportsOnDeviceRecognition else { return nil }
        return recognizer
    }

    private static func transcribe(_ audio: URL, chunk: Int, recognizer: SFSpeechRecognizer) async throws -> [CaptionCue] {
        let offset = Double(chunk) * chunkLength
        let buffers = try await Task.detached(priority: .utility) {
            try await readPCM(audio, from: offset, length: chunkLength)
        }.value
        guard !buffers.isEmpty else { return [] }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true
        request.addsPunctuation = true
        // On-device recognition restarts after each pause and its final result
        // holds only the last utterance. Partial results must be on so every
        // finalized utterance (the ones carrying metadata) can be collected.
        request.shouldReportPartialResults = true
        request.taskHint = .dictation
        buffers.forEach { request.append($0) }
        request.endAudio()
        let segments: [SFTranscriptionSegment] = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { done in
                var resumed = false
                var collected: [SFTranscriptionSegment] = []
                func collect(_ result: SFSpeechRecognitionResult) {
                    let end = collected.last.map { $0.timestamp + $0.duration } ?? -1
                    collected += result.bestTranscription.segments.filter { $0.timestamp >= end - 0.05 && $0.duration > 0 }
                }
                recognizer.recognitionTask(with: request) { result, error in
                    guard !resumed else { return }
                    if let result, result.speechRecognitionMetadata != nil || result.isFinal { collect(result) }
                    if let result, result.isFinal {
                        resumed = true; done.resume(returning: collected)
                    } else if let error {
                        resumed = true
                        // Silence or music: "no speech detected" is an empty chunk, not a failure.
                        if (error as NSError).code == 1110 { done.resume(returning: collected) } else { done.resume(throwing: error) }
                    }
                }
            }
        } onCancel: { request.endAudio() }
        let spaced = !["zh", "ja", "th"].contains(recognizer.locale.language.languageCode?.identifier ?? "")
        return sentences(segments, offset: offset, firstID: chunk * 1000, spaced: spaced)
    }

    /// 16 kHz mono float: what the recognizer wants, and cheap to hold for 45s.
    nonisolated private static func readPCM(_ url: URL, from start: Double, length: Double) async throws -> [AVAudioPCMBuffer] {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else { throw PodcastError.noMedia }
        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 600),
                                       duration: CMTime(seconds: length, preferredTimescale: 600))
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16_000, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false,
            AVLinearPCMIsBigEndianKey: false
        ])
        reader.add(output)
        guard reader.startReading(),
              let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)
        else { throw reader.error ?? PodcastError.noMedia }
        var buffers: [AVAudioPCMBuffer] = []
        while let sample = output.copyNextSampleBuffer() {
            let frames = AVAudioFrameCount(CMSampleBufferGetNumSamples(sample))
            guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { continue }
            buffer.frameLength = frames
            if CMSampleBufferCopyPCMDataIntoAudioBufferList(sample, at: 0, frameCount: Int32(frames),
                                                            into: buffer.mutableAudioBufferList) == noErr {
                buffers.append(buffer)
            }
        }
        if reader.status == .failed { throw reader.error ?? PodcastError.noMedia }
        return buffers
    }

    /// Words → cues: split on terminal punctuation, a long pause, or length.
    nonisolated static func sentences(_ words: [SFTranscriptionSegment], offset: Double, firstID: Int, spaced: Bool) -> [CaptionCue] {
        sentences(words.map { (text: $0.substring, start: $0.timestamp, end: $0.timestamp + $0.duration) },
                  offset: offset, firstID: firstID, spaced: spaced)
    }
    nonisolated static func sentences(_ words: [(text: String, start: Double, end: Double)], offset: Double,
                                      firstID: Int, spaced: Bool) -> [CaptionCue] {
        var cues: [CaptionCue] = []
        var current: [(text: String, start: Double, end: Double)] = []
        func flush() {
            guard let first = current.first, let last = current.last else { return }
            let text = current.map(\.text).joined(separator: spaced ? " " : "")
            cues.append(CaptionCue(id: firstID + cues.count, start: offset + first.start, end: offset + last.end, text: text))
            current = []
        }
        for (index, word) in words.enumerated() {
            if let last = current.last, word.start - last.end > 1.0 { flush() }
            current.append(word)
            let terminal = word.text.last.map { ".?!。？！".contains($0) } ?? false
            // On-device punctuation is sparse; length keeps each cue to one strip line.
            let long = word.end - (current.first?.start ?? word.start) > 3.5 || current.count >= (spaced ? 8 : 16)
            if terminal || long || index == words.count - 1 { flush() }
        }
        return cues
    }

    // MARK: Media

    private static func download(_ episode: Episode) async throws -> URL {
        let folder = try TranscriptCache.folder().appendingPathComponent("Audio", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let ext = episode.mediaURL.pathExtension.isEmpty ? "mp3" : episode.mediaURL.pathExtension
        let target = folder.appendingPathComponent(TranscriptCache.key(episode)).appendingPathExtension(ext)
        if FileManager.default.fileExists(atPath: target.path) { return target }
        var request = URLRequest(url: episode.mediaURL)
        request.timeoutInterval = 60
        let (temporary, response) = try await URLSession.shared.download(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { throw PodcastError.badResponse }
        try? FileManager.default.removeItem(at: target)
        try FileManager.default.moveItem(at: temporary, to: target)
        return target
    }
}

/// Finished and partial transcripts, keyed by episode, in Caches (purgeable).
enum TranscriptCache {
    struct Entry: Codable {
        var locale: String
        var cues: [CaptionCue]
        var chunks: [Int]
        var complete: Bool
    }
    static func folder() throws -> URL {
        // e2e runs point this elsewhere so they never read or clear real caches.
        if let override = ProcessInfo.processInfo.environment["QUIETCAST_CACHE_DIR"] {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return try FileManager.default.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("QuietCast/Transcripts", isDirectory: true)
    }
    static func key(_ episode: Episode) -> String {
        SHA256.hash(data: Data((episode.podcast.id + "\n" + episode.id).utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
    }
    static func load(_ episode: Episode) -> Entry? {
        guard let url = try? folder().appendingPathComponent(key(episode) + ".json"),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Entry.self, from: data)
    }
    static func save(_ episode: Episode, locale: Locale, cues: [CaptionCue], chunks: [Int], complete: Bool) {
        guard let folder = try? folder() else { return }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // Translations are cheap and target-specific; only the transcript is cached.
        let plain = cues.map { CaptionCue(id: $0.id, start: $0.start, end: $0.end, text: $0.text) }
        let entry = Entry(locale: locale.identifier, cues: plain, chunks: chunks, complete: complete)
        try? JSONEncoder().encode(entry).write(to: folder.appendingPathComponent(key(episode) + ".json"), options: .atomic)
    }
}
