import AppKit
import SwiftUI

/// Screen 1e: the first-launch window. Each row below is a real filesystem
/// check, not a cosmetic step — `OnboardingModel` re-runs them on appear and
/// on every window focus, and Continue only lights up once the first two
/// have passed.
enum PermissionStepState {
    case passed, pending, failed
}

/// Plain, nonisolated so step 1's listing (which can block behind the macOS
/// Desktop prompt) runs off the main thread; neither function reads
/// `SettingsStore` directly, so `OnboardingModel` passes in the persisted
/// flags and folder it needs checked.
enum PermissionChecks {
    static func captureFolderAccess(at folder: URL) -> PermissionStepState {
        do {
            _ = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            return .passed
        } catch {
            return .failed
        }
    }

    static func saveFolderAccess(confirmed: Bool, folder: URL) -> PermissionStepState {
        confirmed && FileManager.default.isWritableFile(atPath: folder.path) ? .passed : .pending
    }

    /// Writes a throwaway file, trashes it, then deletes the trashed copy,
    /// so the check never leaves anything behind in the folder or in the
    /// user's real Trash. The UUID in the name avoids a collision with any
    /// other probe file left by a concurrent test run.
    static func trashRoundTrip(in folder: URL) -> (state: PermissionStepState, trashURL: URL?) {
        let probe = folder.appendingPathComponent(".shotput-trash-check-\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: probe.path, contents: Data()) else {
            return (.failed, nil)
        }
        var resultingURL: NSURL?
        do {
            try FileManager.default.trashItem(at: probe, resultingItemURL: &resultingURL)
        } catch {
            try? FileManager.default.removeItem(at: probe)
            return (.failed, nil)
        }
        let trashURL = resultingURL as URL?
        if let trashURL {
            try? FileManager.default.removeItem(at: trashURL)
        }
        return (.passed, trashURL)
    }
}

@MainActor
@Observable
final class OnboardingModel {
    struct StepInfo {
        let title: String
        let subtitle: String
        let systemImage: String
    }

    static let stepInfo: [StepInfo] = [
        StepInfo(
            title: "Capture folder access",
            subtitle: "So Shotput can see the screenshots macOS is already putting there",
            systemImage: "folder"
        ),
        StepInfo(
            title: "Save-folder access",
            subtitle: "Point at where they land. It's the Desktop. It's always the Desktop",
            systemImage: "folder.badge.gearshape"
        ),
        StepInfo(
            title: "Trash access",
            subtitle: "For the tidying up you were definitely going to do yourself",
            systemImage: "trash"
        )
    ]

    private(set) var states: [PermissionStepState] = [.pending, .pending, .pending]
    /// Once the capture-folder listing has failed this session, Grant… stops
    /// retrying it and opens System Settings instead — the user already
    /// declined the TCC prompt, so re-listing would just fail again.
    private(set) var captureFolderDeniedOnce = false

    private let settings: SettingsStore
    private let checkCaptureFolder: () async -> PermissionStepState
    private let checkSaveFolder: () -> PermissionStepState
    private let checkTrash: () -> PermissionStepState
    private let writeLocation: (URL) throws -> Void
    private let openSystemSettings: () -> Void

    init(
        settings: SettingsStore,
        checkCaptureFolder: (() async -> PermissionStepState)? = nil,
        checkSaveFolder: (() -> PermissionStepState)? = nil,
        checkTrash: (() -> PermissionStepState)? = nil,
        writeLocation: @escaping (URL) throws -> Void = CaptureLocation.write,
        openSystemSettings: @escaping () -> Void = OnboardingModel.openPrivacySettings
    ) {
        self.settings = settings
        self.checkCaptureFolder = checkCaptureFolder ?? {
            let folder = settings.captureFolder
            return await Task.detached { PermissionChecks.captureFolderAccess(at: folder) }.value
        }
        self.checkSaveFolder = checkSaveFolder ?? {
            PermissionChecks.saveFolderAccess(confirmed: settings.saveFolderConfirmed, folder: settings.captureFolder)
        }
        self.checkTrash = checkTrash ?? {
            settings.trashAccessVerified ? .passed : .pending
        }
        self.writeLocation = writeLocation
        self.openSystemSettings = openSystemSettings
    }

    var nextPendingIndex: Int? {
        states.firstIndex { $0 != .passed }
    }

