import SwiftUI

struct PlayerBar: View {
    @EnvironmentObject private var player: PodcastPlayer
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dragging = false
    @State private var scrub = 0.0

    var body: some View {
        VStack(spacing: 10) {
            if let error = player.error {
                HStack {
                    Text(error).font(.system(size: 12)).lineLimit(2)
                    Spacer()
                    Button("Try again") { if let episode = player.episode { player.play(episode) } }.buttonStyle(.plain)
                }.foregroundStyle(Palette.secondary)
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 20) {
                    information.frame(minWidth: 200, maxWidth: 330, alignment: .leading).layoutPriority(1)
                    controls
                    timeline.frame(minWidth: 200, maxWidth: .infinity)
                    options
                }.frame(minWidth: 800)
                VStack(spacing: 12) {
                    HStack(spacing: 20) {
                        information.frame(maxWidth: .infinity, alignment: .leading).layoutPriority(1)
                        controls
                        options
                    }
                    timeline
                }
            }
        }
        .padding(.horizontal, 24).padding(.vertical, 14)
        .background(Palette.surface)
        .onChange(of: player.episode?.id) { _, _ in dragging = false; scrub = player.position }
    }

    private var information: some View {
        HStack(spacing: 11) {
            Artwork(url: player.episode?.artworkURL, fallbackURL: player.episode?.podcast.artworkURL, size: 36)
            VStack(alignment: .leading, spacing: 4) {
                Text(player.episode?.title ?? "Nothing playing")
                    .font(.system(size: 12, weight: .medium)).lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .help(player.episode?.title ?? "Nothing playing")
                Text(player.buffering ? "Buffering…" : player.episode?.podcast.title ?? "Pick an episode. Press play.")
                    .font(.system(size: 11)).foregroundStyle(Palette.secondary).lineLimit(1)
            }
        }
    }
    private var controls: some View {
        HStack(spacing: 12) {
            icon("gobackward.15", label: "Back 15 seconds") { player.skip(-15) }
            Button { player.toggle() } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 12)).foregroundStyle(Palette.onText)
                    .frame(width: 34, height: 34).background(Palette.text, in: Circle())
            }.buttonStyle(.plain).accessibilityLabel(player.isPlaying ? "Pause" : "Play")
            icon("goforward.30", label: "Forward 30 seconds") { player.skip(30) }
        }.fixedSize().disabled(player.episode == nil)
    }
    private var timeline: some View {
        VStack(spacing: 2) {
            Slider(value: Binding(get: { dragging ? scrub : min(player.position, max(player.duration, 1)) }, set: { scrub = $0 }),
                   in: 0...max(player.duration, 1), onEditingChanged: { editing in
                if editing { scrub = player.position; dragging = true }
                else { dragging = false; player.seek(scrub) }
            })
            .controlSize(.small).tint(Palette.text).disabled(player.duration <= 0)
            .accessibilityLabel("Playback progress")
            .accessibilityValue("\(clock(dragging ? scrub : player.position)) of \(clock(player.duration))")
            HStack {
                Text(clock(dragging ? scrub : player.position))
                Spacer()
                Text(player.duration > 0 ? clock(player.duration) : "—:—")
            }.font(.system(size: 11, design: .monospaced)).foregroundStyle(Palette.secondary)
        }
    }
    private var options: some View {
        HStack(spacing: 12) {
            if player.hasVideo {
                Button {
                    VideoMotion.change(reduceMotion: reduceMotion) { player.toggleVideo() }
                } label: {
                    Image(systemName: player.videoVisible ? "video.slash" : "video")
                        .font(.system(size: 14)).frame(width: 28, height: 32).contentShape(Rectangle())
                }.buttonStyle(.plain).foregroundStyle(Palette.secondary)
                    .help(player.videoVisible ? "Hide video · audio keeps playing" : "Show video")
                    .accessibilityLabel(player.videoVisible ? "Hide video" : "Show video")
            }
            Menu {
                ForEach([Float(0.8), 1, 1.2, 1.5, 2], id: \.self) { rate in
                    Button("\(rate.formatted())×") { player.rate = rate }
                }
            } label: { Text("\(player.rate.formatted())×").font(.system(size: 12)).monospacedDigit() }
                .menuStyle(.borderlessButton).fixedSize().frame(width: 48)
                .accessibilityLabel("Playback speed")
        }.fixedSize()
    }
    private func icon(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 16)).frame(width: 28, height: 32).contentShape(Rectangle())
        }.buttonStyle(.plain).foregroundStyle(Palette.secondary).help(label).accessibilityLabel(label)
    }
}
