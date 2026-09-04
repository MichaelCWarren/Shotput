import AppKit
import SwiftUI

/// Screen 1c: the settings window. Four groups (STORAGE, AUTO-CLEANUP, AI,
/// GENERAL) bound to `SettingsStore`; anything beyond a direct binding
/// (header text, conditional rows, folder sync/apply, launch-at-login
/// revert) lives in `SettingsViewModel` so it stays unit-testable.
struct SettingsView: View {
    @Environment(SettingsStore.self) private var settings
    /// `AICoordinator` is not `@Observable` itself, so it is passed rather
    /// than read from the environment; the queue and index inside it are,
    /// which is what makes the status rows refresh.
    var ai: AICoordinator?

    /// Only reads the store out of the environment and hands it on: the view
    /// model needs it at init, and the window is sized from a single
    /// synchronous layout pass, so a body that has no rows until `.onAppear`
    /// measures an empty window.
    var body: some View {
        SettingsContent(settings: settings, ai: ai)
    }
}

private struct SettingsContent: View {
    let settings: SettingsStore
    @State private var viewModel: SettingsViewModel
    @State private var hostWindow: NSWindow?

    init(settings: SettingsStore, ai: AICoordinator?) {
        self.settings = settings
        _viewModel = State(initialValue: SettingsViewModel(settings: settings, ai: ai))
    }

    var body: some View {
        ZStack(alignment: .top) {
            Theme.glassBackground(radius: Theme.Radius.window)

            ScrollView {
                VStack(alignment: .leading, spacing: Self.sectionSpacing) {
                    section("STORAGE") { storageGroup() }
                    section("AUTO-CLEANUP") { autoCleanupGroup() }
                    section(viewModel.aiSectionTitle) { aiGroup() }
                    section("GENERAL") { generalGroup() }
                }
                .padding(.horizontal, 20)
                // Leaves the same gap under the 28pt titlebar as the one
                // between sections.
                .padding(.top, 28 + Self.sectionSpacing)
                .padding(.bottom, Self.sectionSpacing)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .ignoresSafeArea()
        .frame(width: Theme.Metrics.settingsWidth)
        .background(ViewResolver(resolve: { $0.window }, onChange: { hostWindow = $0 }))
        .onAppear {
            viewModel.syncFolder()
            viewModel.syncThumbnail()
        }
    }

    private static let sectionSpacing: CGFloat = 20

    /// A label and its group. The label sits far closer to the group it names
    /// than to the section above, so the two read as one block.
    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel(text: title)
            content()
        }
    }

    // MARK: - STORAGE

    private func storageGroup() -> some View {
        SettingsGroup {
            SettingsRow(
                title: "Save screenshots to",
                subtitle: "Sets the capture location for all macOS screenshots"
            ) {
                Button {
                    presentFolderPicker()
                } label: {
                    Label(settings.captureFolder.lastPathComponent, systemImage: "folder")
                }
                .buttonStyle(.bordered)
            }

            RowDivider()
            WarningRow()
        }
    }

    // MARK: - AUTO-CLEANUP

