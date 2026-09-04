import AppKit
import SwiftUI

enum LibraryLayout: String {
    case grid, list
}

/// Numbers the header, body and footer share, so the three bands sit on the
/// same left and right edges and the grid keeps a usable tile size at every
/// window width.
private enum LibraryMetrics {
    static let inset: CGFloat = 18
    static let headerRow: CGFloat = 30
    static let tileMinimum: CGFloat = 148
    static let gridSpacing: CGFloat = 12
    static let idealBodyHeight: CGFloat = 500
    static let searchLimit = 200
}

/// Screen 1d: every screenshot the store knows about, bucketed by day, with
/// Finder-style multi-select and a footer that acts on the selection. The
/// only place a user can pin a screenshot or copy several files at once.
struct LibraryView: View {
    @Environment(ScreenshotStore.self) private var store
    @Environment(SettingsStore.self) private var settings

    /// `AICoordinator` is not `@Observable` itself, so it is passed rather
    /// than read from the environment; the queue and index inside it are,
    /// which is what makes the row badges refresh.
    var ai: AICoordinator?

    @State private var selection = LibrarySelection()
    @State private var search: AIDropdownModel
    @State private var isSearching = false
    @Namespace private var dragNamespace
    @AppStorage("libraryLayout") private var layout: LibraryLayout = .grid

    init(ai: AICoordinator?) {
        self.ai = ai
        _search = State(initialValue: Self.searchModel(ai: ai))
    }

    /// The dropdown's search model, with the Library's own limit: a browse
    /// window filters to everything that matches, where the dropdown shows
    /// the best few.
    private static func searchModel(ai: AICoordinator?) -> AIDropdownModel {
        guard let ai else { return AIDropdownModel { _, _, _ in [] } }
        let semantic = ai.makeSearch()
        return AIDropdownModel { query, shots, _ in
            await semantic.search(query, in: shots, limit: LibraryMetrics.searchLimit)
        }
    }

    private var days: [ScreenshotDay] {
        searchedDays(store.days, query: search.query, semanticIDs: isSemantic ? Set(search.matches.map(\.id)) : [])
    }

    /// Substring only when AI is off: there are no embeddings to search and
    /// `SemanticSearch` would fall back to the same rule anyway.
    private var isSemantic: Bool {
        ai != nil && settings.aiEnabled && !search.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var visibleIDs: [URL] {
        days.flatMap(\.shots).map(\.id)
    }

    private var selectedShots: [Screenshot] {
        selection.selected(from: days)
    }

    var body: some View {
        ZStack(alignment: .top) {
            Theme.glassBackground(radius: Theme.Radius.window)

            VStack(spacing: 0) {
                LibraryToolbar(query: $search.query, layout: $layout)

                if days.isEmpty {
                    LibraryEmptyState(
                        storeEmpty: store.days.isEmpty,
                        query: search.query,
                        isSearching: isSearching,
                        folderName: settings.captureFolder.lastPathComponent
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 14) {
                            ForEach(days) { day in
                                LibraryDaySection(
                                    day: day,
                                    layout: layout,
                                    ai: ai,
                                    dragNamespace: dragNamespace,
                                    selection: $selection,
                                    visibleIDs: visibleIDs,
                                    allDays: days,
                                    onCopy: copySelection,
                                    onSetPinned: { pinned, urls in store.setPinned(pinned, for: urls) },
                                    onReveal: reveal,
                                    onTrash: trashSelection
                                )
                            }
                        }
                        .padding(.horizontal, LibraryMetrics.inset)
                        .padding(.top, 12)
                        .padding(.bottom, 18)
                    }
                    // The single-id form, so how many files a drag carries is
                    // decided by `dragPayload` and can be tested; the
                    // selection is declared as well so the drag preview
                    // stacks and counts the way the system's own do.
                    .dragContainer(for: DraggedScreenshot.self, in: dragNamespace) { (draggedID: URL) in
                        dragPayload(for: draggedID, selection: selection.ids, in: days)
                    }
                    .dragContainerSelection(selectedShots.map(\.id), containerNamespace: dragNamespace)
                    // The window takes its opening height from the hosting
                    // view's fittingSize, which measures with no width to
                    // spare and so lays the grid out one tile per row. A
                    // fixed ideal keeps that measurement off the content.
                    .frame(idealHeight: LibraryMetrics.idealBodyHeight)

                    if !selectedShots.isEmpty {
                        LibraryFooter(
                            shots: selectedShots,
                            onShare: share,
                            onTrash: { trashSelection(selectedShots.map(\.id)) },
                            onCopy: { copySelection(selectedShots.map(\.id)) }
                        )
                    }
                }
            }

            Button("") { selection.selectAll(visibleIDs) }
                .keyboardShortcut("a", modifiers: .command)
                .opacity(0)
                .frame(width: 0, height: 0)
        }
        .ignoresSafeArea()
        .frame(minWidth: Theme.Metrics.libraryWidth, minHeight: 400)
        .onExitCommand { selection.ids = [] }
        .task { search.allShots = store.shots }
        .onChange(of: store.days.flatMap(\.shots).map(\.id)) { _, ids in
            selection.prune(keeping: Set(ids))
            search.allShots = store.shots
        }
        // Long enough to cover the model's debounce and the embedding call,
        // so a query the file names don't match shows "Searching…" instead
        // of flashing "No matches" at every keystroke.
        .task(id: search.query) {
            guard isSemantic else {
                isSearching = false
                return
            }
            isSearching = true
            try? await Task.sleep(for: .milliseconds(700))
            isSearching = false
        }
    }

