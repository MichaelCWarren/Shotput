import AppKit
import SwiftUI
import Combine

enum DropdownRowStyle {
    case list
    case ai
}

struct DropdownView: View {
    let model: DropdownModel
    var ai: AICoordinator?

    @State private var aiModel: AIDropdownModel
    @FocusState private var focused: Bool
    @FocusState private var searchFocused: Bool

    init(model: DropdownModel, ai: AICoordinator? = nil) {
        self.model = model
        self.ai = ai
        _aiModel = State(initialValue: AIDropdownModel(ai: ai))
    }

    // Computed, not stored: `panel.rootView` is assigned once in
    // `ShotputApp.init()`, so this has to re-read `model.aiEnabled` on every
    // body evaluation for the toggle to take effect without reopening.
    private var rowStyle: DropdownRowStyle {
        model.aiEnabled ? .ai : .list
    }

    private var aiSections: [AIDropdownSection] {
        AIDropdownModel.sections(
            days: model.days,
            matches: aiModel.matches,
            query: aiModel.query,
            state: { [ai] url in ai?.state(for: url) ?? .off }
        )
    }

    // Row ids in the order they are drawn, so ↑ ↓ walk the matches section
    // before the day rows. A screenshot rendered twice (as a match and again
    // under ALL · …) is kept only at its first position: `moveUp`/`moveDown`
    // look ids up by first index, so a repeat would trap the walk in a loop.
    private func rowIDs(sections: [AIDropdownSection], shots: [Screenshot]) -> [Screenshot.ID] {
        let rendered = rowStyle == .ai
            ? sections.flatMap { $0.rows.map(\.id) }
            : shots.map(\.id)
        var seen = Set<Screenshot.ID>()
        return rendered.filter { seen.insert($0).inserted }
    }

    var body: some View {
        let shots = model.days.flatMap(\.shots)
        // Sectioning is the AI path's work alone; list mode must not pay for it.
        let sections = rowStyle == .ai ? aiSections : []

        VStack(spacing: 0) {
            header

            if model.days.isEmpty {
                VStack(spacing: 8) {
                    Text("No screenshots yet")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.label)
                    Text("Press ⇧⌘4 to take one")
                        .font(.system(size: 10.5))
                        .foregroundStyle(Theme.secondary(0.55))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.vertical, 28)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(spacing: 2) {
                            if rowStyle == .ai {
                                ForEach(sections) { section in
                                    sectionLabel(text: section.label)
                                    ForEach(section.rows) { item in
                                        aiRow(for: item)
                                    }
                                }
                            } else {
                                ForEach(Array(model.days.enumerated()), id: \.element.id) { index, day in
                                    sectionLabel(for: day, isFirst: index == 0)
                                    ForEach(day.shots) { shot in
                                        row(for: shot)
                                    }
                                }
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 4)
                        .padding(.bottom, 2)
                    }
                    .frame(maxHeight: 420)
                    .onChange(of: model.selection.selectedID) { _, newValue in
                        if let newValue {
                            withAnimation {
                                proxy.scrollTo(newValue)
                            }
                        }
                    }
                }

                if rowStyle == .ai, let ai {
                    AIStatusFooter(ai: ai)
                } else {
                    DropdownFooter.keyHints()
                }
            }

