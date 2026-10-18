import AppKit
import SwiftUI
import Combine

enum NotchPresentation { case tucked, open }
enum NotchPage { case player, browse, rss }

/// Only verified camera geometry gets a notch surface. Never invent a cutout.
struct NotchGeometry: Equatable {
    var centerX: CGFloat
    var top: CGFloat
    var cutoutWidth: CGFloat
    var capHeight: CGFloat
    var availableHeight: CGFloat
    var hasCutout: Bool

    init(screen: NSScreen?) {
        let frame = screen?.frame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        if let screen, screen.safeAreaInsets.top > 0,
           let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea,
           right.minX > left.maxX, right.minX - left.maxX < frame.width / 2 {
            hasCutout = true
            centerX = (left.maxX + right.minX) / 2
            cutoutWidth = right.minX - left.maxX
            capHeight = screen.safeAreaInsets.top
        } else {
            hasCutout = false; centerX = frame.midX; cutoutWidth = 0; capHeight = 0
        }
        top = frame.maxY
        availableHeight = max(240, top - (screen?.visibleFrame.minY ?? frame.minY) - 16)
    }
}

@MainActor
final class NotchController: NSObject, ObservableObject, NSWindowDelegate, NSPopoverDelegate, NSMenuDelegate {
    static let shoulder: CGFloat = 12
    static let captionStripWidth: CGFloat = 420
    static let captionStripHeight: CGFloat = 26
    private static let hoverDelay: UInt64 = 225_000_000
    private static let departureDelay: UInt64 = 250_000_000
    private static let retentionPadding: CGFloat = 12
    @Published private(set) var presentation: NotchPresentation = .tucked
    @Published private(set) var geometry: NotchGeometry
    @Published private(set) var page: NotchPage = .player
    @Published var rssDraft = ""
    let library: Library
    let player: PodcastPlayer
    let browser: BrowserModel
    let captions: CaptionModel
    var expandedWidth: CGFloat { max(page == .player ? 400 : 420, geometry.cutoutWidth + 80) }
    // Camera-side wings only; activationFrame never includes the caption strip.
    private var triggerWidth: CGFloat { geometry.cutoutWidth + (player.episode == nil ? 0 : 64) }
    var triggerHeight: CGFloat { geometry.capHeight + 2 }
    var showsCaptionStrip: Bool { geometry.hasCutout && captions.showsTuckedStrip }
    var tuckedWidth: CGFloat { showsCaptionStrip ? max(triggerWidth, Self.captionStripWidth) : triggerWidth }
    var tuckedHeight: CGFloat { triggerHeight + (showsCaptionStrip ? Self.captionStripHeight : 0) }
    var detailHeight: CGFloat {
        let video = player.hasVideo && player.videoVisible ? CGFloat(166) : 0
        let error = player.error == nil ? CGFloat(0) : 44
        let caption: CGFloat = captions.showsCaptionArea ? captions.mode.playerHeight + Metrics.captionSpacing : 0
        let requested = page == .player ? (player.episode == nil ? 132 : 200 + video + error + caption) : 460
        return min(requested, geometry.availableHeight - geometry.capHeight)
    }
    var contentWidth: CGFloat { presentation == .tucked ? tuckedWidth : expandedWidth }
    var isInteracting = false {
        didSet {
            guard isInteracting != oldValue else { return }
            if isInteracting { cancelTuck() }
            else if presentation == .open, !pointerInside { scheduleTuck() }
        }
    }

