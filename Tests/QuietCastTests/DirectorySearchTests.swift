import XCTest
@testable import QuietCast

final class DirectorySearchTests: XCTestCase {
    private let feedURL = URL(string: "https://example.com/feed.xml")!
    private var item: [String: Any] {
        ["wrapperType": "podcastEpisode", "kind": "podcast-episode",
         "collectionId": 123, "trackId": 456, "trackName": "搜索这一集",
         "collectionName": "A show", "artistName": "A host",
         "feedUrl": feedURL.absoluteString, "episodeUrl": "https://example.com/full.mp4",
         "episodeGuid": "  publisher-guid  ", "episodeContentType": "audio",
         "trackTimeMillis": 90000, "releaseDate": "2026-06-01T10:00:00.123Z",
         "artworkUrl600": "https://example.com/episode.jpg"]
    }
    private func decode(_ items: [[String: Any]]) throws -> [EpisodeSearchHit] {
        try PodcastService.decodeEpisodeSearch(JSONSerialization.data(withJSONObject: ["results": items]))
    }
    func testEpisodeMetadataDeduplicationAndCanonicalIdentity() throws {
        let show: [String: Any] = ["kind": "podcast", "collectionName": "Show", "feedUrl": feedURL.absoluteString]
        let hits = try decode([item, item, show])
        let hit = try XCTUnwrap(hits.first)
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hit.title, "搜索这一集")
        XCTAssertEqual(hit.duration, 90)
        XCTAssertEqual(hit.mediaKind, .audio) // Explicit content type beats .mp4 extension.
        XCTAssertNotNil(hit.date)
        let podcast = try XCTUnwrap(hit.podcast)
        let episode = try XCTUnwrap(hit.publisherEpisode(in: podcast))
        XCTAssertEqual(episode.id, feedURL.absoluteString + "#publisher-guid")
        XCTAssertEqual(episode.artworkURL?.absoluteString, "https://example.com/episode.jpg")
    }
    func testNumericAndStringDirectoryIDsDeduplicate() throws {
        var stringIDs = item
        stringIDs["collectionId"] = "123"; stringIDs["trackId"] = "456"
        XCTAssertEqual(try decode([item, stringIDs]).count, 1)
    }
    func testPreviewAndStorePageURLsAreNeverUsedAsMedia() throws {
        var metadata = item
        metadata.removeValue(forKey: "episodeUrl")
        metadata["previewUrl"] = "https://example.com/preview.mp3"
        metadata["trackViewUrl"] = "https://podcasts.apple.com/us/podcast/example/id123?i=456"
        let hit = try XCTUnwrap(decode([metadata]).first)
        XCTAssertNil(hit.mediaURL)
        XCTAssertNil(hit.publisherEpisode(in: try XCTUnwrap(hit.podcast)))
    }
    func testMissingFeedCanBeResolvedByCollectionID() throws {
        var metadata = item
        metadata.removeValue(forKey: "feedUrl")
        let hit = try XCTUnwrap(decode([metadata]).first)
        XCTAssertNil(hit.podcast)
        XCTAssertEqual(hit.collectionID, "123")
        metadata.removeValue(forKey: "collectionId")
        XCTAssertTrue(try decode([metadata]).isEmpty)
    }
    func testNonWebURLsAreRejected() throws {
        var metadata = item
        metadata["episodeUrl"] = "file:///tmp/audio.mp3"
        metadata["feedUrl"] = "javascript:alert(1)"
        let hit = try XCTUnwrap(decode([metadata]).first)
        XCTAssertNil(hit.mediaURL)
        XCTAssertNil(hit.feedURL)
    }
    func testDirectoryGUIDMatchesExistingRSSEpisode() throws {
        let hit = try XCTUnwrap(decode([item]).first)
        let xml = Data("""
        <rss><channel><title>A show</title><item><title>搜索这一集</title>
        <guid>publisher-guid</guid><enclosure url="https://example.com/refreshed.mp3" type="audio/mpeg"/>
        </item></channel></rss>
        """.utf8)
        let feed = try RSSReader.parse(xml, url: feedURL)
        XCTAssertEqual(hit.matchingEpisode(in: feed)?.mediaURL.absoluteString, "https://example.com/refreshed.mp3")
        XCTAssertEqual(hit.publisherEpisode(in: try XCTUnwrap(hit.podcast))?.id, feed.episodes.first?.id)
    }
    func testAmbiguousTitlesAreNotPlayed() throws {
        var metadata = item
        metadata.removeValue(forKey: "episodeGuid"); metadata.removeValue(forKey: "episodeUrl")
        let hit = try XCTUnwrap(decode([metadata]).first)
        let podcast = try XCTUnwrap(hit.podcast)
        let date = try XCTUnwrap(hit.date)
        let episodes = ["one", "two"].map {
            Episode(id: podcast.id + "#" + $0, title: hit.title, summary: "",
                    mediaURL: URL(string: "https://example.com/\($0).mp3")!, date: date, duration: 90, podcast: podcast)
        }
        XCTAssertNil(hit.matchingEpisode(in: FeedResult(podcast: podcast, episodes: episodes)))
        XCTAssertEqual(hit.matchingEpisode(in: FeedResult(podcast: podcast, episodes: [episodes[0]]))?.id, episodes[0].id)
    }
}
