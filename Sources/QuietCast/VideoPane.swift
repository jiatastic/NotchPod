import SwiftUI
import AVKit

struct VideoPane: View {
    static let chromeHeight: CGFloat = 56
    @EnvironmentObject private var player: PodcastPlayer
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let height: CGFloat

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "video").font(.system(size: 11))
                Text(player.episode?.title ?? "Now watching").font(.system(size: 11)).lineLimit(1)
                Spacer(minLength: 12)
                Button { VideoMotion.change(reduceMotion: reduceMotion) { player.toggleVideo() } } label: {
                    HStack(spacing: 5) {
                        Text("Hide video")
                        Image(systemName: "chevron.up").font(.system(size: 9))
                    }.font(.system(size: 10)).padding(.vertical, 5).contentShape(Rectangle())
                }.buttonStyle(.plain).help("Audio keeps playing when the picture is hidden")
            }.foregroundStyle(Palette.secondary).frame(height: 22)

            ZStack {
                NativeVideoSurface(player: player.videoPlayer)
                if player.videoPlayer.currentItem == nil {
                    Text("Press play to watch.").font(.system(size: 12)).foregroundStyle(.white.opacity(0.7))
                } else if player.buffering {
                    ProgressView().controlSize(.small).tint(.white)
                } else if player.error != nil {
                    Text("Video unavailable. Try again below.")
                        .font(.system(size: 12)).foregroundStyle(.white.opacity(0.7))
                }
            }
            .frame(height: height)
            .background(Color.black)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .accessibilityLabel("Video picture. Playback controls are in the bottom bar.")
        }
        .padding(.horizontal, 36).padding(.top, 14).padding(.bottom, 10)
    }
}

enum VideoMotion {
    @MainActor static func change(reduceMotion: Bool, _ action: () -> Void) {
        let event = NSApp.currentEvent?.type
        let keyboard = event == .keyDown || event == .keyUp
        withAnimation(reduceMotion || keyboard ? nil : .easeInOut(duration: 0.2), action)
    }
}

// One player, one set of controls. The surface only presents its video frames.
struct NativeVideoSurface: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> QuietVideoView {
        let view = QuietVideoView()
        view.controlsStyle = .none
        view.videoGravity = .resizeAspect
        view.showsFullScreenToggleButton = false
        view.player = player
        return view
    }
    func updateNSView(_ view: QuietVideoView, context: Context) {
        if view.player !== player { view.player = player }
    }
    static func dismantleNSView(_ view: QuietVideoView, coordinator: ()) {
        // Detach the view without stopping or replacing the shared player.
        view.player = nil
    }
}

final class QuietVideoView: AVPlayerView {
    // Keep AVPlayerView's independent J/K/L shortcuts from changing playback speed.
    override var acceptsFirstResponder: Bool { false }
}
