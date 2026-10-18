import SwiftUI
import AppKit

@main
struct QuietCastApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    // The player lives in the display notch. No main window opens at launch.
    var body: some Scene {
        Settings { NotchPreferencesView() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject {
    private let library = Library()
    private let browser = BrowserModel()
    private lazy var player = PodcastPlayer(library: library)
    private var notch: NotchController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        NSApp.appearance = NSAppearance(named: .darkAqua)
        notch = NotchController(library: library, player: player, browser: browser)
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        notch?.showPlayer()
        return false
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationWillTerminate(_ notification: Notification) {
        player.persist()
        notch?.shutdown()
    }
}

private struct NotchPreferencesView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            Text("Listen").font(.system(size: 19, weight: .medium))
            Text("Hover the notch to reveal playback. Audio continues when tucked. Displays without a notch use the menu-bar popover instead.")
                .font(.system(size: 12)).foregroundStyle(Palette.secondary).lineSpacing(4)
        }.padding(28).frame(width: 360).background(Palette.surface).foregroundStyle(Palette.text)
            .preferredColorScheme(.dark)
    }
}