    // MARK: - Actions

    /// A file trashed or renamed underneath the library is still in the store
    /// until the watcher rescans, so a copy can fail on a row the user can see.
    /// Saying so beats a Cmd-V that pastes whatever was on the pasteboard before.
    private func copySelection(_ urls: [URL]) {
        guard !urls.isEmpty, !Clipboard.copyImages(urls) else { return }
        presentAlert(
            title: urls.count == 1 ? "Couldn't copy the screenshot" : "Couldn't copy the screenshots",
            message: "One of the files couldn't be read. It may have been moved or deleted."
        )
    }

    private func reveal(_ urls: [URL]) {
        if urls.count == 1, let url = urls.first {
            ScreenshotActions.revealInFinder(url)
        } else if !urls.isEmpty {
            NSWorkspace.shared.activateFileViewerSelecting(urls)
        }
    }

    /// Trashes exactly the urls passed in — always the current selection,
    /// never anything beyond it — via `ScreenshotActions.trash`, which uses
    /// `FileManager.trashItem`. On success the trashed urls drop out of the
    /// selection; on a thrown error (including a partial batch failure) the
    /// selection is left untouched and nothing is removed from the store,
    /// so any files `trash` already moved before the failure stay selected
    /// until the folder watcher's next rescan notices they're gone and
    /// `prune(keeping:)` drops them.
    private func trashSelection(_ urls: [URL]) {
        do {
            try ScreenshotActions.trash(urls)
            store.remove(urls)
            selection.ids.subtract(urls)
        } catch {
            presentAlert(title: "Couldn't move to Trash", message: error.localizedDescription)
        }
    }

    private func share(from anchor: NSView) {
        let picker = NSSharingServicePicker(items: selectedShots.map(\.url))
        picker.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
    }

    private func presentAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.runModal()
    }
}

/// Title, centered search field, grid/list toggle, on their own row below
/// the traffic lights.
private struct LibraryToolbar: View {
    @Binding var query: String
    @Binding var layout: LibraryLayout

    var body: some View {
        HStack(spacing: 12) {
            Text("Shotput Library")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.label)

            Spacer(minLength: 16)

            Picker("Layout", selection: $layout) {
                Image(systemName: "square.grid.2x2.fill").tag(LibraryLayout.grid)
                Image(systemName: "list.bullet").tag(LibraryLayout.list)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
        }
        .frame(height: LibraryMetrics.headerRow)
        .padding(.horizontal, LibraryMetrics.inset)
        // Centred on the window rather than on the row, so the title and the
        // toggle can change width without dragging the field off centre.
        .overlay { searchField }
        // The window draws no title bar of its own, so the row has to start
        // below the traffic lights (bottom edge at 23pt).
        .padding(.top, 28)
        .padding(.bottom, 10)
        .overlay(Divider(), alignment: .bottom)
    }

    private var searchField: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(Theme.secondary(0.55))
            TextField("Search screenshots", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
        }
        .popupChrome()
        .frame(width: 280)
    }
}

