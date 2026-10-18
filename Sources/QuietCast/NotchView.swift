import SwiftUI

struct NotchRootView: View {
    @EnvironmentObject private var notch: NotchController
    @EnvironmentObject private var library: Library
    @EnvironmentObject private var player: PodcastPlayer
    @EnvironmentObject private var captions: CaptionModel

    var body: some View {
        Group {
            if notch.geometry.hasCutout {
                GeometryReader { viewport in
                    let progress = notch.expansionProgress(for: viewport.size.height)
                    VStack(spacing: 0) {
                        cap(progress: progress)
                        // Keep the same content mounted throughout both directions.
                        // Only the live viewport reveals/clips it; no content pop-out.
                        content.allowsHitTesting(notch.presentation == .open)
                            .accessibilityHidden(notch.presentation == .tucked)
                            // Under a caption strip the player must not peek through.
                            .opacity(notch.showsCaptionStrip ? Double(min(1, max(0, progress * 2 - 0.3))) : 1)
                    }
                    .overlay(alignment: .top) {
                        if notch.showsCaptionStrip {
                            CaptionLine(cue: captions.current, bilingual: captions.mode == .bilingual)
                                .padding(.horizontal, 18)
                                .frame(width: notch.tuckedWidth, height: NotchController.captionStripHeight, alignment: .top)
                                .padding(.top, notch.triggerHeight)
                                .opacity(Double(max(0, 1 - progress * 3)))
                                .allowsHitTesting(false)
                        }
                    }
                    .frame(width: notch.expandedWidth)
                    .frame(width: viewport.size.width, height: viewport.size.height, alignment: .top)
                    // The native parent owns the only black silhouette.
                    .clipShape(NotchSilhouette(shoulder: NotchController.shoulder, bottomRadius: 12 + 10 * progress))
                }.ignoresSafeArea()
            } else {
                // A real system menu-bar popover, not an artificial second notch.
                content
            }
        }
        .background {
            if #available(macOS 15, *) { CaptionTranslator() }
        }
        .foregroundStyle(Palette.text).tint(Palette.text)
        .preferredColorScheme(.dark)
        .alert("Listening history", isPresented: Binding(get: { library.error != nil }, set: { if !$0 { library.error = nil } })) {
            Button("OK") { library.error = nil }
        } message: { Text(library.error ?? "") }
    }
    private func cap(progress: CGFloat) -> some View {
        HStack(spacing: 0) {
            Spacer(minLength: 0)
            Group {
                if let episode = player.episode {
                    Artwork(url: episode.artworkURL, fallbackURL: episode.podcast.artworkURL, size: 18)
                }
            }.frame(width: 32)
            // The real camera gap remains completely empty.
            Color.clear.frame(width: notch.geometry.cutoutWidth)
            Group {
                if player.episode != nil {
                    NotchActivity(playing: player.isPlaying, buffering: player.buffering, active: progress < 0.95)
                        .frame(width: 18, height: 16)
                        .accessibilityLabel(player.buffering ? "Buffering" : player.isPlaying ? "Playing" : "Paused")
                }
            }.frame(width: 32)
            Spacer(minLength: 0)
        }.frame(height: notch.geometry.capHeight)
            .opacity(Double(max(0, 1 - progress * 2))).allowsHitTesting(false)
    }
    private var content: some View {
        Group {
            switch notch.page {
            case .player: NotchNowPlayingView()
            case .browse: NotchBrowseView()
            case .rss: NotchRSSView()
            }
        }
        .frame(width: notch.expandedWidth, height: notch.detailHeight)
        .background(notch.geometry.hasCutout ? Color.clear : Palette.surface)
    }
}

struct NotchSilhouette: Shape {
    var shoulder: CGFloat
    var bottomRadius: CGFloat
    func path(in rect: CGRect) -> Path {
        let s = min(shoulder, rect.height / 3)
        let r = min(bottomRadius, (rect.height - s) / 2)
        var p = Path()
        p.move(to: CGPoint(x: 0, y: 0))
        p.addQuadCurve(to: CGPoint(x: s, y: s), control: CGPoint(x: s, y: 0))
        p.addLine(to: CGPoint(x: s, y: rect.height - r))
        p.addQuadCurve(to: CGPoint(x: s + r, y: rect.height), control: CGPoint(x: s, y: rect.height))
        p.addLine(to: CGPoint(x: rect.width - s - r, y: rect.height))
        p.addQuadCurve(to: CGPoint(x: rect.width - s, y: rect.height - r), control: CGPoint(x: rect.width - s, y: rect.height))
        p.addLine(to: CGPoint(x: rect.width - s, y: s))
        p.addQuadCurve(to: CGPoint(x: rect.width, y: 0), control: CGPoint(x: rect.width - s, y: 0))
        p.closeSubpath()
        return p
    }
}

private struct NotchBrowseView: View {
    @EnvironmentObject private var notch: NotchController
    @EnvironmentObject private var browser: BrowserModel
    @EnvironmentObject private var library: Library