            DropdownFooter.cleanup(text: model.footerText, onOpenLibrary: model.openLibrary)
        }
        .frame(width: Theme.Metrics.dropdownWidth)
        .glassEffect(.regular, in: .rect(cornerRadius: Theme.Radius.dropdown))
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.dropdown))
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onAppear {
            focused = true
            aiModel.allShots = model.shots
        }
        .onDisappear {
            aiModel.query = ""
        }
        .onKeyPress(phases: .down) { press in
            if let key = DropdownKey.action(key: press.key, modifiers: press.modifiers) {
                model.handle(key)
                return .handled
            }
            return .ignored
        }
        .onChange(of: rowIDs(sections: sections, shots: shots), initial: true) { _, newValue in
            model.reconcile(ids: newValue)
        }
        // Keyed on the screenshots, not their ids: a description arriving from
        // the queue mutates title/summary without changing any id. Array's ==
        // short-circuits on an unchanged buffer, so the whole store here costs
        // a pointer compare per render.
        .onChange(of: model.shots) { _, newValue in
            aiModel.allShots = newValue
        }
    }

    @ViewBuilder
    private var header: some View {
        DropdownHeader(countText: model.countText, onSettings: model.openSettings)

        // Shown for as long as AI is on rather than revealed by a button, so
        // the field is the one way in and Settings keeps the header to itself.
        if rowStyle == .ai {
            SemanticSearchField(
                query: $aiModel.query,
                focused: $searchFocused,
                // The field clears itself and resigns first; this hands focus
                // back to the container so a second Escape, and the arrows,
                // still land. SwiftUI does not re-home focus on its own when a
                // TextField resigns.
                onEscape: { focused = true },
                onKey: model.handle
            )
        }
    }

    @ViewBuilder
    private func sectionLabel(for day: ScreenshotDay, isFirst: Bool) -> some View {
        let label = SectionLabel(text: day.label.uppercased())
        if isFirst {
            label
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .padding(.bottom, 4)
        } else {
            label
                .padding(.horizontal, 6)
                .padding(.vertical, 8)
                .padding(.bottom, 4)
        }
    }

    @ViewBuilder
    private func sectionLabel(text: String) -> some View {
        // 1b's section headers use fixed top padding rather than the
        // first/rest split above: MATCHES/NO MATCHES sit right under the
        // search field, ALL · sections get more breathing room.
        let topPadding: CGFloat = text.contains("MATCH") ? 2 : 10
        SectionLabel(text: text)
            .padding(.horizontal, 6)
            .padding(.top, topPadding)
            .padding(.bottom, 4)
    }

    @ViewBuilder
    private func row(for shot: Screenshot) -> some View {
        ScreenshotRow(
            shot: shot,
            meta: model.meta(for: shot),
            isHighlighted: shot.id == model.hoveredID || shot.id == model.selection.selectedID,
            isCopied: shot.id == model.copiedID,
            onCopy: { model.copy(shot) },
            onCopyText: { Task { await model.copyText(shot) } },
            onAnnotate: { model.annotate(shot) }
        )
        .onHover { hovering in
            model.hoveredID = hovering ? shot.id : (model.hoveredID == shot.id ? nil : model.hoveredID)
        }
    }

    @ViewBuilder
    private func aiRow(for item: AIRowItem) -> some View {
        let shot = item.screenshot
        AIScreenshotRow(
            item: item,
            isHighlighted: shot.id == model.hoveredID || shot.id == model.selection.selectedID,
            isCopied: shot.id == model.copiedID,
            onCopy: { model.copy(shot) },
            onCopyText: { Task { await model.copyText(shot) } },
            onAnnotate: { model.annotate(shot) },
            onReindex: { [ai] in ai?.reindex(shot.url) },
            onRetry: { [ai] in ai?.retry(shot.url) }
        )
        .onHover { hovering in
            model.hoveredID = hovering ? shot.id : (model.hoveredID == shot.id ? nil : model.hoveredID)
        }
    }
}

@MainActor
@Observable
final class DropdownModel {
    private let store: ScreenshotStore
    private let settings: SettingsStore
    private let cleanup: CleanupScheduler
    private let windows: WindowManager
    private let previewer = QuickLookPreviewer()
    private let dismissClosure: () -> Void
    private let flash = CopiedFlash()

    var selection: DropdownSelection = DropdownSelection(ids: [])

    var days: [ScreenshotDay] {
        Self.visibleDays(store.days)
    }

    // The row list stops at two days; semantic search does not, so it reads
    // the whole store instead of `days`.
    var shots: [Screenshot] { store.shots }

    var countText: String { store.countText }
    var footerText: String { cleanup.footerText }
    var cleanupInterval: CleanupInterval { settings.cleanupInterval }
    var aiEnabled: Bool { settings.aiEnabled }

    var hoveredID: Screenshot.ID?
    var copiedID: Screenshot.ID? { flash.copiedID }

    /// Looks in `shots`, not `days`: an AI match row can be a screenshot
    /// older than the two days the plain list stops at, and keyboard copy
    /// reads the focused shot from here.
    var focusedShot: Screenshot? {
        guard let id = selection.selectedID ?? hoveredID else { return nil }
        return shots.first { $0.id == id }
    }

