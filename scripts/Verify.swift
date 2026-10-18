import Foundation
import AVFoundation
import AVKit

@main
struct Verify {
    static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw NSError(domain: "QuietCastVerification", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    }

    @MainActor
    static func main() async {
        do {
            let url = URL(string: "https://example.com/feed.xml")!
            let fixture = Data("""
            <rss version="2.0" xmlns:itunes="http://www.itunes.com/dtds/podcast-1.0.dtd"><channel>
            <title>一档节目</title><itunes:author>主播</itunes:author><itunes:image href="https://example.com/cover.jpg"/>
            <item><title>Older &amp; good</title><guid>one</guid><pubDate>Mon, 01 Jun 2026 10:00:00 +0000</pubDate><itunes:duration>01:02:03</itunes:duration><description><![CDATA[<p>Hello &amp; world</p>]]></description><enclosure url="https://example.com/one.mp3" type="audio/mpeg"/></item>
            <item><title>最新一集</title><guid>two</guid><pubDate>Tue, 02 Jun 2026 10:00:00 +0000</pubDate><itunes:duration>120</itunes:duration><enclosure url="https://example.com/two.mp3" type="audio/mpeg"/></item>
            <item><title>Duplicate</title><guid>two</guid><enclosure url="https://example.com/two.mp3" type="audio/mpeg"/></item>
            <item><title>Not audio</title><enclosure url="https://example.com/file.pdf" type="application/pdf"/></item>
            </channel></rss>
            """.utf8)
            let feed = try RSSReader.parse(fixture, url: url)
            try require(feed.podcast.title == "一档节目" && feed.podcast.author == "主播", "Feed metadata")
            try require(feed.podcast.artworkURL?.absoluteString == "https://example.com/cover.jpg", "Artwork")
            try require(feed.episodes.count == 2 && feed.episodes.first?.title == "最新一集", "Ordering, audio filtering, deduplication")
            try require(feed.episodes.last?.summary == "Hello & world" && feed.episodes.last?.duration == 3723, "CDATA and duration")
            print("PASS RSS metadata, CDATA, ordering, filtering, deduplication")

            let other = try RSSReader.parse(fixture, url: URL(string: "https://other.com/feed")!)
            try require(other.episodes.first?.id != feed.episodes.first?.id, "Feed-scoped IDs")
            for text in ["<html>not RSS</html>", "<rss><broken>"] {
                var rejected = false
                do { _ = try RSSReader.parse(Data(text.utf8), url: url) } catch { rejected = true }
                try require(rejected, "Reject invalid XML/feed")
            }
            try require(RSSReader.parseDuration("NaN") == 0 && RSSReader.parseDuration("-2") == 0, "Invalid durations")
            try require(RSSReader.parseDuration("42:03") == 2523, "Minute duration")
            try require(webURL("file:///etc/passwd") == nil && webURL("javascript:alert(1)") == nil, "Reject non-web URLs")
            print("PASS invalid feeds, URL validation, duration formats, feed-scoped IDs")

            let mixed = Data("""
            <rss><channel><title>Mixed media</title>
            <item><title>Video</title><guid>video</guid><enclosure url="https://example.com/one.mp4" type=" Video/MP4; codecs=h264 "/></item>
            <item><title>Audio MP4</title><guid>audio</guid><enclosure url="https://example.com/audio.mp4" type="audio/mp4"/></item>
            <item><title>Missing type</title><guid>missing</guid><enclosure url="https://example.com/clip.M4V?token=one"/></item>
            <item><title>Generic video</title><guid>generic</guid><enclosure url="https://example.com/generic.mov" type="application/octet-stream"/></item>
            <item><title>Both</title><guid>both</guid><enclosure url="https://example.com/sound.mp3" type="audio/mpeg"/><enclosure url="https://example.com/picture.mp4" type="video/mp4"/><enclosure url="https://example.com/sound2.mp3" type="audio/mpeg"/></item>
            <item><title>PDF</title><enclosure url="https://example.com/file.pdf"/></item>
            <item><title>Not a direct video</title><enclosure url="https://youtube.com/watch?v=1" type="text/html"/></item>
            </channel></rss>
            """.utf8)
            let mixedFeed = try RSSReader.parse(mixed, url: url)
            try require(mixedFeed.episodes.count == 5, "Mixed enclosure filtering")
            try require(mixedFeed.episodes.filter(\.isVideo).count == 4, "Video MIME and fallback detection")
            try require(mixedFeed.episodes.first { $0.title == "Audio MP4" }?.mediaKind == .audio, "Audio MIME wins over MP4 extension")
            try require(mixedFeed.episodes.first { $0.title == "Both" }?.mediaURL.lastPathComponent == "picture.mp4", "Prefer combined video enclosure")
            print("PASS mixed audio/video feeds, MIME parameters, extension fallback, video preference, unsupported links")

            let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: folder) }
            let file = folder.appendingPathComponent("library.json")
            let library = Library(file: file)
            library.toggle(feed.podcast)
            let episode = feed.episodes[0]
            library.record(episode, position: 42)
            library.record(episode, position: .nan)
            let restored = Library(file: file)
            try require(restored.isFollowing(feed.podcast) && restored.position(for: episode) == 42, "Persistence")
            try require(restored.recent.count == 1 && restored.snapshot.lastEpisodeID == episode.id, "Recent and last episode")
            restored.toggle(feed.podcast)
            try require(restored.podcasts.isEmpty, "Unfollow")
            print("PASS follow/unfollow, atomic persistence, progress, recent history")