    private func autoCleanupGroup() -> some View {
        @Bindable var settings = settings
        return SettingsGroup {
            SettingsRow(title: "Clean up screenshots") {
                Picker("Clean up screenshots", selection: $settings.cleanupInterval) {
                    ForEach(CleanupInterval.allCases) { interval in
                        Text(interval.label).tag(interval)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }

            RowDivider()

            SettingsRow(title: "When cleaning up", subtitle: viewModel.cleanupSubtitle) {
                Picker("When cleaning up", selection: $settings.cleanupAction) {
                    ForEach(CleanupAction.allCases) { action in
                        Text(action.label).tag(action)
                    }
                }
                .labelsHidden()
                .fixedSize()
            }

            RowDivider()

            SettingsRow(title: "Keep pinned screenshots", subtitle: "Pinned items are never cleaned up") {
                Toggle("", isOn: $settings.keepPinned)
                    .labelsHidden()
                    .toggleStyle(.switch)
            }
        }
    }

    // MARK: - AI

    private func aiGroup() -> some View {
        @Bindable var settings = settings
        return SettingsGroup {
            SettingsRow(
                title: "Describe screenshots with AI",
                subtitle: "Auto-titles, descriptions and semantic search"
            ) {
                Toggle("", isOn: $settings.aiEnabled)
                    .labelsHidden()
                    .toggleStyle(.switch)
            }

            RowDivider()

            // Still a Menu rather than a Picker: some choices are
            // unselectable, and only menu items carry a per-item disabled
            // state and a tooltip saying why.
            SettingsRow(title: "Model") {
                Menu(viewModel.selectedChoice.displayName) {
                    ForEach(viewModel.choices) { choice in
                        Button(choice.displayName) { settings.aiProvider = choice.id }
                            .disabled(!choice.isEnabled)
                            .help(choice.disabledReason ?? "")
                    }
                }
                .fixedSize()
            }
            .disabled(!settings.aiEnabled)

            RowDivider()

            SettingsRow(
                title: "Send images off this Mac",
                subtitle: "Off = images stay on this Mac. On allows Ollama Cloud and any remote Ollama host."
            ) {
                Toggle("", isOn: $settings.sendToCloud)
                    .labelsHidden()
                    .toggleStyle(.switch)
            }
            .disabled(!settings.aiEnabled)

            if viewModel.showsModelNameRow {
                RowDivider()
                SettingsRow(title: "Model name", subtitle: "Any model pulled on the host, e.g. llava:13b") {
                    TextField("", text: $settings.aiModel)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 160)
                }
                .disabled(!settings.aiEnabled)
            }

            if viewModel.showsOllamaHostRow {
                RowDivider()
                SettingsRow(
                    title: "Ollama host",
                    subtitle: "Where Ollama listens. Any host but localhost needs Send images off this Mac."
                ) {
                    TextField("", text: $settings.ollamaHost)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 160)
                }
                .disabled(!settings.aiEnabled)
            }

            if viewModel.showsCloudKeyRow {
                RowDivider()
                SettingsRow(title: "Cloud API key", subtitle: viewModel.cloudKeySubtitle) {
                    CloudKeyField(key: settings.ollamaCloudKey) { viewModel.commitCloudKey($0) }
                }
                .disabled(!settings.aiEnabled)
            }

            if viewModel.aiStatus != nil {
                RowDivider()
                statusRow()

                if !viewModel.aiFailures.isEmpty {
                    RowDivider()
                    AIFailuresRow(
                        failures: viewModel.listedFailures,
                        totalCount: viewModel.aiFailures.count,
                        hiddenCount: viewModel.hiddenFailureCount,
                        retry: { viewModel.retryFailure($0) },
                        retryAll: { viewModel.retryAllFailed() }
                    )
                }
            }
        }
    }

    /// Last in the group so the settings read top-down and the result of
    /// them concludes it.
    private func statusRow() -> some View {
        SettingsRow(
            title: viewModel.aiStatusHeadline,
            subtitle: viewModel.aiStatusDetail,
            note: viewModel.aiStatusNote
        ) {
            HStack(spacing: 8) {
                if viewModel.isDescribing {
                    ProgressView()
                        .controlSize(.small)
                }
                Button("Re-index All") { confirmReindexAll() }
                    .buttonStyle(.bordered)
                    .disabled(!viewModel.canReindexAll)
            }
        }
    }

    // MARK: - GENERAL

