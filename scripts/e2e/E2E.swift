import AppKit
import AVFoundation
import SwiftUI
import Translation

/// End-to-end checks against real services: Apple's directory, a real RSS feed,
/// real streaming playback, on-device transcription/translation, and the real
/// notch views rendered offscreen. Run through scripts/e2e.sh.
@main
struct E2E {
    static var shots = URL(fileURLWithPath: "e2e-shots")

    @MainActor static func main() {
        NSApplication.shared.setActivationPolicy(.accessory)
        NSApp.appearance = NSAppearance(named: .darkAqua)
        if let dir = ProcessInfo.processInfo.environment["E2E_SHOTS"] { shots = URL(fileURLWithPath: dir) }
        Task { @MainActor in
            do {
                try await run()
                print("All e2e checks passed. Screenshots: \(shots.path)")
                exit(0)
            } catch {
                fputs("FAIL: \(error.localizedDescription)\n", stderr)
                exit(1)
            }
        }
        NSApplication.shared.run()
    }

    @MainActor static func run() async throws {
        try FileManager.default.createDirectory(at: shots, withIntermediateDirectories: true)
        let data = FileManager.default.temporaryDirectory.appendingPathComponent("notchpod-e2e-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: data) }
        let library = Library(file: data.appendingPathComponent("library.json"))
        let av = AVPlayer(); av.isMuted = true
        let player = PodcastPlayer(library: library, avPlayer: av)
        let browser = BrowserModel()
        let notch = NotchController(library: library, player: player, browser: browser)
        defer { notch.shutdown() }
        let captions = notch.captions
        captions.mode = .off

        // 1. Find a show in Apple's directory and load its real feed.
        browser.addRSS("https://feeds.npr.org/510289/podcast.xml")
        try await until("feed loads", 30) { !browser.loading }
        guard let show = browser.selected, let episode = browser.episodes.first else { throw failure("Feed has no episodes") }
        let directory = try await PodcastService().search("Planet Money", country: "US")
        try check(directory.contains { $0.title == "Planet Money" }, "Directory finds Planet Money")
        library.toggle(show)
        try check(library.isFollowing(show), "Follow a show")
        pass("search + feed: \(show.title), \(browser.episodes.count) episodes")

        // 2. Stream it: play, pause, seek, speed, saved progress.
        player.play(episode)
        try await until("playback starts", 45) { player.position >= 2 && player.duration > 0 }
        player.toggle()
        try check(!player.isPlaying, "Pause")
        player.seek(70)
        try await Task.sleep(nanoseconds: 1_000_000_000)
        try check(abs(av.currentTime().seconds - 70) < 2, "Seek to 70s")
        player.rate = 1.5; player.toggle()
        try await Task.sleep(nanoseconds: 500_000_000)
        try check(av.rate == 1.5, "1.5x speed")
        player.toggle(); player.rate = 1; player.persist()
        try check(Library(file: data.appendingPathComponent("library.json")).position(for: episode) >= 70, "Progress saved to disk")
        pass("playback: stream, pause, seek, 1.5x, saved progress")

        // 3. Captions: real on-device transcription through the app's own model.
        player.seek(0)
        captions.mode = .bilingual
        try await until("first captions", 120) { captions.hasTrack || captions.status?.contains("Turn on") == true }
        try check(captions.hasTrack, captions.status ?? "No captions")
        try await until("two chunks transcribed", 120) { (captions.cues.last?.end ?? 0) > CaptionTranscriber.chunkLength * 1.5 }
        let early = captions.cues.filter { $0.end <= CaptionTranscriber.chunkLength * 2 }
        let spoken = early.reduce(0) { $0 + ($1.end - $1.start) }
        try check(spoken > CaptionTranscriber.chunkLength, "Captions cover the first 90s (\(Int(spoken))s of speech)")
        try check(zip(captions.cues, captions.cues.dropFirst()).allSatisfy { $0.end <= $1.start }, "Cues are ordered")
        let long = captions.cues.filter { $0.text.count > 64 }
        try check(long.isEmpty, "Each cue fits one strip line: \(long.map(\.text))")
        player.seek(25)
        try await until("cue follows the playhead", 5) { captions.current.map { $0.start <= 25 && $0.end > 25 } ?? false }
        pass("captions: \(captions.cues.count) cues, \"\(captions.current?.text ?? "")\"")

        // 4. Translation, when this Mac has the language pack.
        if let pair = captions.translation {
            try await until("translations appear", 60) { captions.cues.contains { $0.translation != nil } }
            pass("translation → \(CaptionModel.name(pair.target)): \"\(captions.cues.first { $0.translation != nil }?.translation ?? "")\"")
        } else {
            print("SKIP translation: \(captions.notice ?? "no translation needed")")
        }

        // 5. The real notch views, rendered offscreen.
        player.toggle()
        try await until("playing for the tucked strip", 20) { player.isPlaying && captions.current != nil }
        try check(notch.showsCaptionStrip, "Tucked caption strip shows while playing")
        await render("tucked-captions", width: notch.tuckedWidth + 24, height: notch.tuckedHeight, notch: notch, NotchRootView())
        await render("player-captions", width: 400, height: notch.detailHeight, notch: notch, NotchNowPlayingView())
        player.toggle()
        try await until("strip hides when paused", 5) { !captions.showsTuckedStrip }
        captions.mode = .off
        await render("player", width: 400, height: notch.detailHeight, notch: notch, NotchNowPlayingView())
        await render("show", width: 420, height: 460, notch: notch, NotchBrowseView())
        browser.showRecent(); browser.query = "design"
        do {
            try await until("directory search", 30) { browser.resultsAreCurrent && !browser.searchResults.isEmpty }
        } catch {
            throw failure("Directory search: searching=\(browser.searching) current=\(browser.resultsAreCurrent) results=\(browser.searchResults.count) error=\(browser.error ?? "-") warning=\(browser.searchWarning ?? "-")")
        }
        await render("search", width: 420, height: 460, notch: notch,
                     SearchPanel(height: 460, width: 420, embedded: true, playEpisode: { _ in }, choose: { _ in }, dismiss: {}))
        pass("notch UI rendered: tucked, player, show, search")

        // 6. Optional: video podcast.
        if ProcessInfo.processInfo.environment["E2E_VIDEO"] == "1" {
            let feed = try await PodcastService().feed(URL(string: "https://feeds.twit.tv/twit_video_hd.xml")!)
            guard let video = feed.episodes.first(where: \.isVideo) else { throw failure("No video episode") }
            player.play(video)
            try await until("video plays", 60) { player.position >= 1 }
            try check(player.hasVideo && player.videoVisible, "Video surface shown")
            let before = player.position
            player.toggleVideo()
            try await Task.sleep(nanoseconds: 2_000_000_000)
            try check(!player.videoVisible && player.isPlaying && player.position > before, "Hiding video keeps audio playing")
            player.toggle()
            pass("video: plays, hide keeps audio")
        }
    }

    // MARK: Helpers

    @MainActor static func render<V: View>(_ name: String, width: CGFloat, height: CGFloat, notch: NotchController, _ view: V) async {
        let root = view.environmentObject(notch).environmentObject(notch.library).environmentObject(notch.player)
            .environmentObject(notch.browser).environmentObject(notch.captions)
            .frame(width: width, height: height)
            .background(Color.black.clipShape(NotchSilhouette(shoulder: NotchController.shoulder, bottomRadius: 12)))
            .preferredColorScheme(.dark)
        let hosting = NSHostingView(rootView: root)
        let window = NSWindow(contentRect: NSRect(x: -4000, y: 0, width: width, height: height),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = hosting; window.orderFront(nil)
        try? await Task.sleep(nanoseconds: 2_500_000_000) // artwork and layout settle
        if let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) {
            hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
            try? bitmap.representation(using: .png, properties: [:])?.write(to: shots.appendingPathComponent("\(name).png"))
        }
        // Tear the view down: a hidden but live tree keeps reacting to model
        // changes (e.g. a show page turning into search and cancelling it).
        window.contentView = nil
        window.close()
    }
    @MainActor static func until(_ what: String, _ seconds: Double, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition() {
            if Date() > deadline { throw failure("Timed out: \(what)") }
            try await Task.sleep(nanoseconds: 200_000_000)
        }
    }
    static func check(_ condition: Bool, _ message: String) throws { if !condition { throw failure(message) } }
    static func failure(_ message: String) -> NSError {
        NSError(domain: "E2E", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
    static func pass(_ message: String) { print("PASS \(message)") }
}
