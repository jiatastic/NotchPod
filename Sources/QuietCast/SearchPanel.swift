import SwiftUI
import AppKit

struct SearchPanel: View {
    @EnvironmentObject private var browser: BrowserModel
    let height: CGFloat
    var width: CGFloat = 560
    var embedded = false
    let playEpisode: (Episode) -> Void
    let choose: (Podcast) -> Void
    let dismiss: () -> Void
    @State private var selection: String?
    @State private var keyboardTarget: String?

    private var showsLibrary: Bool { browser.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private var rows: [PodcastSearchResult] { browser.searchResults }
    private var keyboardHint: String {
        if browser.resolvingEpisodeID != nil { return "Opening episode…" }
        // The spinner in the field already says "searching"; don't repeat it.
        guard browser.resultsAreCurrent, let row = rows.first(where: { $0.id == selection }) ?? rows.first else { return "" }
        if case .episode = row { return "↑ ↓ · Return to play" }
        return "↑ ↓ · Return to open"
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").font(.system(size: 14, weight: .medium)).foregroundStyle(Palette.secondary)
                SearchInput(text: $browser.query, submit: submit, move: move, dismiss: dismiss,
                            compositionChanged: browser.setSearchComposition)
                    .frame(height: 24).accessibilityLabel("Search episodes or shows")
                if browser.searching { ProgressView().controlSize(.small) }
                Button(action: dismiss) {
                    Image(systemName: "xmark").font(.system(size: 11, weight: .semibold)).foregroundStyle(Palette.secondary)
                        .frame(width: 22, height: 22).background(Palette.hover, in: Circle()).contentShape(Circle())
                }.buttonStyle(PressableStyle()).keyboardShortcut(.cancelAction).accessibilityLabel("Close search")
            }.padding(.horizontal, Metrics.gutter).padding(.vertical, 16)
            Rectangle().fill(Palette.separator).frame(height: 1)
            if !showsLibrary {
                HStack {
                    Spacer()
                    Text(keyboardHint).font(.system(size: 11)).foregroundStyle(Palette.tertiary)
                }.frame(height: 14).padding(.horizontal, Metrics.gutter).padding(.top, 12).padding(.bottom, 4)
            }
            if let warning = browser.searchWarning, !showsLibrary {
                HStack(spacing: 8) {
                    Text(warning).font(.system(size: 11)).foregroundStyle(Palette.secondary)
                    Spacer(minLength: 0)
                    Button("Retry") { browser.search() }.font(.system(size: 11)).buttonStyle(.plain)
                }.padding(.horizontal, Metrics.gutter).padding(.vertical, 6)
            }
            if let error = browser.episodePlaybackError, !showsLibrary {
                Text(error).font(.system(size: 11)).foregroundStyle(Palette.secondary).lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, Metrics.gutter).padding(.vertical, 6)
            }
            if showsLibrary {
                SearchLibraryHome(choose: choose, play: playEpisode)
            } else if let error = browser.error {
                VStack(spacing: 12) {
                    Text(error).font(.system(size: 12)).foregroundStyle(Palette.secondary).multilineTextAlignment(.center)
                    Button("Try again") { browser.search() }.font(.system(size: 12, weight: .medium)).buttonStyle(PressableStyle())
                }.padding(Metrics.gutter).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if rows.isEmpty {
                VStack(spacing: 6) {
                    if !browser.searching && browser.resultsAreCurrent {
                        Text("No results").font(.system(size: 14, weight: .medium))
                        Text("Try another title or keyword.")
                            .font(.system(size: 12)).foregroundStyle(Palette.secondary)
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(rows) { item in
                                if case .episode(let hit) = item, hit.id == browser.episodeResults.first?.id { section("Episodes") }
                                if case .show(let show) = item, show.id == browser.results.first?.id { section("Shows") }
                                result(item).id(item.id)
                            }
                        }.padding(.horizontal, Metrics.gutter - Metrics.rowInset).padding(.bottom, 14)
                    }
                    .onChange(of: keyboardTarget) { _, id in
                        if let id { proxy.scrollTo(id, anchor: .center) }
                    }
                    .onChange(of: browser.resultsAreCurrent) { _, current in
                        if current, let first = rows.first { proxy.scrollTo(first.id, anchor: .top) }
                    }
                }
            }
        }
        .frame(width: width, height: height)
        .background(embedded ? Color.clear : Palette.surface).foregroundStyle(Palette.text)
        .clipShape(RoundedRectangle(cornerRadius: embedded ? 0 : 10))
        .overlay { RoundedRectangle(cornerRadius: embedded ? 0 : 10).strokeBorder(embedded ? .clear : Palette.separator, lineWidth: 1) }
        .shadow(color: embedded ? .clear : .black.opacity(0.14), radius: embedded ? 0 : 18, y: embedded ? 0 : 8)
        .onExitCommand(perform: dismiss)
        .onAppear {
            selection = browser.resultsAreCurrent ? rows.first?.id : nil
            if !browser.resultsAreCurrent { browser.scheduleSearch() }
        }
        .onChange(of: browser.resultsAreCurrent) { _, current in
            selection = current ? rows.first?.id : nil; keyboardTarget = nil
        }
        .onDisappear { browser.endSearchInput() }
        // Search/keyboard actions are frequent: no animated result churn.
        .transaction { $0.animation = nil; $0.disablesAnimations = true }
    }

    private func section(_ title: String) -> some View {
        Text(title).font(.system(size: 11, weight: .medium)).foregroundStyle(Palette.tertiary)
            .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, Metrics.rowInset).padding(.top, 14).padding(.bottom, 4)
    }
    private func result(_ item: PodcastSearchResult) -> some View {
        Button { activate(item) } label: {
            NotchRow(title: item.title, detail: item.subtitle, symbol: item.symbol, busy: item.episodeID != nil && item.episodeID == browser.resolvingEpisodeID) {
                Artwork(url: item.artworkURL, size: 40)
            }
        }.buttonStyle(RowStyle(selected: selection == item.id)).disabled(!browser.resultsAreCurrent)
            .opacity(browser.resultsAreCurrent ? 1 : 0.5)
            .onHover { if $0, browser.resultsAreCurrent { selection = item.id; keyboardTarget = nil } }
            .accessibilityValue(selection == item.id ? "Selected" : "")
            .help(item.title)
    }
    private func activate(_ item: PodcastSearchResult) {
        guard browser.resultsAreCurrent else { return }
        switch item {
        case .episode(let hit): browser.playSearchEpisode(hit, play: playEpisode)
        case .show(let show): browser.cancelEpisodeResolution(); choose(show)
        }
    }
    private func submit() {
        guard !showsLibrary else { return }
        if browser.resultsAreCurrent, let row = rows.first(where: { $0.id == selection }) ?? rows.first {
            activate(row)
        } else if !browser.searching { browser.search() }
    }
    private func move(_ delta: Int) {
        guard browser.resultsAreCurrent, !rows.isEmpty else { return }
        let index = rows.firstIndex { $0.id == selection } ?? (delta > 0 ? -1 : rows.count)
        let next = min(max(index + delta, 0), rows.count - 1)
        selection = rows[next].id
        keyboardTarget = selection
    }
}