            // Simulate an existing v0.1 record with the old audioURL key and no kind.
            var legacyJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(episode)) as! [String: Any]
            legacyJSON["audioURL"] = legacyJSON.removeValue(forKey: "mediaURL")
            legacyJSON.removeValue(forKey: "mediaKind")
            let migrated = try JSONDecoder().decode(Episode.self, from: JSONSerialization.data(withJSONObject: legacyJSON))
            try require(migrated.mediaURL == episode.mediaURL && !migrated.isVideo && migrated.id == episode.id, "Legacy audio migration")
            let legacyRecord = ListeningRecord(episode: migrated, position: 87, updatedAt: Date())
            var legacySnapshot = try JSONSerialization.jsonObject(with: JSONEncoder().encode(
                LibrarySnapshot(podcasts: [feed.podcast], records: [legacyRecord], lastEpisodeID: migrated.id))) as! [String: Any]
            var legacyRecords = legacySnapshot["records"] as! [[String: Any]]
            legacyRecords[0]["episode"] = legacyJSON
            legacySnapshot["records"] = legacyRecords
            try JSONSerialization.data(withJSONObject: legacySnapshot).write(to: file)
            let migratedLibrary = Library(file: file)
            try require(migratedLibrary.position(for: migrated) == 87, "Legacy progress intact")
            let video = mixedFeed.episodes.first { $0.isVideo }!
            migratedLibrary.record(video, position: 12)
            let videoLibrary = Library(file: file)
            try require(videoLibrary.recent.first?.episode.isVideo == true && videoLibrary.position(for: video) == 12, "Video metadata persists")
            let restoredVideo = PodcastPlayer(library: videoLibrary)
            try require(restoredVideo.hasVideo && !restoredVideo.videoVisible && !restoredVideo.isPlaying && restoredVideo.videoPlayer.currentItem == nil, "Video restore without loading/autoplay")
            restoredVideo.toggleVideo()
            try require(restoredVideo.videoVisible && restoredVideo.videoPlayer.currentItem == nil, "Showing restored video doesn't autoplay")
            print("PASS legacy audio migration, preserved progress, video persistence, paused video restore")

            let cues = [CaptionCue(id: 0, start: 1, end: 4, text: "One."), CaptionCue(id: 1, start: 5, end: 9, text: "Two."),
                        CaptionCue(id: 2, start: 9, end: 12, text: "Three.")]
            try require(CaptionModel.cue(at: 0.5, in: cues) == nil && CaptionModel.cue(at: 4.5, in: cues) == nil, "Caption gaps")
            try require(CaptionModel.cue(at: 1, in: cues)?.id == 0 && CaptionModel.cue(at: 9, in: cues)?.id == 2, "Caption boundaries")
            try require(CaptionModel.cue(at: 11.9, in: [CaptionCue]())?.id == nil, "Empty caption track")
            try require(CaptionModel.rewindTarget(from: 8, in: cues) == 5, "Rewind to current sentence start")
            try require(CaptionModel.rewindTarget(from: 5.5, in: cues) == 1, "Rewind near start goes to previous sentence")
            try require(CaptionModel.rewindTarget(from: 0.2, in: cues) == nil, "Rewind before first sentence never moves forward")
            let messy = CaptionModel.normalized([CaptionCue(id: 0, start: 6, end: 8, text: "Later."), CaptionCue(id: 1, start: 1, end: 7, text: "Overlaps."),
                                                 CaptionCue(id: 2, start: 3, end: 3, text: "Empty."), CaptionCue(id: 3, start: .nan, end: 2, text: "Bad.")])
            try require(messy.map(\.id) == [1, 0] && messy[0].end == 6 && CaptionModel.cue(at: 6.5, in: messy)?.id == 0, "Caption normalization")
            let demo = CaptionDemo.cues(duration: 300)
            try require(!demo.isEmpty && zip(demo, demo.dropFirst()).allSatisfy { $0.end <= $1.start && $0.id + 1 == $1.id }, "Demo cues ordered")
            var words: [(text: String, start: Double, end: Double)] = [("Hello", 0, 0.4), ("there.", 0.5, 0.9), ("After", 2.5, 2.8),
                                                                     ("a", 2.9, 3.0), ("pause", 3.1, 3.5)]
            for index in 0..<14 {
                let start = 3.6 + Double(index) * 0.2
                words.append((text: "w\(index)", start: start, end: start + 0.15))
            }
            let split = CaptionTranscriber.sentences(words, offset: 45, firstID: 1000, spaced: true)
            try require(split.first?.text == "Hello there." && split.first?.start == 45 && split[1].text.hasPrefix("After a pause"), "Sentence split on punctuation and pause")
            try require(split.allSatisfy { $0.text.split(separator: " ").count <= 10 } && split.map(\.id) == Array(1000..<1000 + split.count), "Cues fit one line, stable ids")
            try require(CaptionTranscriber.sentences([("你好", 0, 0.5), ("世界。", 0.5, 1)], offset: 0, firstID: 0, spaced: false).first?.text == "你好世界。", "CJK joins without spaces")
            print("PASS caption lookup, sentence gaps, normalization, sentence-aware rewind, sentence splitting")

            if ProcessInfo.processInfo.environment["QUIETCAST_LIVE_TESTS"] == "1" {
                let service = PodcastService()
                let results = try await service.search("Planet Money", country: "US")
                guard let podcast = results.first(where: { $0.title == "Planet Money" }) else { throw PodcastError.invalidFeed }
                let live = try await service.feed(podcast.feedURL, existing: podcast)
                try require(!live.episodes.isEmpty, "Real feed episodes")
                print("PASS live directory + RSS: \(podcast.title), \(live.episodes.count) episodes")
                let avPlayer = AVPlayer()
                avPlayer.isMuted = true
                library.record(live.episodes[0], position: 42)
                let player = PodcastPlayer(library: library, avPlayer: avPlayer)
                try require(player.position == 42 && !player.isPlaying && avPlayer.currentItem == nil, "Restore without autoplay")
                player.play(live.episodes[0])
                let deadline = Date().addingTimeInterval(45)
                while Date() < deadline && player.position < 43 {
                    if let error = player.error { throw NSError(domain: "Playback", code: 1, userInfo: [NSLocalizedDescriptionKey: error]) }
                    try await Task.sleep(nanoseconds: 250_000_000)
                }
                try require(player.position >= 43 && avPlayer.currentTime().seconds >= 43, "Real playback + resume seek timed out")
                player.toggle()
                try require(!player.isPlaying, "Pause")
                player.seek(70)
                try await Task.sleep(nanoseconds: 1_000_000_000)
                try require(abs(avPlayer.currentTime().seconds - 70) < 2, "Seek")
                player.rate = 1.5
                player.toggle()
                try await Task.sleep(nanoseconds: 500_000_000)
                try require(avPlayer.rate == 1.5, "Playback speed")
                player.toggle()
                player.persist()
                let saved = Library(file: file)
                try require(saved.position(for: live.episodes[0]) >= 70, "Save real progress")
                print("PASS real player: muted streaming, restore at 42s, pause, seek, 1.5×, saved progress")

                if ProcessInfo.processInfo.environment["QUIETCAST_VIDEO_TESTS"] == "1" {
                    let videoFeed = try await service.feed(URL(string: "https://feeds.twit.tv/twit_video_hd.xml")!)
                    guard let video = videoFeed.episodes.first(where: \.isVideo) else { throw PodcastError.noMedia }
                    try require(video.date != nil, "Named RFC822 timezone dates")
                    player.rate = 1
                    player.play(video)
                    try require(player.hasVideo && player.videoVisible, "Video opens when played")
                    guard let item = avPlayer.currentItem else { throw PodcastError.noMedia }
                    let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
                    item.add(output)
                    let surface = QuietVideoView()
                    surface.controlsStyle = .none
                    surface.player = player.videoPlayer
                    var decoded = false
                    let deadline = Date().addingTimeInterval(60)
                    while Date() < deadline && (!decoded || player.position < 1) {
                        if let error = player.error { throw NSError(domain: "VideoPlayback", code: 1, userInfo: [NSLocalizedDescriptionKey: error]) }
                        if let frame = output.copyPixelBuffer(forItemTime: item.currentTime(), itemTimeForDisplay: nil) {
                            decoded = CVPixelBufferGetWidth(frame) > 0 && CVPixelBufferGetHeight(frame) > 0
                        }
                        try await Task.sleep(nanoseconds: 250_000_000)
                    }
                    try require(decoded && player.position >= 1, "Video frames decode and clock advances")
                    let audioTracks = try await item.asset.loadTracks(withMediaType: .audio)
                    try require(!audioTracks.isEmpty, "Video contains an audio track")
                    let before = player.position
                    player.toggleVideo()
                    NativeVideoSurface.dismantleNSView(surface, coordinator: ())
                    try await Task.sleep(nanoseconds: 2_000_000_000)
                    try require(!player.videoVisible && player.isPlaying && player.position > before && avPlayer.currentItem === item, "Hide/detach video keeps same stream playing")
                    player.toggleVideo()
                    surface.player = player.videoPlayer
                    try require(player.videoVisible && surface.player === avPlayer && avPlayer.currentItem === item, "Show video preserves stream")
                    player.toggle()
                    let frozen = player.position
                    player.toggleVideo()
                    try await Task.sleep(nanoseconds: 1_000_000_000)
                    try require(!player.isPlaying && abs(player.position - frozen) < 1.5, "Hide paused video does not start playback")
                    player.play(live.episodes[0])
                    try require(!player.hasVideo && !player.videoVisible, "Audio clears the video surface")
                    player.toggle()
                    print("PASS live video: decoded frames + audio track, hide/show without restart, pause preserved, audio switch")
                }
            }
            print("All checks passed.")
        } catch {
            fputs("FAIL: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }
}