    private func generalGroup() -> some View {
        @Bindable var settings = settings
        return SettingsGroup {
            SettingsRow(title: "Launch at login") {
                Toggle("", isOn: Binding(
                    get: { settings.launchAtLogin },
                    set: { newValue in
                        viewModel.setLaunchAtLogin(newValue)
                        if let error = viewModel.lastError {
                            presentAlert(title: "Couldn't change launch at login", message: error.localizedDescription)
                            viewModel.lastError = nil
                        }
                    }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
            }

            RowDivider()

            SettingsRow(title: "Open dropdown shortcut") {
                // 5, not the cap's usual 2: it puts the cap at the 24pt of the
                // switches and pop-ups it shares a column with.
                KeyCap(text: "⌃⇧S", size: 11, horizontalPadding: 8, verticalPadding: 5)
            }

            RowDivider()

            SettingsRow(
                title: "Copy to clipboard on capture",
                subtitle: "New screenshots go straight to the clipboard"
            ) {
                Toggle("", isOn: $settings.autoCopyOnCapture)
                    .labelsHidden()
                    .toggleStyle(.switch)
            }

            RowDivider()

            SettingsRow(
                title: "Hide the floating thumbnail",
                subtitle: "Shotput's capture toast replaces the macOS preview"
            ) {
                Toggle("", isOn: Binding(
                    get: { settings.hidesSystemThumbnail },
                    set: { newValue in
                        viewModel.setHidesSystemThumbnail(newValue)
                        if let error = viewModel.lastError {
                            presentAlert(title: "Couldn't change the floating thumbnail", message: error.localizedDescription)
                            viewModel.lastError = nil
                        }
                    }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
            }
        }
    }

    // MARK: - Actions

    private func presentFolderPicker() {
        guard let url = ScreenshotActions.chooseFolder(
            startingAt: settings.captureFolder,
            prompt: "Choose",
            message: "Choose where macOS saves screenshots"
        ) else { return }

        viewModel.applyFolder(url)
        if let error = viewModel.lastError {
            presentAlert(title: "Couldn't change the screenshot folder", message: error.localizedDescription)
            viewModel.lastError = nil
        }
    }

    /// Asked every time. Re-indexing discards every description the library
    /// has, and on a cloud provider it uploads every screenshot again and
    /// charges for it again.
    private func confirmReindexAll() {
        let alert = NSAlert()
        alert.messageText = "Describe every screenshot again?"
        alert.informativeText = viewModel.reindexWarning
        alert.addButton(withTitle: "Re-index All")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true

        let confirmed: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .alertFirstButtonReturn else { return }
            viewModel.reindexAll()
        }
        if let hostWindow {
            alert.beginSheetModal(for: hostWindow, completionHandler: confirmed)
        } else {
            confirmed(alert.runModal())
        }
    }

    private func presentAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        if let hostWindow {
            alert.beginSheetModal(for: hostWindow)
        } else {
            alert.runModal()
        }
    }
}

/// Title, optional subtitle and trailing control: the row shape repeated in
/// every group (`.row-item` in the design).
private struct SettingsRow<Trailing: View>: View {
    let title: String
    var subtitle: String?
    /// A problem to report, on its own line so it does not read as more
    /// subtitle.
    var note: String?
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.label)
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.secondary(0.55))
                }
                if let note {
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(Theme.warn)
                        Text(note)
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.secondary(0.75))
                    }
                    .padding(.top, 2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            trailing
        }
        // A control shorter than the 24pt system ones would otherwise leave
        // its row a couple of points short of the rows around it.
        .frame(minHeight: 24)
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }
}

/// The STORAGE group's fixed warning banner about rewriting the system
/// screenshot location.
/// Holds a draft instead of binding to the store: through a binding every
/// keystroke is another keychain write, and the first of them can raise an
/// ACL dialog in the middle of typing.
private struct CloudKeyField: View {
    let key: String
    let commit: (String) -> Void

    @State private var draft: String
    @FocusState private var focused: Bool

    init(key: String, commit: @escaping (String) -> Void) {
        self.key = key
        self.commit = commit
        _draft = State(initialValue: key)
    }

    var body: some View {
        SecureField("", text: $draft)
            .textFieldStyle(.roundedBorder)
            .frame(width: 160)
            .focused($focused)
            .onSubmit { commit(draft) }
            .onChange(of: focused) { _, isFocused in
                if !isFocused { commit(draft) }
            }
            // Adopts a key that changed under the field, so it cannot go on
            // showing one the store no longer holds.
            .onChange(of: key) { _, stored in draft = stored }
    }
}

private struct WarningRow: View {
    private var keyName: Text {
        Text("com.apple.screencapture location").font(.system(size: 10, design: .monospaced))
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 14))
                .foregroundStyle(Theme.warn)

            Text("Changing this rewrites the system default (\(keyName)). Existing files stay put.")
                .font(.system(size: 11))
                .foregroundStyle(Theme.secondary(0.75))
                .lineSpacing(4.95)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 11)
        .padding(.horizontal, 14)
        .background(Color(red: 1, green: 214 / 255, blue: 120 / 255).opacity(0.16))
        // The card's corners are rounded behind its rows, so a row with a
        // fill of its own has to round the bottom two or it squares them off.
        .clipShape(.rect(
            bottomLeadingRadius: Theme.Radius.group,
            bottomTrailingRadius: Theme.Radius.group
        ))
    }
}

/// The given-up screenshots, capped. Settings already scrolls, so an
/// unbounded list would push everything under it off the window.
private struct AIFailuresRow: View {
    let failures: [AIFailureItem]
    let totalCount: Int
    let hiddenCount: Int
    let retry: (URL) -> Void
    let retryAll: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.warn)

                Text(SettingsViewModel.failureSummary(count: totalCount))
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.label)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Button("Retry All") { retryAll() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }

            ForEach(failures) { item in
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.url.lastPathComponent)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Theme.secondary(0.85))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text(SettingsViewModel.failureDetail(item))
                            .font(.system(size: 10.5))
                            .foregroundStyle(Theme.secondary(0.55))
                            .lineLimit(2)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    Button("Retry") { retry(item.url) }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
            }

            if hiddenCount > 0 {
                Text("\(hiddenCount) more not shown. Retry All covers them too.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.secondary(0.5))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }
}
