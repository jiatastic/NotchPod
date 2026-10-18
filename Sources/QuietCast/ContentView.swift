import SwiftUI
import AppKit

private let ink = Palette.text
private let muted = Palette.secondary
private let wash = Palette.selection
private let hairline = Palette.separator

struct ContentView: View {
    @EnvironmentObject private var library: Library
    @EnvironmentObject private var player: PodcastPlayer
    @EnvironmentObject private var browser: BrowserModel
    @State private var searchPresented = false
    @State private var searchReturnResponder: NSResponder?
    @State private var rssPresented = false
    @State private var rss = ""
    @State private var scrollPositions: [String: String] = [:]

    var body: some View {
        ZStack {
            contentShell
                .allowsHitTesting(!searchPresented)
                .accessibilityHidden(searchPresented)
            if searchPresented {
                GeometryReader { geometry in
                    ZStack(alignment: .top) {
                        Color.black.opacity(0.12).contentShape(Rectangle()).onTapGesture { closeSearch() }
                        SearchPanel(height: min(460, geometry.size.height - 32), playEpisode: { episode in
                            closeSearch(); player.play(episode)
                        }, choose: { podcast in
                            closeSearch(); browser.open(podcast)
                        }, dismiss: closeSearch)
                        .environmentObject(browser)
                        .frame(maxWidth: .infinity).padding(.top, 16)
                    }
                }.transaction { $0.animation = nil; $0.disablesAnimations = true }
            }
        }
        .background(Palette.surface).foregroundStyle(ink).tint(ink)
        .frame(minWidth: 720, minHeight: 480)
        .preferredColorScheme(.dark)
        .sheet(isPresented: $rssPresented) { rssSheet.preferredColorScheme(.dark) }
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Button(action: toggleSearch) { Image(systemName: "magnifyingglass") }
                    .help("Search podcasts · ⌘K").keyboardShortcut("k", modifiers: .command)
                    .accessibilityLabel("Search podcasts")
            }
        }
        .alert("Listening history", isPresented: Binding(get: { library.error != nil }, set: { if !$0 { library.error = nil } })) {
            Button("OK") { library.error = nil }
        } message: { Text(library.error ?? "") }
    }

    private var contentShell: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                sidebar.frame(width: 190)
                Rectangle().fill(hairline).frame(width: 1)
                GeometryReader { geometry in
                    let pictureHeight = min(260, max(120, geometry.size.height * (geometry.size.height < 420 ? 0.32 : 0.42)))
                    VStack(spacing: 0) {
                        if player.hasVideo {
                            // Keep the surface mounted while collapsed; only its presentation changes.
                            VideoPane(height: pictureHeight).environmentObject(player)
                                .frame(height: player.videoVisible ? pictureHeight + VideoPane.chromeHeight : 0, alignment: .top)
                                .opacity(player.videoVisible ? 1 : 0).clipped()
                                .allowsHitTesting(player.videoVisible)
                                .accessibilityHidden(!player.videoVisible)
                                .transition(.opacity)
                        }
                        mainContent.frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }
            Rectangle().fill(hairline).frame(height: 1)
            PlayerBar().environmentObject(player)
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 7) {
                Image(systemName: "waveform").font(.system(size: 12, weight: .medium))
                Text("QuietCast").font(.system(size: 13, weight: .medium))
            }.padding(.horizontal, 18).padding(.top, 12).padding(.bottom, 28)
            Button { browser.showRecent() } label: {
                HStack(spacing: 9) {
                    Image(systemName: "clock").font(.system(size: 12))
                    Text("Recent").font(.system(size: 12))
                    Spacer()
                }
                .padding(.horizontal, 10).padding(.vertical, 9)
                .background(browser.selected == nil && !browser.loading ? wash : .clear, in: RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle())
            }.buttonStyle(.plain).padding(.horizontal, 8)
            Text("Following").font(.system(size: 11, weight: .medium)).foregroundStyle(muted)
                .padding(.horizontal, 18).padding(.top, 30).padding(.bottom, 10)
            ScrollView {
                LazyVStack(spacing: 3) {
                    ForEach(library.podcasts) { podcast in
                        Button { browser.open(podcast) } label: {
                            HStack(spacing: 8) {
                                Artwork(url: podcast.artworkURL, size: 23)
                                Text(podcast.title).font(.system(size: 12)).lineLimit(1)
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 10).padding(.vertical, 7)
                            .background(browser.selected?.id == podcast.id ? wash : .clear, in: RoundedRectangle(cornerRadius: 6))
                            .contentShape(Rectangle())
                        }.buttonStyle(.plain).help(podcast.title)
                            .contextMenu { Button("Unfollow", role: .destructive) { library.toggle(podcast) } }
                    }
                    if library.podcasts.isEmpty {
                        Text("Your favorites, right here.").font(.system(size: 11)).foregroundStyle(muted)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 10).padding(.top, 3)
                    }
                }.padding(.horizontal, 8)
            }
            Spacer(minLength: 12)
            Button { rss = ""; rssPresented = true } label: {
                HStack(spacing: 8) {
                    Image(systemName: "plus").font(.system(size: 11))
                    Text("Add RSS feed").font(.system(size: 11))
                }.foregroundStyle(muted).padding(10).contentShape(Rectangle())
            }.buttonStyle(.plain).padding(.horizontal, 8)
        }.frame(maxHeight: .infinity).background(Palette.surface)
    }

    private var mainContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            if browser.loading {
                Spacer()
                HStack { Spacer(); ProgressView().controlSize(.small); Spacer() }
                Text("Loading episodes…").font(.system(size: 12)).foregroundStyle(muted)
                    .frame(maxWidth: .infinity).padding(.top, 12)
                Spacer()
            } else if let error = browser.feedError {
                emptyState(title: "Couldn't load this show", detail: error) {
                    if let podcast = browser.selected { browser.open(podcast) } else { rssPresented = true }
                }
            } else if let podcast = browser.selected {
                podcastHeader(podcast)
                if let error = browser.refreshError {
                    HStack(spacing: 12) {
                        Text("Couldn't refresh. Showing cached episodes.").font(.system(size: 11)).foregroundStyle(muted)
                        Spacer()
                        Button("Try again") { browser.refresh() }.buttonStyle(.plain).font(.system(size: 11))
                    }.help(error).padding(.horizontal, 36).padding(.bottom, 12)
                }
                episodeList(browser.episodes)
            } else {
                HStack {
                    Text("Recent").font(.system(size: 19, weight: .medium))
                    Spacer()
                    searchButton
                }.padding(.horizontal, 36).padding(.top, 28).padding(.bottom, 25)
                if library.recent.isEmpty {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("Find a show. Settle in.").font(.system(size: 22)).tracking(-0.5)
                        Text("No feeds to scroll. No account to make.\nJust something worth listening to.")
                            .font(.system(size: 13)).foregroundStyle(muted).lineSpacing(6)
                        Button(action: openSearch) {
                            HStack(spacing: 16) {
                                Text("Search podcasts")
                                Text("⌘K").foregroundStyle(Palette.onText.opacity(0.7)).font(.system(size: 11))
                            }.font(.system(size: 12)).padding(.horizontal, 16).padding(.vertical, 10)
                                .background(ink, in: Capsule()).foregroundStyle(Palette.onText)
                        }.buttonStyle(.plain).padding(.top, 8)
                    }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                        .padding(.leading, 36).padding(.bottom, 70)
                } else { episodeList(library.recent.map(\.episode)) }
            }
        }
    }
    private var searchButton: some View {
        Button(action: openSearch) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                Text("Search").font(.system(size: 11))
                Text("⌘K").font(.system(size: 11)).foregroundStyle(muted)
            }.foregroundStyle(muted).padding(.horizontal, 11).padding(.vertical, 7).background(wash, in: Capsule())
        }.buttonStyle(.plain)
    }
    private func podcastHeader(_ podcast: Podcast) -> some View {
        HStack(alignment: .top, spacing: 15) {
            Artwork(url: podcast.artworkURL, size: 45)
            VStack(alignment: .leading, spacing: 6) {
                Text(podcast.title).font(.system(size: 19, weight: .medium)).lineLimit(2)
                HStack(spacing: 8) {
                    Text(podcast.author).font(.system(size: 12)).foregroundStyle(muted).lineLimit(1)
                    if browser.refreshing {
                        ProgressView().controlSize(.mini).help("Refreshing episodes in the background")
                    }
                }
            }
            Spacer(minLength: 12)
            Button { library.toggle(podcast) } label: {
                Text(library.isFollowing(podcast) ? "Following" : "Follow")
                    .font(.system(size: 11)).padding(.horizontal, 13).padding(.vertical, 7)
                    .background(wash, in: Capsule())
            }.buttonStyle(.plain).fixedSize()
            searchButton
        }.padding(.horizontal, 36).padding(.top, 28).padding(.bottom, 28)
    }
    private func episodeList(_ episodes: [Episode]) -> some View {
        let section = browser.selected?.id ?? "recent"
        let position = Binding<String?>(get: { scrollPositions[section] }, set: {
            if let id = $0 { scrollPositions[section] = id }
        })
        return ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(episodes) { episode in
                    EpisodeRow(episode: episode).environmentObject(player).environmentObject(library)
                }
            }.scrollTargetLayout().padding(.horizontal, 36).padding(.bottom, 24)
        }
        .scrollPosition(id: position, anchor: .top)
        .id(section)
    }
    private func emptyState(title: String, detail: String, retry: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(.system(size: 20))
            Text(detail).font(.system(size: 12)).foregroundStyle(muted)
            Button("Try again", action: retry).buttonStyle(.bordered)
        }.padding(36).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
    private var rssSheet: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Add RSS feed").font(.system(size: 17, weight: .medium))
            Text("Paste a podcast's public RSS feed to listen here.").font(.system(size: 12)).foregroundStyle(muted)
            TextField("https://example.com/feed.xml", text: $rss)
                .textFieldStyle(.roundedBorder).onSubmit { submitRSS() }
            HStack {
                Spacer()
                Button("Cancel") { rssPresented = false }.keyboardShortcut(.cancelAction)
                Button("Open") { submitRSS() }.keyboardShortcut(.defaultAction).disabled(webURL(rss) == nil)
            }
        }.padding(28).frame(width: 440).background(Palette.surface).foregroundStyle(ink)
    }
    private func submitRSS() {
        guard webURL(rss) != nil else { return }
        rssPresented = false; browser.addRSS(rss)
    }
    private func openSearch() {
        guard !rssPresented, !searchPresented else { return }
        searchReturnResponder = NSApp.keyWindow?.firstResponder
        searchPresented = true
    }
    private func closeSearch() {
        searchPresented = false
        let previous = searchReturnResponder
        searchReturnResponder = nil
        DispatchQueue.main.async {
            if let view = previous as? NSView, let window = view.window, window === NSApp.keyWindow {
                window.makeFirstResponder(view)
            }
        }
    }
    private func toggleSearch() { if searchPresented { closeSearch() } else { openSearch() } }
}

