import XCTest
@testable import QuietCast

final class PodcastTests: XCTestCase {
    private let url = URL(string: "https://example.com/feed.xml")!
    private var fixture: Data {
        Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <rss version="2.0" xmlns:itunes="http://www.itunes.com/dtds/podcast-1.0.dtd" xmlns:content="http://purl.org/rss/1.0/modules/content/">
        <channel><title>一档节目</title><itunes:author>主播</itunes:author><itunes:image href="https://example.com/cover.jpg"/>
        <item><title>Older &amp; good</title><guid>one</guid><pubDate>Mon, 01 Jun 2026 10:00:00 +0000</pubDate><itunes:duration>01:02:03</itunes:duration><description><![CDATA[<p>Hello &amp; world</p>]]></description><enclosure url="https://example.com/one.mp3" type="audio/mpeg"/></item>
        <item><title>最新一集</title><guid>two</guid><pubDate>Tue, 02 Jun 2026 10:00:00 +0000</pubDate><itunes:duration>120</itunes:duration><enclosure url="https://example.com/two.mp3" type="audio/mpeg"/></item>
        <item><title>Duplicate</title><guid>two</guid><enclosure url="https://example.com/two.mp3" type="audio/mpeg"/></item>
        <item><title>Not audio</title><enclosure url="https://example.com/file.pdf" type="application/pdf"/></item>
        </channel></rss>
        """.utf8)
    }

    func testRSSMetadataCDATAOrderingAndDeduplication() throws {
        let result = try RSSReader.parse(fixture, url: url)
        XCTAssertEqual(result.podcast.title, "一档节目")
        XCTAssertEqual(result.podcast.author, "主播")
        XCTAssertEqual(result.podcast.artworkURL?.absoluteString, "https://example.com/cover.jpg")
        XCTAssertEqual(result.episodes.count, 2)
        XCTAssertEqual(result.episodes.first?.title, "最新一集")
        XCTAssertEqual(result.episodes.last?.duration, 3723)
        XCTAssertEqual(result.episodes.last?.summary, "Hello & world")
    }
    func testVideoEnclosuresAndMIMEPrecedence() throws {
        let data = Data("""
        <rss><channel><title>Video feed</title>
        <item><title>Video</title><enclosure url="https://example.com/watch.mp4" type="VIDEO/MP4; codecs=h264"/></item>
        <item><title>Audio</title><enclosure url="https://example.com/audio.mp4" type="audio/mp4"/></item>
        <item><title>Missing MIME</title><enclosure url="https://example.com/watch.M4V"/></item>
        <item><title>PDF</title><enclosure url="https://example.com/file.pdf"/></item>
        </channel></rss>
        """.utf8)
        let feed = try RSSReader.parse(data, url: url)
        XCTAssertEqual(feed.episodes.count, 3)
        XCTAssertEqual(feed.episodes.filter(\.isVideo).count, 2)
        XCTAssertEqual(feed.episodes.first { $0.title == "Audio" }?.mediaKind, .audio)
    }
    func testLegacyAudioRecordsDecode() throws {
        let episode = try XCTUnwrap(RSSReader.parse(fixture, url: url).episodes.first)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(episode)) as? [String: Any])
        json["audioURL"] = json.removeValue(forKey: "mediaURL")
        json.removeValue(forKey: "mediaKind")
        let decoded = try JSONDecoder().decode(Episode.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(decoded.mediaURL, episode.mediaURL)
        XCTAssertEqual(decoded.mediaKind, .audio)
        XCTAssertEqual(decoded.id, episode.id)
    }
    func testMalformedFeedIsRejected() {
        XCTAssertThrowsError(try RSSReader.parse(Data("<html>not RSS</html>".utf8), url: url))
        XCTAssertThrowsError(try RSSReader.parse(Data("<rss><broken>".utf8), url: url))
    }
    func testIDsAreFeedScoped() throws {
        let one = try RSSReader.parse(fixture, url: url)
        let two = try RSSReader.parse(fixture, url: URL(string: "https://other.com/feed.xml")!)
        XCTAssertNotEqual(one.episodes.first?.id, two.episodes.first?.id)
    }
    func testDurationsAndURLValidation() {
        XCTAssertEqual(RSSReader.parseDuration("42:03"), 2523)
        XCTAssertEqual(RSSReader.parseDuration(" -2 "), 0)
        XCTAssertEqual(RSSReader.parseDuration("NaN"), 0)
        XCTAssertEqual(RSSReader.parseDuration("1:2:3:4"), 0)
        XCTAssertNil(webURL("file:///etc/passwd"))
        XCTAssertNil(webURL("javascript:alert(1)"))
        XCTAssertNotNil(webURL(" https://example.com/rss "))
        XCTAssertEqual(clock(3723), "1:02:03")
    }
    @MainActor
    func testLibraryPersistsFollowsAndProgress() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("library.json")
        let result = try RSSReader.parse(fixture, url: url)
        let episode = try XCTUnwrap(result.episodes.first)
        let library = Library(file: file)
        library.toggle(result.podcast)
        library.record(episode, position: 42)
        library.record(episode, position: .nan)
        let restored = Library(file: file)
        XCTAssertTrue(restored.isFollowing(result.podcast))
        XCTAssertEqual(restored.position(for: episode), 42)
        XCTAssertEqual(restored.recent.count, 1)
        XCTAssertEqual(restored.snapshot.lastEpisodeID, episode.id)
        restored.toggle(result.podcast)
        XCTAssertTrue(restored.podcasts.isEmpty)
    }

    func testLiveSearchAndFeed() async throws {
        guard ProcessInfo.processInfo.environment["QUIETCAST_LIVE_TESTS"] == "1" else {
            throw XCTSkip("Set QUIETCAST_LIVE_TESTS=1 for real directory/RSS integration.")
        }
        let service = PodcastService()
        let results = try await service.search("Planet Money", country: "US")
        let podcast = try XCTUnwrap(results.first { $0.title == "Planet Money" })
        let feed = try await service.feed(podcast.feedURL, existing: podcast)
        XCTAssertFalse(feed.episodes.isEmpty)
        let episode = try XCTUnwrap(feed.episodes.first)
        var request = URLRequest(url: episode.mediaURL)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 30
        let (_, response) = try await URLSession.shared.data(for: request)
        let http = try XCTUnwrap(response as? HTTPURLResponse)
        XCTAssertTrue((200..<400).contains(http.statusCode))
        print("LIVE PASS: \(podcast.title) — \(episode.title); \(feed.episodes.count) episodes; audio HTTP \(http.statusCode)")
    }
}