/// One day bucket: header, then the grid or list of its shots.
private struct LibraryDaySection: View {
    let day: ScreenshotDay
    let layout: LibraryLayout
    let ai: AICoordinator?
    let dragNamespace: Namespace.ID
    @Binding var selection: LibrarySelection
    let visibleIDs: [URL]
    let allDays: [ScreenshotDay]
    let onCopy: ([URL]) -> Void
    let onSetPinned: (Bool, [URL]) -> Void
    let onReveal: ([URL]) -> Void
    let onTrash: ([URL]) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(day.label)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(Theme.label)
                Text(day.countText)
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.secondary(0.5))
            }

            if layout == .grid {
                LazyVGrid(columns: Self.columns, spacing: LibraryMetrics.gridSpacing) {
                    ForEach(day.shots) { shot in
                        LibraryTile(shot: shot, isSelected: selection.ids.contains(shot.id), ai: ai)
                            .draggable(containerItemID: shot.id, containerNamespace: dragNamespace)
                            .onTapGesture { click(shot.id) }
                            .contextMenu { contextMenu(for: shot) }
                    }
                }
            } else {
                LazyVStack(spacing: 2) {
                    ForEach(day.shots) { shot in
                        LibraryRow(shot: shot, isSelected: selection.ids.contains(shot.id), ai: ai)
                            .draggable(containerItemID: shot.id, containerNamespace: dragNamespace)
                            .onTapGesture { click(shot.id) }
                            .contextMenu { contextMenu(for: shot) }
                    }
                }
            }
        }
    }

    /// Adaptive rather than a fixed five columns: fixed columns stretch each
    /// tile as the window widens, and the thumbnail only gets more letterboxed.
    /// A minimum width adds a column instead and keeps tiles 148-160 wide.
    private static let columns = [
        GridItem(.adaptive(minimum: LibraryMetrics.tileMinimum), spacing: LibraryMetrics.gridSpacing, alignment: .topLeading)
    ]

    private func click(_ id: URL) {
        let modifiers = NSApp.currentEvent?.modifierFlags ?? []
        selection.click(id, in: visibleIDs, modifiers: modifiers)
    }

    /// `contextMenu`'s content closure is the only hook SwiftUI runs before
    /// the menu opens, so the "right-click an unselected tile selects it
    /// first" rule has to live in this `let _ =` side effect rather than a
    /// gesture handler.
    @ViewBuilder
    private func contextMenu(for shot: Screenshot) -> some View {
        let _ = selectForMenu(shot.id)
        let shots = selection.selected(from: allDays)
        let urls = shots.map(\.id)
        let allPinned = !shots.isEmpty && shots.allSatisfy(\.isPinned)

        Button(shots.count > 1 ? "Copy \(shots.count)" : "Copy") {
            onCopy(urls)
        }
        Button(pinMenuLabel(for: shots)) {
            onSetPinned(!allPinned, urls)
        }
        Button("Reveal in Finder") {
            onReveal(urls)
        }
        if let ai {
            switch AIRowStatus(state: ai.state(for: shot.url)).action {
            case .none:
                EmptyView()
            case .reindex:
                Divider()
                Button(reindexMenuLabel(count: shots.count)) {
                    for url in urls { ai.reindex(url) }
                }
            case .retry:
                Divider()
                // Only the given-up ones: `retry` on a described screenshot
                // would describe it again behind a row that still reads as
                // described.
                let failed = urls.filter { if case .gaveUp = ai.state(for: $0) { return true } else { return false } }
                Button(retryMenuLabel(count: failed.count)) {
                    for url in failed { ai.retry(url) }
                }
            }
        }
        Button("Move to Trash") {
            onTrash(urls)
        }
    }

    private func selectForMenu(_ id: URL) {
        guard !selection.ids.contains(id) else { return }
        selection.click(id, in: visibleIDs, modifiers: [])
    }
}

/// Selection-count/size on the left, Share…/Move to Trash/Copy N pills on
/// the right. Rendered only while the selection is non-empty.
private struct LibraryFooter: View {
    let shots: [Screenshot]
    let onShare: (NSView) -> Void
    let onTrash: () -> Void
    let onCopy: () -> Void

    @State private var shareAnchor: NSView?

    var body: some View {
        let parts = footerParts(for: shots)

        HStack(spacing: 12) {
            HStack(spacing: 0) {
                Text(parts.count).fontWeight(.bold)
                Text(" · \(parts.size)")
            }
            .font(.system(size: 11.5))
            .foregroundStyle(Theme.secondary(0.65))

            Spacer(minLength: 12)

            GlassEffectContainer(spacing: 8) {
                HStack(spacing: 8) {
                    PillButton(title: "Share…", height: 26, fontSize: 11.5, weight: .medium) {
                        if let shareAnchor {
                            onShare(shareAnchor)
                        }
                    }
                    // A background takes the pill's own frame, where a stacked
                    // sibling would grow to fill the footer and drag the pill
                    // away from the other two; the picker's popover anchors here.
                    .background(ViewResolver(resolve: { $0 }, onChange: { shareAnchor = $0 }))

                    PillButton(title: "Move to Trash", height: 26, fontSize: 11.5, weight: .medium, action: onTrash)
                    PillButton(
                        title: "Copy \(shots.count)",
                        systemImage: "doc.on.doc",
                        prominent: true,
                        height: 26,
                        fontSize: 11.5,
                        action: onCopy
                    )
                }
            }
        }
        .padding(.horizontal, LibraryMetrics.inset)
        .padding(.vertical, 10)
        .background(.quinary)
        .topHairline()
    }
}

/// Centered "No screenshots…"/"No matches…" message shown when there's
/// nothing to display; neither case renders the footer.
private struct LibraryEmptyState: View {
    let storeEmpty: Bool
    let query: String
    let isSearching: Bool
    let folderName: String

    var body: some View {
        VStack(spacing: 6) {
            Text(title)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(Theme.label)
            if storeEmpty {
                Text("Press ⇧⌘4 and it will show up here.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.secondary(0.5))
            }
        }
    }

    private var title: String {
        if storeEmpty { return "No screenshots in \(folderName)" }
        return isSearching ? "Searching…" : "No matches for \u{201c}\(query)\u{201d}"
    }
}