private extension PodcastSearchResult {
    var title: String {
        switch self { case .episode(let hit): return hit.title; case .show(let show): return show.title }
    }
    var subtitle: String {
        switch self {
        case .episode(let hit): return [hit.showTitle, minutes(hit.duration)].compactMap { $0 }.joined(separator: " · ")
        case .show(let show): return show.author
        }
    }
    var artworkURL: URL? {
        switch self { case .episode(let hit): return hit.artworkURL; case .show(let show): return show.artworkURL }
    }
    var episodeID: String? {
        if case .episode(let hit) = self { return hit.id }
        return nil
    }
    var symbol: String {
        switch self { case .episode: return "play.fill"; case .show: return "chevron.right" }
    }
}

// The single search entry also holds following and recent listening.
private struct SearchLibraryHome: View {
    let choose: (Podcast) -> Void
    let play: (Episode) -> Void
    @EnvironmentObject private var library: Library

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                if library.podcasts.isEmpty && library.recent.isEmpty {
                    Text("Find your next listen.").font(.system(size: 13)).foregroundStyle(Palette.secondary)
                        .padding(.horizontal, Metrics.rowInset).padding(.top, 20)
                }
                if !library.podcasts.isEmpty {
                    header("Following")
                    ForEach(library.podcasts) { show in
                        Button { choose(show) } label: {
                            NotchRow(title: show.title, detail: show.author.isEmpty ? nil : show.author, symbol: "chevron.right") {
                                Artwork(url: show.artworkURL, size: 40)
                            }
                        }.buttonStyle(RowStyle())
                            .contextMenu { Button("Unfollow", role: .destructive) { library.toggle(show) } }
                    }
                }
                if !library.recent.isEmpty {
                    header("Recent")
                    ForEach(library.recent.prefix(12), id: \.episode.id) { record in
                        Button { play(record.episode) } label: {
                            NotchRow(title: record.episode.title, detail: record.episode.podcast.title) {
                                Artwork(url: record.episode.artworkURL, fallbackURL: record.episode.podcast.artworkURL, size: 40)
                            }
                        }.buttonStyle(RowStyle())
                    }
                }
            }.padding(.horizontal, Metrics.gutter - Metrics.rowInset).padding(.bottom, 14)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    private func header(_ title: String) -> some View {
        Text(title).font(.system(size: 11, weight: .medium)).foregroundStyle(Palette.tertiary)
            .padding(.horizontal, Metrics.rowInset).padding(.top, 14).padding(.bottom, 4)
    }
}

