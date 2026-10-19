import Foundation

struct FeedResult: Sendable {
    let podcast: Podcast
    let episodes: [Episode]
}

struct PodcastService: Sendable {
    func search(_ term: String, country: String) async throws -> [Podcast] {
        var components = URLComponents(string: "https://itunes.apple.com/search")!
        components.queryItems = [
            .init(name: "term", value: term), .init(name: "media", value: "podcast"),
            .init(name: "entity", value: "podcast"), .init(name: "limit", value: "40"),
            .init(name: "country", value: country)
        ]
        let data = try await fetch(components.url!)
        return try Self.decodeShowSearch(data)
    }

    func searchEpisodes(_ term: String, country: String) async throws -> [EpisodeSearchHit] {
        var components = URLComponents(string: "https://itunes.apple.com/search")!
        components.queryItems = [
            .init(name: "term", value: term), .init(name: "media", value: "podcast"),
            .init(name: "entity", value: "podcastEpisode"), .init(name: "limit", value: "40"),
            .init(name: "country", value: country)
        ]
        return try Self.decodeEpisodeSearch(await fetch(components.url!))
    }

    func searchDirectory(_ term: String, country: String) async throws -> DirectorySearchResults {
        // A failure in one category must not discard the other category's results.
        async let shows = outcome { try await search(term, country: country) }
        async let episodes = outcome { try await searchEpisodes(term, country: country) }
        let pair = await (shows, episodes)
        try Task.checkCancellation()
        switch pair {
        case (.success(let shows), .success(let episodes)):
            return DirectorySearchResults(shows: shows, episodes: episodes, warning: nil)
        case (.success(let shows), .failure):
            return DirectorySearchResults(shows: shows, episodes: [], warning: "Episode search unavailable. Showing shows only.")
        case (.failure, .success(let episodes)):
            return DirectorySearchResults(shows: [], episodes: episodes, warning: "Show search unavailable. Showing episodes only.")
        case (.failure(let error), .failure): throw error
        }
    }

    func lookupPodcast(_ collectionID: String, country: String) async throws -> Podcast {
        var components = URLComponents(string: "https://itunes.apple.com/lookup")!
        components.queryItems = [.init(name: "id", value: collectionID), .init(name: "country", value: country)]
        let data = try await fetch(components.url!)
        guard let podcast = try Self.decodeShowSearch(data).first else { throw PodcastError.episodeUnavailable }
        return podcast
    }

    static func decodeShowSearch(_ data: Data) throws -> [Podcast] {
        let response = try JSONDecoder().decode(DirectoryResponse.self, from: data)
        var seen = Set<String>()
        return response.results.compactMap { item in
            guard item.kind == nil || item.kind == "podcast",
                  let feed = item.feedUrl.flatMap(webURL), seen.insert(feed.absoluteString).inserted else { return nil }
            return Podcast(title: item.collectionName ?? "Untitled show", author: item.artistName ?? "",
                           feedURL: feed, artworkURL: item.artworkURL)
        }
    }

    static func decodeEpisodeSearch(_ data: Data) throws -> [EpisodeSearchHit] {
        let response = try JSONDecoder().decode(DirectoryResponse.self, from: data)
        let formatter = ISO8601DateFormatter()
        var seen = Set<String>()
        return response.results.compactMap { item in
            guard item.kind == "podcast-episode" || item.wrapperType == "podcastEpisode",
                  let title = item.trackName?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty else { return nil }
            let feed = item.feedUrl.flatMap(webURL)
            let media = item.episodeUrl.flatMap(webURL)
            let guid = item.episodeGuid?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            guard let scope = item.collectionId?.value ?? feed?.absoluteString,
                  let identity = item.trackId?.value ?? guid ?? media?.absoluteString else { return nil }
            let id = scope + "#" + identity
            guard seen.insert(id).inserted else { return nil }
            var date: Date?
            if let value = item.releaseDate {
                formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                date = formatter.date(from: value)
                if date == nil {
                    formatter.formatOptions = [.withInternetDateTime]
                    date = formatter.date(from: value)
                }
            }
            let milliseconds = item.trackTimeMillis ?? 0
            let type = item.episodeContentType?.lowercased()
            let kind: MediaKind = type == "video" ? .video : type == "audio" ? .audio
                : media.flatMap { MediaKind.classify(url: $0, mimeType: nil) } ?? .audio
            return EpisodeSearchHit(id: id, title: plainText(title), showTitle: item.collectionName ?? "Untitled show",
                author: item.artistName ?? "", collectionID: item.collectionId?.value, feedURL: feed,
                mediaURL: media, guid: guid, artworkURL: item.artworkURL, date: date,
                duration: milliseconds.isFinite && milliseconds > 0 ? min(milliseconds / 1000, 31_536_000) : 0, mediaKind: kind)
        }
    }

    private func outcome<Value: Sendable>(_ operation: @Sendable () async throws -> Value) async -> Result<Value, Error> {
        do { return .success(try await operation()) }
        catch { return .failure(error) }
    }

    func feed(_ url: URL, existing: Podcast? = nil) async throws -> FeedResult {
        let data = try await fetch(url)
        return try await Task.detached(priority: .userInitiated) {
            try RSSReader.parse(data, url: url, existing: existing)
        }.value
    }