    init(
        store: ScreenshotStore,
        settings: SettingsStore,
        cleanup: CleanupScheduler,
        windows: WindowManager,
        dismiss: @escaping () -> Void
    ) {
        self.store = store
        self.settings = settings
        self.cleanup = cleanup
        self.windows = windows
        self.dismissClosure = dismiss
    }

    func meta(for shot: Screenshot) -> String {
        shot.metaText(cleanup: cleanupInterval)
    }

    func copy(_ shot: Screenshot) {
        if Clipboard.copyImages([shot.url]) {
            flash.markCopied(shot.id)
        } else {
            NSSound.beep()
        }
    }

    func copyText(_ shot: Screenshot) async {
        do {
            let text = try await OCR.recognizeText(in: shot.url)
            if !text.isEmpty {
                Clipboard.copyText(text)
                flash.markCopied(shot.id)
            } else {
                NSSound.beep()
            }
        } catch {
            NSSound.beep()
        }
    }

    func annotate(_ shot: Screenshot) {
        close()
        ScreenshotActions.annotate(shot.url)
    }

    func preview(_ shot: Screenshot) {
        previewer.toggle(shot.url)
    }

    func openLibrary() {
        close()
        windows.show(.library)
    }

    func openSettings() {
        close()
        windows.show(.settings)
    }

    func close() {
        previewer.close()
        dismissClosure()
    }

    func handle(_ key: DropdownKey) {
        switch key {
        case .up:
            selection.moveUp()
        case .down:
            selection.moveDown()
        case .copy:
            if let shot = focusedShot {
                copy(shot)
            }
        case .copyText:
            if let shot = focusedShot {
                Task { await copyText(shot) }
            }
        case .preview:
            if let shot = focusedShot {
                preview(shot)
            }
        case .close:
            close()
        }
    }

    func reconcile(ids: [Screenshot.ID]) {
        selection.reconcile(ids: ids)
    }

    nonisolated static func visibleDays(_ days: [ScreenshotDay]) -> [ScreenshotDay] {
        Array(days.prefix(2))
    }
}

@MainActor
@Observable
final class CopiedFlash {
    var copiedID: Screenshot.ID?
    private var clearTask: Task<Void, Never>?

    func markCopied(_ id: Screenshot.ID, clearAfter: Duration = .milliseconds(1500)) {
        clearTask?.cancel()
        copiedID = id
        clearTask = Task {
            try? await Task.sleep(for: clearAfter)
            // `try?` eats the cancellation error, so without this a re-copy of
            // the same id would let the cancelled task clear the new flash.
            guard !Task.isCancelled else { return }
            if copiedID == id {
                copiedID = nil
            }
        }
    }
}

struct DropdownSelection {
    var ids: [Screenshot.ID]
    var selectedID: Screenshot.ID?

    init(ids: [Screenshot.ID] = []) {
        self.ids = ids
        self.selectedID = nil
    }

    mutating func moveDown() {
        guard !ids.isEmpty else { return }
        if let selectedID, let currentIndex = ids.firstIndex(of: selectedID) {
            let nextIndex = min(currentIndex + 1, ids.count - 1)
            self.selectedID = ids[nextIndex]
        } else {
            self.selectedID = ids[0]
        }
    }

    mutating func moveUp() {
        guard !ids.isEmpty else { return }
        if let selectedID, let currentIndex = ids.firstIndex(of: selectedID) {
            let previousIndex = max(currentIndex - 1, 0)
            self.selectedID = ids[previousIndex]
        } else {
            self.selectedID = ids[ids.count - 1]
        }
    }

    mutating func reconcile(ids: [Screenshot.ID]) {
        self.ids = ids
        if let selectedID, !ids.contains(selectedID) {
            self.selectedID = nil
        }
    }
}

enum DropdownKey: Equatable {
    case up, down, copy, copyText, preview, close

    static func action(key: KeyEquivalent, modifiers: EventModifiers) -> DropdownKey? {
        if key == .upArrow {
            return .up
        } else if key == .downArrow {
            return .down
        } else if key == .return {
            return modifiers.contains(.option) ? .copyText : .copy
        } else if key == .space {
            return .preview
        } else if key == .escape {
            return .close
        }
        return nil
    }
}
