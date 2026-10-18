import Foundation

struct Podcast: Identifiable, Codable, Equatable, Sendable {
    var id: String { feedURL.absoluteString }
    let title: String
    let author: String
    let feedURL: URL
    let artworkURL: URL?
}

enum MediaKind: String, Codable, Sendable {
    case audio, video

    static func classify(url: URL, mimeType: String?) -> MediaKind? {
        let type = mimeType?.split(separator: ";", maxSplits: 1).first?
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        if type.hasPrefix("video/") { return .video }
        if type.hasPrefix("audio/") { return .audio }
        // Publishers sometimes omit the MIME type or use a generic download type.
        guard type.isEmpty || type == "application/octet-stream" else { return nil }
        switch url.pathExtension.lowercased() {
        case "mp4", "m4v", "mov": return .video
        case "mp3", "m4a", "aac", "wav", "aiff", "flac", "ogg", "opus": return .audio
        default: return nil
        }
    }
}

struct Episode: Identifiable, Codable, Equatable, Sendable {
    let id: String
    let title: String
    let summary: String
    let mediaURL: URL
    let date: Date?
    let duration: Double
    let podcast: Podcast
    let mediaKind: MediaKind
    let artworkURL: URL?
    var isVideo: Bool { mediaKind == .video }
    var displayArtworkURL: URL? { artworkURL ?? podcast.artworkURL }

    init(id: String, title: String, summary: String, mediaURL: URL, date: Date?, duration: Double,
         podcast: Podcast, mediaKind: MediaKind = .audio, artworkURL: URL? = nil) {
        self.id = id; self.title = title; self.summary = summary; self.mediaURL = mediaURL
        self.date = date; self.duration = duration; self.podcast = podcast; self.mediaKind = mediaKind
        self.artworkURL = artworkURL
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, summary, mediaURL, audioURL, date, duration, podcast, mediaKind, artworkURL
    }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        title = try values.decode(String.self, forKey: .title)
        summary = try values.decode(String.self, forKey: .summary)
        // Existing audio-only listening records keep their URLs and progress.
        if let url = try values.decodeIfPresent(URL.self, forKey: .mediaURL) { mediaURL = url }
        else { mediaURL = try values.decode(URL.self, forKey: .audioURL) }
        date = try values.decodeIfPresent(Date.self, forKey: .date)
        duration = try values.decode(Double.self, forKey: .duration)
        podcast = try values.decode(Podcast.self, forKey: .podcast)
        mediaKind = try values.decodeIfPresent(MediaKind.self, forKey: .mediaKind) ?? .audio
        artworkURL = try values.decodeIfPresent(URL.self, forKey: .artworkURL)
    }
    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(title, forKey: .title)
        try values.encode(summary, forKey: .summary)
        try values.encode(mediaURL, forKey: .mediaURL)
        try values.encodeIfPresent(date, forKey: .date)
        try values.encode(duration, forKey: .duration)
        try values.encode(podcast, forKey: .podcast)
        try values.encode(mediaKind, forKey: .mediaKind)
        try values.encodeIfPresent(artworkURL, forKey: .artworkURL)
    }
}

struct ListeningRecord: Codable, Sendable {
    let episode: Episode
    var position: Double
    var updatedAt: Date
}

struct LibrarySnapshot: Codable {
    var podcasts: [Podcast] = []
    var records: [ListeningRecord] = []
    var lastEpisodeID: String?
}

enum PodcastError: LocalizedError {
    case invalidURL, badResponse, invalidFeed, noMedia, episodeUnavailable
    var errorDescription: String? {
        switch self {
        case .invalidURL: return "Enter a valid HTTP or HTTPS RSS feed URL."
        case .badResponse: return "The server is unavailable. Please try again."
        case .invalidFeed: return "This address isn't a readable podcast RSS feed."
        case .noMedia: return "This feed has no playable episodes."
        case .episodeUnavailable: return "This episode has no publicly available publisher audio or video. Try another episode."
        }
    }
}

func webURL(_ value: String) -> URL? {
    guard let url = URL(string: value.trimmingCharacters(in: .whitespacesAndNewlines)),
          ["https", "http"].contains(url.scheme?.lowercased() ?? ""),
          url.host != nil else { return nil }
    return url
}

func clock(_ seconds: Double) -> String {
    let n = seconds.isFinite ? Int(max(0, seconds)) : 0
    return n >= 3600 ? String(format: "%d:%02d:%02d", n / 3600, n / 60 % 60, n % 60)
        : String(format: "%d:%02d", n / 60, n % 60)
}

/// "28 min" for list metadata; nil when the duration is unknown.
func minutes(_ seconds: Double) -> String? {
    seconds > 0 && seconds.isFinite ? "\(max(1, Int(seconds / 60))) min" : nil
}

func plainText(_ html: String) -> String {
    html.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        .replacingOccurrences(of: "&amp;", with: "&")
        .replacingOccurrences(of: "&lt;", with: "<")
        .replacingOccurrences(of: "&gt;", with: ">")
        .replacingOccurrences(of: "&quot;", with: "\"")
        .replacingOccurrences(of: "&#39;", with: "'")
        .replacingOccurrences(of: "&nbsp;", with: " ")
        .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        .trimmingCharacters(in: .whitespacesAndNewlines)
}