    private func fetch(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.setValue("NotchPod/0.9.1 (macOS; podcast reader)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw PodcastError.badResponse
        }
        guard data.count <= 20_000_000 else { throw PodcastError.invalidFeed }
        return data
    }
}

private struct DirectoryResponse: Decodable {
    let results: [DirectoryItem]
}

private struct DirectoryItem: Decodable {
    let kind: String?
    let wrapperType: String?
    let collectionId: DirectoryID?
    let trackId: DirectoryID?
    let collectionName: String?
    let trackName: String?
    let artistName: String?
    let feedUrl: String?
    let episodeUrl: String?
    let episodeGuid: String?
    let episodeContentType: String?
    let artworkUrl600: String?
    let artworkUrl160: String?
    let artworkUrl100: String?
    let releaseDate: String?
    let trackTimeMillis: Double?

    var artworkURL: URL? {
        [artworkUrl600, artworkUrl160, artworkUrl100].compactMap { $0.flatMap(webURL) }.first
    }
}

// Some storefront responses encode directory IDs as strings instead of numbers.
private struct DirectoryID: Decodable {
    let value: String
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let string = try? container.decode(String.self) { value = string }
        else { value = String(try container.decode(Int64.self)) }
    }
}

final class RSSReader: NSObject, XMLParserDelegate {
    private struct Item {
        var fields: [String: String] = [:]
        var media: (url: URL, kind: MediaKind)?
        var artwork: URL?
    }
    private var path: [String] = []
    private var fields: [String: String] = [:]
    private var items: [Item] = []
    private var item: Item?
    private var artwork: URL?

    static func parse(_ data: Data, url: URL, existing: Podcast? = nil) throws -> FeedResult {
        let reader = RSSReader()
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.delegate = reader
        guard parser.parse(), !reader.items.isEmpty else { throw PodcastError.invalidFeed }
        let title = reader.fields["title"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        let podcast = Podcast(title: existing?.title ?? title ?? "Untitled show",
            author: existing?.author ?? plainText(reader.fields["itunes:author"] ?? reader.fields["managingEditor"] ?? ""),
            feedURL: url, artworkURL: existing?.artworkURL ?? reader.artwork)
        var seen = Set<String>()
        let episodes = reader.items.compactMap { item -> Episode? in
            guard let media = item.media else { return nil }
            // Feed-scoped IDs prevent GUID collisions across publishers.
            let key = url.absoluteString + "#" + (item.fields["guid"]?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? media.url.absoluteString)
            guard seen.insert(key).inserted else { return nil }
            return Episode(id: key, title: plainText(item.fields["title"] ?? "Untitled episode"),
                summary: plainText(item.fields["content:encoded"] ?? item.fields["description"] ?? item.fields["itunes:summary"] ?? ""),
                mediaURL: media.url, date: parseDate(item.fields["pubDate"] ?? ""),
                duration: parseDuration(item.fields["itunes:duration"] ?? ""), podcast: podcast,
                mediaKind: media.kind, artworkURL: item.artwork)
        }.sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
        guard !episodes.isEmpty else { throw PodcastError.noMedia }
        return FeedResult(podcast: podcast, episodes: episodes)
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
        path.append(elementName)
        if elementName == "item" { item = Item() }
        if elementName == "enclosure", item != nil, let address = attributes["url"],
           let url = webURL(address), let kind = MediaKind.classify(url: url, mimeType: attributes["type"]) {
            // Prefer a video's combined picture + audio when both formats are offered.
            if item?.media == nil || (kind == .video && item?.media?.kind != .video) {
                item?.media = (url, kind)
            }
        }
        if elementName == "itunes:image", let url = attributes["href"].flatMap(webURL) {
            if item != nil { item?.artwork = url }
            else { artwork = url }
        }
        if elementName == "media:thumbnail", item != nil, item?.artwork == nil {
            item?.artwork = attributes["url"].flatMap(webURL)
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { append(string) }
    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        if let string = String(data: CDATABlock, encoding: .utf8) { append(string) }
    }
    private func append(_ string: String) {
        guard let key = path.last else { return }
        if item != nil { item?.fields[key, default: ""] += string }
        else if path.dropLast().last == "channel" { fields[key, default: ""] += string }
        else if key == "url", path.dropLast().last == "image", let url = webURL(string) { artwork = artwork ?? url }
    }
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName: String?) {
        if elementName == "item", let item { items.append(item); self.item = nil }
        _ = path.popLast()
    }

    static func parseDuration(_ string: String) -> Double {
        let parts = string.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ":")
        guard !parts.isEmpty, parts.count <= 3 else { return 0 }
        var total = 0.0
        for part in parts {
            guard let number = Double(part), number.isFinite, number >= 0 else { return 0 }
            total = total * 60 + number
        }
        return total
    }
    private static func parseDate(_ string: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        for format in ["EEE, dd MMM yyyy HH:mm:ss Z", "EEE, d MMM yyyy HH:mm:ss Z",
                       "EEE, dd MMM yyyy HH:mm:ss z", "EEE, d MMM yyyy HH:mm:ss z", "yyyy-MM-dd'T'HH:mm:ssZ"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: string.trimmingCharacters(in: .whitespacesAndNewlines)) { return date }
        }
        return nil
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