// Marked text is published for display but never sent to the directory until
// composition commits. Arrows/Return still belong to the IME while it is active.
private struct SearchInput: NSViewRepresentable {
    @Binding var text: String
    let submit: () -> Void
    let move: (Int) -> Void
    let dismiss: () -> Void
    let compositionChanged: (Bool) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> SearchTextField {
        let field = SearchTextField(string: text)
        field.isBordered = false; field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 15)
        field.textColor = .labelColor
        field.placeholderString = "Search episodes or shows"
        field.delegate = context.coordinator
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return field
    }
    func updateNSView(_ field: SearchTextField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text { field.stringValue = text }
    }
    static func dismantleNSView(_ field: SearchTextField, coordinator: Coordinator) {
        coordinator.stopCompositionTracking()
    }
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: SearchInput
        private var compositionTask: Task<Void, Never>?
        init(_ parent: SearchInput) { self.parent = parent }
        func stopCompositionTracking() { compositionTask?.cancel(); compositionTask = nil }
        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            let marked = (field.currentEditor() as? NSTextView)?.hasMarkedText() == true
            parent.compositionChanged(marked)
            parent.text = field.stringValue
            stopCompositionTracking()
            guard marked else { return }
            // Committing the same marked string may not emit another text-change
            // notification. Watch only during composition so it cannot get stuck.
            compositionTask = Task { @MainActor [weak self, weak field] in
                while !Task.isCancelled {
                    do { try await Task.sleep(nanoseconds: 50_000_000) } catch { return }
                    guard let field, field.window != nil,
                          let editor = field.currentEditor() as? NSTextView else { return }
                    if !editor.hasMarkedText() {
                        self?.parent.compositionChanged(false)
                        self?.parent.text = field.stringValue
                        return
                    }
                }
            }
        }
        func controlTextDidEndEditing(_ notification: Notification) {
            stopCompositionTracking()
            parent.compositionChanged(false)
            if let field = notification.object as? NSTextField { parent.text = field.stringValue }
        }
        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            guard !textView.hasMarkedText() else { return false }
            switch commandSelector {
            case #selector(NSResponder.moveDown(_:)): parent.move(1)
            case #selector(NSResponder.moveUp(_:)): parent.move(-1)
            case #selector(NSResponder.insertNewline(_:)): parent.submit()
            case #selector(NSResponder.cancelOperation(_:)): parent.dismiss()
            default: return false
            }
            return true
        }
    }
}

private final class SearchTextField: NSTextField {
    private var didFocus = false
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil, !didFocus else { return }
        didFocus = true
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window else { return }
            window.makeFirstResponder(self)
            self.selectText(nil)
        }
    }
}