    var canContinue: Bool {
        states[0] == .passed && states[1] == .passed
    }

    var hint: String {
        if let gatingIndex = [0, 1].first(where: { states[$0] != .passed }) {
            return "Continue wakes up once \(Self.stepInfo[gatingIndex].title) is granted"
        }
        if states[2] != .passed {
            return "Trash access is optional. Auto-cleanup will come asking the first time it runs anyway."
        }
        return "Granted, all three. The menu bar remembers where this lives."
    }

    func recheck() async {
        let capture = await checkCaptureFolder()
        states[0] = capture
        if capture == .failed { captureFolderDeniedOnce = true }
        states[1] = checkSaveFolder()
        states[2] = checkTrash()
    }

    func grantCaptureFolder() async {
        if captureFolderDeniedOnce {
            openSystemSettings()
        } else {
            await recheck()
        }
    }

    /// `chosenFolder` is nil when the panel was cancelled, which changes
    /// nothing — the picker itself lives in the view so this stays testable
    /// without presenting real UI.
    func grantSaveFolder(chosenFolder: URL?) async {
        guard let chosenFolder else { return }
        if chosenFolder.path != settings.captureFolder.path {
            try? writeLocation(chosenFolder)
            settings.captureFolder = chosenFolder
        }
        settings.saveFolderConfirmed = true
        await recheck()
    }

    func grantTrash() async {
        let result = PermissionChecks.trashRoundTrip(in: settings.captureFolder)
        if result.state == .passed {
            settings.trashAccessVerified = true
        }
        await recheck()
    }

    func continueTapped() {
        settings.onboardingComplete = true
    }

    private nonisolated static func openPrivacySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders") else { return }
        NSWorkspace.shared.open(url)
    }
}

struct OnboardingView: View {
    let windows: WindowManager
    @Environment(SettingsStore.self) private var settings

    var body: some View {
        ZStack(alignment: .top) {
            Theme.glassBackground(radius: Theme.Radius.onboarding)

            OnboardingContent(windows: windows, settings: settings)
        }
        .ignoresSafeArea()
        .frame(width: Theme.Metrics.onboardingWidth)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.onboarding))
    }
}

/// Split out so the model can be built in `init` from a store handed down
/// rather than in an `.onAppear`: `WindowManager` sizes this window from a
/// single synchronous layout pass, and SwiftUI defers `.onAppear` past that
/// pass when the window is opened from a button action. A body still waiting
/// for its model at that point measures as an empty sliver, and nothing
/// afterwards grows the window.
private struct OnboardingContent: View {
    let windows: WindowManager
    let settings: SettingsStore

    @State private var model: OnboardingModel
    @State private var keyObserver: NSObjectProtocol?
    @State private var hostWindow: NSWindow?

