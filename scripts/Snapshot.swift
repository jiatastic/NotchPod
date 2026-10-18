import SwiftUI
import AppKit
import AVFoundation

// Captures our own view, not the screen. No Accessibility / Screen Recording needed.
@main
struct Snapshot {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let library = Library(file: folder.appendingPathComponent("library.json"))
        let browser = BrowserModel()
        let avPlayer = AVPlayer()
        avPlayer.isMuted = true
        let player = PodcastPlayer(library: library, avPlayer: avPlayer)
        let view = ContentView().environmentObject(library).environmentObject(browser).environmentObject(player)
            .environment(\.locale, Locale(identifier: "en_US"))
        let hosting = NSHostingView(rootView: view)
        let small = CommandLine.arguments.contains("--small")
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: small ? 720 : 940, height: small ? 480 : 600),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.contentView = hosting
        window.orderFront(nil)
        Task { @MainActor in
            do {
                if CommandLine.arguments.contains("--video") {
                    browser.addRSS("https://feeds.twit.tv/twit_video_hd.xml")
                    while browser.loading { try await Task.sleep(nanoseconds: 100_000_000) }
                    guard let podcast = browser.selected, let episode = browser.episodes.first(where: \.isVideo) else {
                        throw PodcastError.noMedia
                    }
                    library.toggle(podcast)
                    player.play(episode)
                    let deadline = Date().addingTimeInterval(60)
                    while player.position < 1 && Date() < deadline {
                        if player.error != nil { throw PodcastError.badResponse }
                        try await Task.sleep(nanoseconds: 250_000_000)
                    }
                    guard player.position >= 1 else { throw PodcastError.badResponse }
                    player.toggle()
                    if CommandLine.arguments.contains("--hidden") { player.toggleVideo() }
                } else if CommandLine.arguments.contains("--live") {
                    let result = try await PodcastService().search("Planet Money", country: "US")
                    if let podcast = result.first(where: { $0.title == "Planet Money" }) {
                        library.toggle(podcast)
                        browser.open(podcast)
                        while browser.loading { try await Task.sleep(nanoseconds: 100_000_000) }
                    }
                }
                try await Task.sleep(nanoseconds: 1_000_000_000)
                hosting.layoutSubtreeIfNeeded()
                if CommandLine.arguments.contains("--video"), !CommandLine.arguments.contains("--hidden") {
                    @MainActor func findSurface(_ view: NSView) -> QuietVideoView? {
                        if let surface = view as? QuietVideoView { return surface }
                        for subview in view.subviews {
                            if let surface = findSurface(subview) { return surface }
                        }
                        return nil
                    }
                    guard let surface = findSurface(hosting) else { throw PodcastError.noMedia }
                    let deadline = Date().addingTimeInterval(10)
                    while !surface.isReadyForDisplay && Date() < deadline {
                        try await Task.sleep(nanoseconds: 100_000_000)
                    }
                    guard surface.isReadyForDisplay else { throw PodcastError.badResponse }
                    print("PASS native AVPlayerView is ready for display")
                }
                guard let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { fatalError("No bitmap") }
                hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
                let path = CommandLine.arguments.first(where: { $0.hasSuffix(".png") }) ?? ".build/window.png"
                try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
                try? FileManager.default.removeItem(at: folder)
                print("Saved \(path)")
                exit(0)
            } catch {
                fputs("Snapshot failed: \(error)\n", stderr)
                exit(1)
            }
        }
        app.run()
    }
}
