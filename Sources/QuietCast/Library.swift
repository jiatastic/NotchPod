import Foundation
import Combine

@MainActor
final class Library: ObservableObject {
    @Published private(set) var snapshot = LibrarySnapshot()
    @Published var error: String?
    private let file: URL

    init(file: URL? = nil) {
        self.file = file ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("QuietCast/library.json")
        if FileManager.default.fileExists(atPath: self.file.path) {
            do { snapshot = try JSONDecoder().decode(LibrarySnapshot.self, from: Data(contentsOf: self.file)) }
            catch { self.error = "Couldn't read listening history: \(error.localizedDescription)" }
        }
    }
    var podcasts: [Podcast] { snapshot.podcasts }
    var recent: [ListeningRecord] { snapshot.records.sorted { $0.updatedAt > $1.updatedAt } }
    func position(for episode: Episode) -> Double { snapshot.records.first { $0.episode.id == episode.id }?.position ?? 0 }
    func isFollowing(_ podcast: Podcast) -> Bool { podcasts.contains { $0.id == podcast.id } }
    func toggle(_ podcast: Podcast) {
        if isFollowing(podcast) { snapshot.podcasts.removeAll { $0.id == podcast.id } }
        else { snapshot.podcasts.append(podcast) }
        save()
    }
    func record(_ episode: Episode, position: Double) {
        guard position.isFinite, position >= 0 else { return }
        snapshot.records.removeAll { $0.episode.id == episode.id }
        snapshot.records.insert(ListeningRecord(episode: episode, position: position, updatedAt: Date()), at: 0)
        snapshot.records = Array(snapshot.records.prefix(200))
        snapshot.lastEpisodeID = episode.id
        save()
    }
    private func save() {
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(snapshot).write(to: file, options: .atomic)
        } catch { self.error = "Couldn't save listening history: \(error.localizedDescription)" }
    }
}