    @MainActor
    init(windows: WindowManager, settings: SettingsStore) {
        self.windows = windows
        self.settings = settings
        _model = State(initialValue: OnboardingModel(settings: settings))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            rows
            footer
        }
        .background(ViewResolver(resolve: { $0.window }, onChange: { hostWindow = $0 }))
        .onAppear { setUp() }
        .onDisappear { tearDown() }
        .onChange(of: hostWindow) { _, window in
            observeKeyChanges(window: window)
        }
    }

    private var header: some View {
        VStack(spacing: 6) {
            Image(systemName: "camera")
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 64, height: 64)
                .background(
                    LinearGradient(
                        colors: [Color(red: 0x4d / 255, green: 0xa3 / 255, blue: 0xe0 / 255), Theme.accent],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    ),
                    in: RoundedRectangle(cornerRadius: 16)
                )
                .padding(.bottom, 6)

            Text("Welcome to Shotput")
                .font(.system(size: 19, weight: .bold))
                .kerning(-0.19)
                .foregroundStyle(Theme.label)

            Text("Your screenshots, one click from the clipboard. macOS just wants to ask three times whether you meant it.")
                .font(.system(size: 12.5))
                .lineSpacing(6)
                .multilineTextAlignment(.center)
                .foregroundStyle(Theme.secondary(0.65))
                .frame(maxWidth: 320)
        }
        // The body ignores the safe area so the glass reaches the window
        // edges, which also drops the inset that would otherwise hold content
        // clear of the transparent titlebar. 50 restores it, as in Settings.
        .padding(.top, 50)
        .padding(.horizontal, 32)
        .padding(.bottom, 18)
    }

    private var rows: some View {
        VStack(spacing: 8) {
            ForEach(OnboardingModel.stepInfo.indices, id: \.self) { index in
                SettingsGroup(radius: Theme.Radius.group) {
                    row(index: index)
                }
            }
        }
        .padding(.horizontal, 26)
        .padding(.bottom, 8)
    }

    private func row(index: Int) -> some View {
        let info = OnboardingModel.stepInfo[index]
        return HStack(spacing: 12) {
            Image(systemName: info.systemImage)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(rowGradient(for: index), in: RoundedRectangle(cornerRadius: 9))

            VStack(alignment: .leading, spacing: 2) {
                Text(info.title)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(Theme.label)
                Text(info.subtitle)
                    .font(.system(size: 10.5))
                    .lineSpacing(2)
                    // Two lines whether or not this row is the one showing
                    // Grant…: the button narrows the text column, and without
                    // a reserved height the rows below would jump as each
                    // step passes, inside a window already sized once.
                    .lineLimit(2, reservesSpace: true)
                    .foregroundStyle(Theme.secondary(0.55))
            }

            Spacer(minLength: 0)

            trailing(index: index)
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 11)
    }

    private func rowGradient(for index: Int) -> LinearGradient {
        let colors: [(Color, Color)] = [
            (Color(red: 0x4d / 255, green: 0xa3 / 255, blue: 0xe0 / 255), Theme.accent),
            (Color(red: 0x9a / 255, green: 0x6e / 255, blue: 0xe8 / 255), Color(red: 0x6b / 255, green: 0x3f / 255, blue: 0xc9 / 255)),
            (Color(red: 0xf0 / 255, green: 0xa8 / 255, blue: 0x3c / 255), Color(red: 0xd9 / 255, green: 0x7b / 255, blue: 0x12 / 255))
        ]
        let (start, end) = colors[index]
        return LinearGradient(colors: [start, end], startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    @ViewBuilder
    private func trailing(index: Int) -> some View {
        if model.states[index] == .passed {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 15))
                .foregroundStyle(.white, Theme.green)
        } else if model.nextPendingIndex == index {
            PillButton(title: "Grant…", prominent: true, height: 25) {
                grant(index: index)
            }
        }
    }

    private var footer: some View {
        VStack(spacing: 10) {
            Button {
                model.continueTapped()
                windows.window(for: .onboarding)?.close()
            } label: {
                Text("Continue")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.glassProminent)
            .buttonBorderShape(.roundedRectangle(radius: 12))
            .controlSize(.extraLarge)
            .disabled(!model.canContinue)

            Text(model.hint)
                .font(.system(size: 10.5))
                .multilineTextAlignment(.center)
                .foregroundStyle(Theme.secondary(0.5))
        }
        .padding(.horizontal, 26)
        .padding(.top, 14)
        .padding(.bottom, 24)
    }

    // MARK: - Actions

    private func grant(index: Int) {
        switch index {
        case 0:
            Task { await model.grantCaptureFolder() }
        case 1:
            presentSaveFolderPanel()
        default:
            Task { await model.grantTrash() }
        }
    }

    private func presentSaveFolderPanel() {
        let chosen = ScreenshotActions.chooseFolder(startingAt: settings.captureFolder, prompt: "Use This Folder")
        Task { await model.grantSaveFolder(chosenFolder: chosen) }
    }

    private func setUp() {
        Task { await model.recheck() }
        observeKeyChanges(window: hostWindow)
    }

    /// Re-runs the checks whenever the window comes back to the front, so
    /// granting access in System Settings and switching back turns the row
    /// green. Driven by the window the view is actually in rather than by
    /// `WindowManager`, which has not recorded the window yet when this view
    /// first appears. The window arrives asynchronously, so this runs both on
    /// appear and on every change and does nothing until there is one.
    private func observeKeyChanges(window: NSWindow?) {
        tearDown()
        guard let window else { return }
        keyObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main
        ) { _ in
            Task { await model.recheck() }
        }
    }

    private func tearDown() {
        if let keyObserver {
            NotificationCenter.default.removeObserver(keyObserver)
        }
        keyObserver = nil
    }
}
