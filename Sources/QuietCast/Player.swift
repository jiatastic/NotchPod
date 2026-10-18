import AVFoundation
import Combine
import MediaPlayer

@MainActor
final class PodcastPlayer: ObservableObject {
    @Published private(set) var episode: Episode?
    @Published private(set) var position = 0.0
    @Published private(set) var duration = 0.0
    @Published private(set) var isPlaying = false
    @Published private(set) var buffering = false
    @Published private(set) var videoVisible = false
    var hasVideo: Bool { episode?.isVideo == true }
    var videoPlayer: AVPlayer { player }
    @Published var error: String?
    @Published var rate: Float = 1 { didSet { if isPlaying { player.rate = rate }; updateNowPlaying() } }
    private let player: AVPlayer
    private let library: Library
    private var timeObserver: Any?
    private var statusObserver: NSKeyValueObservation?
    private var controlObserver: NSKeyValueObservation?
    private var endObserver: NSObjectProtocol?
    private var lastSaved = Date.distantPast
    private var generation = UUID()
    private var seekID = UUID()
    private var seeking = false
    private var remoteTargets: [(MPRemoteCommand, Any)] = []

    init(library: Library, avPlayer: AVPlayer = AVPlayer()) {
        self.library = library
        self.player = avPlayer
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 1, preferredTimescale: 600), queue: .main) { [weak self] time in
            Task { @MainActor in self?.tick(time.seconds) }
        }
        controlObserver = player.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
            let status = player.timeControlStatus
            Task { @MainActor in
                self?.isPlaying = status != .paused
                self?.buffering = status == .waitingToPlayAtSpecifiedRate
                self?.updateNowPlaying()
            }
        }
        configureRemoteCommands()
        if let id = library.snapshot.lastEpisodeID,
           let record = library.recent.first(where: { $0.episode.id == id }) {
            // Restore the last episode without downloading or autoplaying it.
            episode = record.episode; position = record.position; duration = record.episode.duration
        }
    }

    func play(_ episode: Episode) {
        if self.episode?.id == episode.id, let item = player.currentItem, item.status != .failed {
            toggle(); return
        }
        persist()
        generation = UUID()
        let id = generation
        self.episode = episode; position = library.position(for: episode); duration = episode.duration
        let resumePosition = position
        videoVisible = episode.isVideo
        seeking = false
        error = nil; buffering = true; isPlaying = true
        statusObserver = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        let item = AVPlayerItem(url: episode.mediaURL)
        player.replaceCurrentItem(with: item)
        statusObserver = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
            let status = item.status
            let seconds = item.duration.seconds
            let message = item.error?.localizedDescription
            Task { @MainActor in
                guard let self, self.generation == id else { return }
                if status == .failed {
                    self.error = message ?? "This episode couldn't be played. Please try again."; self.isPlaying = false; self.buffering = false
                    self.player.pause()
                } else if status == .readyToPlay {
                    if seconds.isFinite, seconds > 0 { self.duration = seconds }
                    let start = self.duration > 0 && resumePosition >= self.duration - 2 ? 0 : resumePosition
                    self.seek(start)
                }
            }
        }
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.generation == id else { return }
                self.isPlaying = false; self.buffering = false
                if self.duration > 0 { self.position = self.duration }
                self.persist(); self.updateNowPlaying()
            }
        }
        player.playImmediately(atRate: rate)
        library.record(episode, position: position)
        updateNowPlaying()
    }

    func toggle() {
        guard let episode else { return }
        if player.currentItem == nil || player.currentItem?.status == .failed { play(episode); return }
        if isPlaying { player.pause(); isPlaying = false; buffering = false; persist() }
        else {
            if duration > 0, position >= duration - 1 { seek(0) }
            player.playImmediately(atRate: rate); isPlaying = true
        }
        updateNowPlaying()
    }
    func seek(_ seconds: Double) {
        guard seconds.isFinite else { return }
        position = max(0, duration > 0 ? min(seconds, duration) : seconds)
        if player.currentItem != nil {
            seeking = true
            let id = UUID(); seekID = id
            let generation = generation
            player.seek(to: CMTime(seconds: position, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
                Task { @MainActor in
                    guard let self, self.generation == generation, self.seekID == id else { return }
                    self.seeking = false
                }
            }
        }
        persist(); updateNowPlaying()
    }
    func skip(_ seconds: Double) { seek(position + seconds) }
    func toggleVideo() {
        guard hasVideo else { return }
        // Visibility is presentation-only: do not replace, seek, or pause the player.
        videoVisible.toggle()
    }
    func persist() {
        if let episode { library.record(episode, position: position) }
        lastSaved = Date()
    }
    private func tick(_ seconds: Double) {
        guard player.currentItem?.status == .readyToPlay, !seeking, seconds.isFinite else { return }
        position = max(0, seconds)
        if let value = player.currentItem?.duration.seconds, value.isFinite, value > 0 { duration = value }
        if isPlaying, Date().timeIntervalSince(lastSaved) >= 5 { persist() }
        updateNowPlaying()
    }
    private func configureRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        center.skipBackwardCommand.preferredIntervals = [15]
        center.skipForwardCommand.preferredIntervals = [30]
        func bind(_ command: MPRemoteCommand, action: @escaping @MainActor () -> Void) {
            let token = command.addTarget { [weak self] _ in
                guard self != nil else { return .commandFailed }
                Task { @MainActor in action() }
                return .success
            }
            remoteTargets.append((command, token))
        }
        bind(center.playCommand) { [weak self] in if self?.isPlaying == false { self?.toggle() } }
        bind(center.pauseCommand) { [weak self] in if self?.isPlaying == true { self?.toggle() } }
        bind(center.togglePlayPauseCommand) { [weak self] in self?.toggle() }
        bind(center.skipBackwardCommand) { [weak self] in self?.skip(-15) }
        bind(center.skipForwardCommand) { [weak self] in self?.skip(30) }
    }
    private func updateNowPlaying() {
        guard let episode else { return }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = [
            MPMediaItemPropertyTitle: episode.title,
            MPMediaItemPropertyArtist: episode.podcast.title,
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: position,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? rate : 0
        ]
        MPNowPlayingInfoCenter.default().playbackState = isPlaying ? .playing : .paused
    }
    deinit {
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        for (command, token) in remoteTargets { command.removeTarget(token) }
    }
}