    private var panel: NotchPanel!
    private var frameAnimator: NotchFrameAnimator!
    private var popover: NSPopover?
    private var statusItem: NSStatusItem?
    private var playMenuItem: NSMenuItem?
    private var videoMenuItem: NSMenuItem?
    private var speedItems: [NSMenuItem] = []
    private var observers: [NSObjectProtocol] = []
    private var subscriptions = Set<AnyCancellable>()
    private var keyMonitor: Any?
    private var pointerMonitors: [Any] = []
    private var pointerTimer: Timer?
    private var hoverTask: Task<Void, Never>?
    private var tuckTask: Task<Void, Never>?
    private var pointerInside = false
    private var hoverRequiresExit = false
    private var menuTracking = false
    private var lastOpenedAt = Date.distantPast
    private var screenID: NSNumber?
    private var scrollPositions: [String: String] = [:]
    private var lastTarget = NSRect.zero
    private var captionItems: [NSMenuItem] = []
    private var selectedScreen: NSScreen? {
        NSScreen.screens.first { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber) == screenID }
            ?? NSScreen.screens.first { NotchGeometry(screen: $0).hasCutout }
            ?? NSScreen.main ?? NSScreen.screens.first
    }
    private var activeWindow: NSWindow? {
        geometry.hasCutout ? panel : popover?.contentViewController?.view.window
    }

    init(library: Library, player: PodcastPlayer, browser: BrowserModel) {
        self.library = library; self.player = player; self.browser = browser
        captions = CaptionModel(player: player)
        let saved = UserDefaults.standard.object(forKey: "notchDisplay") as? NSNumber
        let screen = NSScreen.screens.first { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber) == saved }
            ?? NSScreen.screens.first { NotchGeometry(screen: $0).hasCutout } ?? NSScreen.main
        screenID = saved ?? screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        geometry = NotchGeometry(screen: screen)
        super.init()
        panel = NotchPanel(contentRect: targetFrame(), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.delegate = self
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = false
        panel.colorSpace = .sRGB; panel.alphaValue = 1
        panel.acceptsMouseMovedEvents = true
        panel.level = .statusBar; panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = false; panel.isReleasedWhenClosed = false
        panel.isMovable = false; panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        frameAnimator = NotchFrameAnimator(window: panel)
        createStatusItem()
        installNotchContent()
        applyPanelAppearance()
        subscribe()
        if geometry.hasCutout { panel.orderFrontRegardless() }
        let timer = Timer(timeInterval: 0.10, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.trackPointer() }
        }
        pointerTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }
    private func rootView() -> some View {
        NotchRootView().environmentObject(self).environmentObject(library).environmentObject(player).environmentObject(browser)
            .environmentObject(captions)
            .environment(\.locale, Locale(identifier: "en_US"))
    }
    private func installNotchContent() {
        if geometry.hasCutout {
            let hosting = NotchHostingView(rootView: rootView()); hosting.sizingOptions = []
            hosting.pointerChanged = { [weak self] in self?.trackPointer() }
            panel.contentView = NotchSurfaceView(content: hosting) { [weak self] bounds in
                let progress = self?.expansionProgress(for: bounds.height) ?? 0
                return NotchSilhouette(shoulder: Self.shoulder, bottomRadius: 12 + 10 * progress)
                    .path(in: bounds).cgPath
            }
        } else { panel.contentView = nil; panel.orderOut(nil) }
    }

    func showPlayer(focus: Bool = true) { page = .player; open(focus: focus) }
    func showSearch() { browser.showRecent(); browser.query = ""; page = .browse; open() }
    func showRSS() { page = .rss; open() }
    func showLoadedFeed() { activeWindow?.makeFirstResponder(nil); page = .browse; open() }
    func openShow(_ podcast: Podcast) { browser.open(podcast); page = .browse; open() }
    func scrollPosition(for key: String) -> Binding<String?> {
        Binding(get: { self.scrollPositions[key] }, set: { if let id = $0 { self.scrollPositions[key] = id } })
    }
    func play(_ episode: Episode) {
        if player.episode?.id != episode.id || !player.isPlaying { player.play(episode) }
        showPlayer()
    }
    /// Back to the start of the spoken sentence when captions exist; else 15s.
    func rewind() {
        if let start = captions.rewindTarget() { player.seek(start) } else { player.skip(-15) }
    }
    func tuck(animated: Bool = true) {
        cancelTuck(); hoverTask?.cancel(); hoverTask = nil
        browser.endSearchInput()
        presentation = .tucked
        // Explicit dismissal under the pointer must not immediately reopen.
        hoverRequiresExit = activationFrame.contains(NSEvent.mouseLocation)
        pointerInside = hoverRequiresExit
        isInteracting = false
        activeWindow?.makeFirstResponder(nil)
        // Retain the current surface until the closing spring has settled.
        applyPanelAppearance(); position(animated: animated)
        if panel.isKeyWindow { panel.resignKey() }
        if popover?.isShown == true { popover?.close() }
        if !geometry.hasCutout { page = .player }
    }
    func popoverDidClose(_ notification: Notification) {
        if presentation != .tucked { tuck(animated: false) }
    }
    func windowDidResignKey(_ notification: Notification) {
        if !menuTracking { scheduleTuck(force: true) }
    }
    private func open(focus: Bool = true, animated: Bool = false) {
        cancelTuck(); hoverTask?.cancel(); hoverTask = nil
        lastOpenedAt = Date()
        if page == .player || (page == .browse && browser.selected != nil) { activeWindow?.makeFirstResponder(nil) }
        presentation = .open
        applyPanelAppearance(); position(animated: animated)
        if geometry.hasCutout {
            if focus { panel.makeKeyAndOrderFront(nil) } else { panel.orderFrontRegardless() }
            trackPointer()
            if !pointerInside { scheduleTuck() }
        } else {
            // Defer until native status-menu tracking has finished.
            Task { @MainActor [weak self] in
                guard let self, self.presentation == .open, !self.geometry.hasCutout,
                      let button = self.statusItem?.button, button.window != nil else { return }
                if self.popover == nil {
                    let popover = NSPopover()
                    popover.delegate = self; popover.behavior = .transient; popover.animates = false
                    popover.contentViewController = NSHostingController(rootView: self.rootView())
                    self.popover = popover
                }
                self.applyPanelAppearance(); self.position(animated: false)
                if self.popover?.isShown != true {
                    self.popover?.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
                }
                if focus { self.activeWindow?.makeKey() }
            }
        }
    }
    func expansionProgress(for height: CGFloat) -> CGFloat {
        min(1, max(0, (height - tuckedHeight) / max(1, geometry.capHeight + detailHeight - tuckedHeight)))
    }
    // Intent regions use stable destination geometry, never the animated frame.
    // Transparent shoulders do not enlarge the closed activation target.
    private var activationFrame: NSRect {
        NSRect(x: geometry.centerX - triggerWidth / 2, y: geometry.top - triggerHeight,
               width: triggerWidth, height: triggerHeight)
    }
    private var retentionFrame: NSRect {
        let height = geometry.capHeight + detailHeight
        return NSRect(x: geometry.centerX - expandedWidth / 2, y: geometry.top - height,
                      width: expandedWidth, height: height)
            .insetBy(dx: -Self.retentionPadding, dy: -Self.retentionPadding)
    }
    private func targetFrame() -> NSRect {
        let height = presentation == .tucked ? tuckedHeight : geometry.capHeight + detailHeight
        let width = max(1, contentWidth + 2 * Self.shoulder)
        return NSRect(x: geometry.centerX - width / 2, y: geometry.top - height, width: width, height: height)
    }
    /// Retargets the spring (keeping velocity) only when the destination moved.
    private func reposition() {
        guard geometry.hasCutout else { position(animated: false); return }
        guard targetFrame() != lastTarget else { return }
        position(animated: true)
    }
    private func position(animated: Bool) {
        guard let panel else { return }
        // The strip is display-only: clicks under it reach the app beneath.
        // Hover still arrives through the pointer monitors and timer.
        panel.ignoresMouseEvents = presentation == .tucked && showsCaptionStrip
        lastTarget = targetFrame()
        guard geometry.hasCutout else {
            frameAnimator?.cancel(); panel.orderOut(nil)
            popover?.contentSize = NSSize(width: expandedWidth, height: detailHeight)
            return
        }
        frameAnimator.move(to: targetFrame(),
            animated: animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
            closing: presentation == .tucked) { [weak self] in
                guard let self, self.presentation == .tucked, self.page != .player else { return }
                self.page = .player
            }
    }
    private func refreshGeometry() {
        tuck(animated: false)
        geometry = NotchGeometry(screen: selectedScreen)
        pointerInside = false
        hoverRequiresExit = false
        popover = nil
        installNotchContent(); position(animated: false)
        if geometry.hasCutout { panel.orderFrontRegardless() }
    }
    private func trackPointer() {
        guard geometry.hasCutout, panel.isVisible else { return }
        let region = presentation == .tucked ? activationFrame : retentionFrame
        let inside = region.contains(NSEvent.mouseLocation)
        if presentation == .tucked, !inside { hoverRequiresExit = false }
        guard inside != pointerInside else { return }
        pointerInside = inside
        if inside {
            cancelTuck()
            if presentation == .tucked, !hoverRequiresExit {
                hoverTask?.cancel()
                hoverTask = Task { [weak self] in
                    try? await Task.sleep(nanoseconds: Self.hoverDelay)
                    guard !Task.isCancelled, let self, self.pointerInside, self.presentation == .tucked,
                          !self.hoverRequiresExit, !self.menuTracking, NSEvent.pressedMouseButtons == 0,
                          self.activationFrame.contains(NSEvent.mouseLocation) else { return }
                    self.page = .player
                    self.open(focus: false, animated: true)
                }
            }
        } else {
            hoverTask?.cancel(); hoverTask = nil
            if presentation == .open { scheduleTuck() }
        }
    }
    private func cancelTuck() { tuckTask?.cancel(); tuckTask = nil }
    private func scheduleTuck(force: Bool = false) {
        guard presentation == .open else { return }
        cancelTuck()
        tuckTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.departureDelay)
            while !Task.isCancelled && NSEvent.pressedMouseButtons != 0 {
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            guard !Task.isCancelled, let self, self.geometry.hasCutout, self.presentation == .open,
                  !self.menuTracking, !self.isInteracting, self.panel.attachedSheet == nil else { return }
            if !force {
                guard !self.retentionFrame.contains(NSEvent.mouseLocation),
                      !(self.activeWindow?.firstResponder is NSTextView) else { return }
            }
            self.tuck()
        }
    }
    private func subscribe() {
        // Track the 12pt grace region outside our window too. Mouse-only global
        // monitoring does not request Accessibility or intercept other apps' input.
        let pointerEvents: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged]
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: pointerEvents, handler: { [weak self] _ in
            Task { @MainActor in self?.trackPointer() }
        }) { pointerMonitors.append(monitor) }
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: pointerEvents, handler: { [weak self] event in
            self?.trackPointer()
            return event
        }) { pointerMonitors.append(monitor) }
        // Resize for video/error changes. @Published emits before assignment.
        player.$videoVisible.sink { [weak self] _ in Task { @MainActor in self?.position(animated: false) } }.store(in: &subscriptions)
        player.$error.sink { [weak self] _ in Task { @MainActor in self?.position(animated: false) } }.store(in: &subscriptions)
        player.$episode.sink { [weak self] _ in Task { @MainActor in self?.position(animated: false) } }.store(in: &subscriptions)
        // Captions resize on layout changes only, never on individual cues.
        Publishers.CombineLatest3(captions.$showsTuckedStrip, captions.$cues.map(\.isEmpty).removeDuplicates(),
                                  captions.$status.map { $0 == nil }.removeDuplicates())
            .combineLatest(captions.$mode)
            .dropFirst()
            // @Published emits before assignment; read the new layout next turn.
            .sink { [weak self] _ in DispatchQueue.main.async { self?.reposition() } }
            .store(in: &subscriptions)
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refreshGeometry() }
        })
        observers.append(center.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.menuTracking = true; self?.cancelTuck() }
        })
        observers.append(center.addObserver(forName: NSMenu.didEndTrackingNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                self?.menuTracking = false
                if let self, !self.pointerInside, Date().timeIntervalSince(self.lastOpenedAt) > 1 { self.scheduleTuck() }
            }
        })
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.activeWindow?.isKeyWindow == true, !self.menuTracking,
                  self.activeWindow?.attachedSheet == nil else { return event }
            let editor = self.activeWindow?.firstResponder as? NSTextView
            if editor?.hasMarkedText() == true { return event }
            if event.keyCode == 53 { self.tuck(animated: false); return nil }
            let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
            if modifiers == .command {
                switch event.charactersIgnoringModifiers?.lowercased() {
                case "k": self.showSearch(); return nil
                case "p": self.player.toggle(); return nil
                default: break
                }
                if self.page == .player, editor == nil {
                    if event.keyCode == 123 { self.rewind(); return nil }
                    if event.keyCode == 124 { self.player.skip(30); return nil }
                }
            }
            if self.page == .player, editor == nil, modifiers.isEmpty, event.keyCode == 49 {
                self.player.toggle(); return nil
            }
            return event
        }
    }
    private func applyPanelAppearance() {
        let dark = NSAppearance(named: .darkAqua)
        panel?.appearance = dark; popover?.appearance = dark
    }
    func menuNeedsUpdate(_ menu: NSMenu) {
        playMenuItem?.title = player.isPlaying ? "Pause" : "Play"
        playMenuItem?.isEnabled = player.episode != nil
        videoMenuItem?.isHidden = !player.hasVideo
        videoMenuItem?.title = player.videoVisible ? "Hide Video" : "Show Video"
        for item in captionItems { item.state = item.representedObject as? String == captions.mode.rawValue ? .on : .off }
        for item in speedItems { item.state = (item.representedObject as? NSNumber)?.floatValue == player.rate ? .on : .off }
    }
    private func createStatusItem() {
        let status = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        status.button?.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "Listen")
        status.button?.image?.isTemplate = true
        status.button?.toolTip = "Listen"
        let menu = NSMenu(); menu.delegate = self; menu.autoenablesItems = false
        menu.appearance = NSAppearance(named: .darkAqua)
        func item(_ title: String, _ action: Selector) -> NSMenuItem {
            let value = NSMenuItem(title: title, action: action, keyEquivalent: "")
            value.target = self; menu.addItem(value); return value
        }
        _ = item("Show Player", #selector(showPlayerAction))
        _ = item("Search Episodes & Shows…", #selector(searchAction))
        _ = item("Add RSS Feed…", #selector(rssAction))
        menu.addItem(.separator())
        playMenuItem = item("Play", #selector(playAction))
        videoMenuItem = item("Show Video", #selector(videoAction))
        let speedMenu = NSMenu()
        for rate in [Float(0.8), 1, 1.2, 1.5, 2] {
            let value = NSMenuItem(title: "\(rate.formatted())×", action: #selector(speedAction(_:)), keyEquivalent: "")
            value.target = self; value.representedObject = NSNumber(value: rate)
            speedMenu.addItem(value); speedItems.append(value)
        }
        let speedItem = NSMenuItem(title: "Playback Speed", action: nil, keyEquivalent: "")
        speedItem.submenu = speedMenu; menu.addItem(speedItem)
        let captionMenu = NSMenu()
        for mode in CaptionMode.allCases {
            let value = NSMenuItem(title: mode.title, action: #selector(captionAction(_:)), keyEquivalent: "")
            value.target = self; value.representedObject = mode.rawValue
            captionMenu.addItem(value); captionItems.append(value)
        }
        let captionItem = NSMenuItem(title: "Captions", action: nil, keyEquivalent: "")
        captionItem.submenu = captionMenu; menu.addItem(captionItem)
        menu.addItem(.separator())
        _ = item("Move to This Display", #selector(moveDisplayAction))
        menu.addItem(.separator())
        _ = item("Quit Listen", #selector(quitAction))
        status.menu = menu; statusItem = status
    }
    @objc private func showPlayerAction() { showPlayer() }
    @objc private func searchAction() { showSearch() }
    @objc private func rssAction() { showRSS() }
    @objc private func playAction() { player.toggle() }
    @objc private func videoAction() { player.toggleVideo() }
    @objc private func speedAction(_ sender: NSMenuItem) {
        if let value = sender.representedObject as? NSNumber { player.rate = value.floatValue }
    }
    @objc private func captionAction(_ sender: NSMenuItem) {
        if let raw = sender.representedObject as? String, let mode = CaptionMode(rawValue: raw) { captions.mode = mode }
    }
    @objc private func moveDisplayAction() {
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        screenID = screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        UserDefaults.standard.set(screenID, forKey: "notchDisplay")
        refreshGeometry(); showPlayer()
    }
    @objc private func quitAction() { NSApp.terminate(nil) }
    func shutdown() {
        presentation = .tucked
        frameAnimator?.cancel()
        browser.endSearchInput()
        pointerTimer?.invalidate(); pointerTimer = nil
        hoverTask?.cancel(); cancelTuck(); subscriptions.removeAll()
        captions.shutdown()
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        for monitor in pointerMonitors { NSEvent.removeMonitor(monitor) }
        pointerMonitors = []
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers = []
        popover?.delegate = nil; popover?.close()
        if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
        panel.orderOut(nil)
    }
}

private final class NotchPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}