    var body: some View {
        if browser.selected == nil && browser.loading {
            ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if browser.selected == nil, let error = browser.feedError {
            VStack(alignment: .leading, spacing: 14) {
                Text("Couldn't load this feed").font(.system(size: 15))
                Text(error).font(.system(size: 12)).foregroundStyle(Palette.secondary)
                Button("Edit feed") { notch.showRSS() }
            }.padding(Metrics.gutter).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let show = browser.selected {
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Button { browser.showRecent() } label: {
                        Image(systemName: "chevron.left").font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Palette.secondary).frame(width: 24, height: 30).contentShape(Rectangle())
                    }.buttonStyle(PressableStyle()).accessibilityLabel("Back to search")
                    Artwork(url: show.artworkURL, size: 36)
                    Text(show.title).font(.system(size: 14, weight: .semibold)).lineLimit(2)
                    Spacer(minLength: 4)
                    if browser.refreshing { ProgressView().controlSize(.mini) }
                    FollowButton(following: library.isFollowing(show)) { library.toggle(show) }
                // The chevron glyph sits ~8pt inside its frame; this optically aligns it to the gutter.
                }.padding(.leading, Metrics.gutter - 8).padding(.trailing, Metrics.gutter).padding(.top, 14).padding(.bottom, 8)
                if browser.loading {
                    Spacer(); ProgressView().controlSize(.small); Spacer()
                } else if let error = browser.feedError {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("Couldn't load this show").font(.system(size: 15))
                        Text(error).font(.system(size: 12)).foregroundStyle(Palette.secondary)
                        Button("Try again") { notch.openShow(show) }
                    }.padding(Metrics.gutter).frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    if let error = browser.refreshError {
                        HStack {
                            Text("Showing cached episodes.").font(.system(size: 11)).foregroundStyle(Palette.secondary)
                            Spacer()
                            Button("Retry") { browser.refresh() }.font(.system(size: 11)).buttonStyle(.plain)
                        }.help(error).padding(.horizontal, Metrics.gutter).padding(.bottom, 8)
                    }
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(browser.episodes) { episode in
                                Button { notch.play(episode) } label: {
                                    NotchRow(title: episode.title, detail: minutes(episode.duration)) {
                                        Artwork(url: episode.artworkURL, fallbackURL: episode.podcast.artworkURL, size: 40)
                                    }
                                }.buttonStyle(RowStyle()).accessibilityLabel("Play \(episode.title)")
                            }
                        }.scrollTargetLayout().padding(.horizontal, Metrics.gutter - Metrics.rowInset).padding(.bottom, 14)
                    }.scrollPosition(id: notch.scrollPosition(for: show.id), anchor: .top).id(show.id)
                }
            }
        } else {
            SearchPanel(height: notch.detailHeight, width: notch.expandedWidth, embedded: true,
                playEpisode: { notch.play($0) }, choose: { notch.openShow($0) }, dismiss: { notch.showPlayer() })
        }
    }
}

private struct NotchRSSView: View {
    @EnvironmentObject private var notch: NotchController
    @EnvironmentObject private var browser: BrowserModel
    @FocusState private var focused: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Add RSS feed").font(.system(size: 20))
            TextField("https://example.com/feed.xml", text: $notch.rssDraft)
                .textFieldStyle(.roundedBorder).focused($focused).onSubmit(open)
            HStack {
                Button("Cancel") { notch.showPlayer() }.buttonStyle(.plain)
                Spacer()
                Button("Open feed", action: open).buttonStyle(.borderedProminent).disabled(webURL(notch.rssDraft) == nil)
            }.font(.system(size: 12))
            Spacer()
        }.padding(Metrics.gutter).padding(.top, 20).task { focused = true }
    }
    private func open() {
        guard webURL(notch.rssDraft) != nil else { return }
        browser.addRSS(notch.rssDraft)
        notch.showLoadedFeed()
    }
}

/// Follow is a quiet outline pill; following is plain text with a check.
/// Native bordered buttons read as borrowed from another app inside the notch.
private struct FollowButton: View {
    let following: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Label(following ? "Following" : "Follow", systemImage: following ? "checkmark" : "plus")
                .font(.system(size: 11, weight: .medium)).labelStyle(.titleAndIcon)
                .foregroundStyle(following ? Palette.secondary : Palette.text)
                .padding(.horizontal, 10).frame(height: 24)
                .overlay { Capsule().strokeBorder(following ? .clear : Palette.track, lineWidth: 1) }
                .contentShape(Capsule())
        }.buttonStyle(PressableStyle(scale: 0.96)).fixedSize()
            .accessibilityHint(following ? "Unfollow this show" : "Follow this show")
    }
}

/// Shared row body for episode, show, search and recent lists: artwork, two
/// lines, and a trailing glyph shown only while RowStyle highlights the row
/// (the whole row is the target, so a permanent glyph is noise).
struct NotchRow<Leading: View>: View {
    let title: String
    var detail: String? = nil
    var symbol = "play.fill"
    var busy = false
    @ViewBuilder let leading: () -> Leading
    @Environment(\.rowHighlighted) private var highlighted
    var body: some View {
        HStack(spacing: 12) {
            leading()
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 13)).lineLimit(2).multilineTextAlignment(.leading)
                if let detail {
                    Text(detail).font(.system(size: 11)).foregroundStyle(Palette.secondary).lineLimit(1)
                }
            }.layoutPriority(1)
            Spacer(minLength: 8)
            if busy {
                ProgressView().controlSize(.mini)
            } else {
                Image(systemName: symbol).font(.system(size: 10, weight: .semibold)).foregroundStyle(Palette.secondary)
                    .opacity(highlighted ? 1 : 0)
            }
        }
    }
}
