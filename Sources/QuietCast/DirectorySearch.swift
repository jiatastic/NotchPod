import Foundation

/// Directory metadata is not a playable Episode until its publisher feed is known.
/// In particular, Apple page URLs and preview URLs are never media sources.
struct EpisodeSearchHit: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let showTitle: String
    let author: String
    let collectionID: String?
    let feedURL: URL?
    let mediaURL: URL?
    let guid: String?
    let artworkURL: URL?
    let date: Date?
    let duration: Double
    let mediaKind: MediaKind

    var podcast: Podcast? {
        guard let feedURL else { return nil }
        return Podcast(title: showTitle, author: author, feedURL: feedURL, artworkURL: artworkURL)
    }
    func publisherEpisode(in podcast: Podcast) -> Episode? {
        guard let mediaURL else { return nil }
        // Use exactly the same feed-scoped identity as RSSReader, not Apple's ID.
        return Episode(id: podcast.id + "#" + (guid ?? mediaURL.absoluteString), title: title,
                       summary: "", mediaURL: mediaURL, date: date, duration: duration,
                       podcast: podcast, mediaKind: mediaKind, artworkURL: artworkURL)
    }
    func matchingEpisode(in feed: FeedResult) -> Episode? {
        if let guid, let episode = feed.episodes.first(where: { $0.id == feed.podcast.id + "#" + guid }) {
            return episode
        }
        if let mediaURL, let episode = feed.episodes.first(where: { $0.mediaURL == mediaURL }) {
            return episode
        }
        // A title alone is unsafe (e.g. many episodes called "Daily briefing").
        guard guid == nil, mediaURL == nil, let date else { return nil }
        let matches = feed.episodes.filter {
            $0.title.compare(title, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
                && abs(($0.date ?? .distantPast).timeIntervalSince(date)) < 60
        }
        return matches.count == 1 ? matches.first : nil
    }
}

struct DirectorySearchResults: Sendable {
    let shows: [Podcast]
    let episodes: [EpisodeSearchHit]
    let warning: String?
}

enum PodcastSearchResult: Identifiable {
    case episode(EpisodeSearchHit)
    case show(Podcast)

    var id: String {
        switch self {
        case .episode(let hit): return "episode:" + hit.id
        case .show(let show): return "show:" + show.id
        }
    }
}