private struct EpisodeRow: View {
    let episode: Episode
    @EnvironmentObject private var player: PodcastPlayer
    @EnvironmentObject private var library: Library
    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var active: Bool { player.episode?.id == episode.id }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 18) {
                Artwork(url: episode.artworkURL, fallbackURL: episode.podcast.artworkURL, size: 36)
                VStack(alignment: .leading, spacing: 9) {
                    Button(action: playEpisode) {
                        Text(episode.title).font(.system(size: 13, weight: active ? .medium : .regular))
                            .lineLimit(2).multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                    }.buttonStyle(.plain).help("Play episode")
                    ViewThatFits(in: .horizontal) {
                        metadata(includeProgress: true)
                        metadata(includeProgress: false)
                    }
                }
                Button(action: playEpisode) {
                    Image(systemName: active && player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 11)).foregroundStyle(active ? ink : muted)
                        .frame(width: 32, height: 32)
                        .background(active || hovering ? wash : .clear, in: Circle()).contentShape(Circle())
                }.buttonStyle(.plain)
                    .accessibilityLabel(active && player.isPlaying ? "Pause \(episode.title)" : "Play \(episode.title)")
            }.padding(.vertical, 20)
            Rectangle().fill(hairline).frame(height: 1)
        }.onHover { hovering = $0 }
    }
    private func playEpisode() {
        if player.episode?.id != episode.id && (episode.isVideo || player.hasVideo) {
            VideoMotion.change(reduceMotion: reduceMotion) { player.play(episode) }
        } else { player.play(episode) }
    }
    private func metadata(includeProgress: Bool) -> some View {
        HStack(spacing: 8) {
            if episode.isVideo { Label("Video", systemImage: "video").labelStyle(.titleAndIcon) }
            if let date = episode.date {
                if episode.isVideo { Text("·") }
                Text(date, format: .dateTime.year().month().day())
            }
            if episode.duration > 0 {
                if episode.isVideo || episode.date != nil { Text("·") }
                Text("\(max(1, Int(episode.duration / 60))) min")
            }
            let progress = library.position(for: episode)
            if includeProgress, progress > 0 {
                if episode.isVideo || episode.date != nil || episode.duration > 0 { Text("·") }
                Text(episode.duration > 0 && progress >= episode.duration - 2 ? "Finished" : "At \(clock(progress))")
            }
        }.font(.system(size: 11)).foregroundStyle(muted).fixedSize(horizontal: true, vertical: false)
    }
}