@MainActor
final class BrowserModel: ObservableObject {
    @Published var query = "" { didSet { if query != oldValue { invalidateSearch(); scheduleSearch() } } }
    // Apple's directory storefront follows the Mac's region; there is no picker.
    // Numeric UN M.49 regions ("419") are not storefronts.
    let country: String = {
        let id = Locale.current.region?.identifier ?? ""
        return id.count == 2 && id.allSatisfy(\.isLetter) ? id : "US"
    }()
    @Published var results: [Podcast] = []
    @Published private(set) var episodeResults: [EpisodeSearchHit] = []
    @Published private(set) var searchWarning: String?
    @Published private(set) var resolvingEpisodeID: String?
    @Published private(set) var episodePlaybackError: String?
    @Published var selected: Podcast?
    @Published var episodes: [Episode] = []
    @Published var searching = false
    @Published var loading = false
    @Published var hasSearched = false
    @Published var error: String?
    @Published var feedError: String?
    @Published private(set) var refreshing = false
    @Published private(set) var refreshError: String?
    private var feedCache: [String: FeedResult] = [:]
    private var cacheOrder: [String] = []
    private var completedSearch: String?
    private var composingSearch = false
    private var searchCache: [String: (result: DirectorySearchResults, date: Date)] = [:]
    private var searchCacheOrder: [String] = []
    private var directoryPodcasts: [String: Podcast] = [:]
    private var directoryOrder: [String] = []
    var searchResults: [PodcastSearchResult] {
        episodeResults.map(PodcastSearchResult.episode) + results.map(PodcastSearchResult.show)
    }
    var resultsAreCurrent: Bool { !searching && completedSearch == searchKey }
    private var searchKey: String { country + ":" + query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
    private let service = PodcastService()
    private var searchTask: Task<Void, Never>?
    private var feedTask: Task<Void, Never>?
    private var episodeTask: Task<Void, Never>?
    private var searchID = UUID()
    private var feedID = UUID()
    private var resolutionID = UUID()

    func search() { startSearch(delay: 0) }
    func scheduleSearch() { startSearch(delay: 350_000_000) }
    func setSearchComposition(_ composing: Bool) {
        guard composingSearch != composing else { return }
        composingSearch = composing
        invalidateSearch()
        if !composing { scheduleSearch() }
    }
    func endSearchInput() {
        composingSearch = false
        searchTask?.cancel(); searchID = UUID(); searching = false
        cancelEpisodeResolution()
    }
    private func startSearch(delay: UInt64) {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty, !composingSearch else { return }
        searchTask?.cancel()
        cancelEpisodeResolution()
        let id = UUID(); searchID = id
        let key = searchKey
        completedSearch = nil
        searching = true; error = nil; searchWarning = nil; hasSearched = true
        if let cached = searchCache[key], Date().timeIntervalSince(cached.date) < 300 {
            searchCacheOrder.removeAll { $0 == key }; searchCacheOrder.append(key)
            applySearch(cached.result, key: key)
            return
        }
        let country = country
        searchTask = Task {
            do {
                if delay > 0 { try await Task.sleep(nanoseconds: delay) }
                try Task.checkCancellation()
                let result = try await service.searchDirectory(term, country: country)
                guard !Task.isCancelled, searchID == id else { return }
                applySearch(result, key: key)
                if result.warning == nil {
                    searchCache[key] = (result, Date())
                    searchCacheOrder.removeAll { $0 == key }; searchCacheOrder.append(key)
                    while searchCacheOrder.count > 10 { searchCache.removeValue(forKey: searchCacheOrder.removeFirst()) }
                }
            } catch {
                guard !Task.isCancelled, searchID == id else { return }
                self.error = error.localizedDescription; searching = false
            }
        }
    }
    private func applySearch(_ result: DirectorySearchResults, key: String) {
        results = result.shows; episodeResults = result.episodes; searchWarning = result.warning
        completedSearch = key; searching = false
    }
    private func invalidateSearch() {
        searchTask?.cancel(); searchID = UUID()
        cancelEpisodeResolution()
        completedSearch = nil; searching = false; hasSearched = false; error = nil; searchWarning = nil
        // Keep old rows stable during a new request, but resultsAreCurrent disables
        // their actions until the current query completes. Empty input shows library.
        if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { results = []; episodeResults = [] }
    }
    func cancelEpisodeResolution() {
        episodeTask?.cancel(); episodeTask = nil; resolutionID = UUID()
        resolvingEpisodeID = nil; episodePlaybackError = nil
    }
    func playSearchEpisode(_ hit: EpisodeSearchHit, play: @escaping (Episode) -> Void) {
        guard resultsAreCurrent, resolvingEpisodeID != hit.id else { return }
        cancelEpisodeResolution()
        let id = UUID(); resolutionID = id
        let key = searchKey
        let country = country
        resolvingEpisodeID = hit.id
        episodeTask = Task {
            do {
                let episode = try await resolveEpisode(hit, country: country)
                guard !Task.isCancelled, resolutionID == id, searchKey == key, resultsAreCurrent else { return }
                resolvingEpisodeID = nil; episodeTask = nil
                play(episode)
            } catch {
                guard !Task.isCancelled, resolutionID == id else { return }
                resolvingEpisodeID = nil; episodeTask = nil
                episodePlaybackError = error.localizedDescription
            }
        }
    }
    private func resolveEpisode(_ hit: EpisodeSearchHit, country: String) async throws -> Episode {
        let directoryKey = country + ":" + (hit.collectionID ?? hit.feedURL?.absoluteString ?? hit.id)
        let podcast: Podcast
        if let cached = directoryPodcasts[directoryKey] { podcast = cached }
        else if let direct = hit.podcast { podcast = direct }
        else if let collectionID = hit.collectionID { podcast = try await service.lookupPodcast(collectionID, country: country) }
        else { throw PodcastError.episodeUnavailable }
        try Task.checkCancellation()
        directoryPodcasts[directoryKey] = podcast
        directoryOrder.removeAll { $0 == directoryKey }; directoryOrder.append(directoryKey)
        while directoryOrder.count > 20 { directoryPodcasts.removeValue(forKey: directoryOrder.removeFirst()) }
        if let cached = feedCache[podcast.id], let episode = hit.matchingEpisode(in: cached) { return episode }
        if hit.guid != nil, let episode = hit.publisherEpisode(in: podcast) { return episode }
        // Missing GUID/media metadata: try RSS for a canonical publisher episode.
        do {
            let result = try await service.feed(podcast.feedURL, existing: podcast)
            try Task.checkCancellation()
            remember(result)
            if let episode = hit.matchingEpisode(in: result) { return episode }
        } catch {
            try Task.checkCancellation()
            if hit.mediaURL == nil { throw error }
        }
        guard let episode = hit.publisherEpisode(in: podcast) else { throw PodcastError.episodeUnavailable }
        return episode
    }
    func open(_ podcast: Podcast) {
        cancelEpisodeResolution()
        guard selected?.id != podcast.id || (!loading && !refreshing) else { return }
        load(podcast.feedURL, existing: podcast)
    }
    func refresh() {
        guard let selected, !refreshing, !loading else { return }
        load(selected.feedURL, existing: selected)
    }
    func addRSS(_ string: String) {
        guard let url = webURL(string) else { feedError = PodcastError.invalidURL.localizedDescription; return }
        load(url, existing: nil)
    }
    func showRecent() {
        feedTask?.cancel(); feedID = UUID()
        selected = nil; episodes = []; loading = false; refreshing = false
        feedError = nil; refreshError = nil
    }
    private func load(_ url: URL, existing: Podcast?) {
        feedTask?.cancel()
        let id = UUID(); feedID = id
        let cached = feedCache[url.absoluteString]
        if cached != nil {
            cacheOrder.removeAll { $0 == url.absoluteString }
            cacheOrder.append(url.absoluteString)
        }
        selected = cached?.podcast ?? existing
        episodes = cached?.episodes ?? []
        loading = cached == nil; refreshing = cached != nil
        feedError = nil; refreshError = nil
        feedTask = Task {
            do {
                let result = try await service.feed(url, existing: existing)
                guard !Task.isCancelled, feedID == id else { return }
                remember(result)
                if selected != result.podcast { selected = result.podcast }
                if episodes != result.episodes { episodes = result.episodes }
                loading = false; refreshing = false
            } catch {
                guard !Task.isCancelled, feedID == id else { return }
                if cached != nil { refreshError = error.localizedDescription }
                else { feedError = error.localizedDescription }
                loading = false; refreshing = false
            }
        }
    }
    private func remember(_ result: FeedResult) {
        let key = result.podcast.id
        feedCache[key] = result
        cacheOrder.removeAll { $0 == key }
        cacheOrder.append(key)
        // Bound memory: keep only the 20 most recently opened/refreshed feeds.
        while cacheOrder.count > 20 { feedCache.removeValue(forKey: cacheOrder.removeFirst()) }
    }
}
