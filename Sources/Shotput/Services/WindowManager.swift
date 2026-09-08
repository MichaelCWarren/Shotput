import AppKit
import SwiftUI

/// Opens the app's ordinary (non-panel) windows once each and reuses them on
/// every later call. An accessory app is never active on its own, so every
/// `show` re-activates the app before bringing the window forward.
@MainActor
final class WindowManager {
    enum Kind: Hashable {
        case settings, library, onboarding, about
    }

    private let settings: SettingsStore
    private let screenshotStore: ScreenshotStore
    private let ai: AICoordinator?
    private let visibleHeight: @MainActor (NSWindow) -> CGFloat?
    private let contentOverride: (@MainActor (Kind) -> AnyView)?
    private var windows: [Kind: NSWindow] = [:]

    /// `visibleHeight` is injected so tests can stand in a small display; it
    /// answers for the screen the window has just been placed on, which is
    /// not always the main one. `content` likewise stands in a body with a
    /// known settling behaviour, which the three real screens cannot show.
    init(
        settings: SettingsStore,
        screenshotStore: ScreenshotStore,
        ai: AICoordinator? = nil,
        visibleHeight: @escaping @MainActor (NSWindow) -> CGFloat? = { ($0.screen ?? NSScreen.main)?.visibleFrame.height },
        content: (@MainActor (Kind) -> AnyView)? = nil
    ) {
        self.settings = settings
        self.screenshotStore = screenshotStore
        self.ai = ai
        self.visibleHeight = visibleHeight
        self.contentOverride = content
    }

    func window(for kind: Kind) -> NSWindow? {
        windows[kind]
    }

    func show(_ kind: Kind) {
        if let window = windows[kind] {
            bringToFront(window)
            return
        }
        let window = makeWindow(for: kind)
        windows[kind] = window
        bringToFront(window)
        // `makeWindow` sizes the window by running the SwiftUI tree, but a
        // caller already inside a SwiftUI action defers that work to the end
        // of its own update, so the measurement sees an empty view and the
        // window is built a few points tall. The tree exists by the next turn.
        Task { @MainActor in growToFitContent(window, kind: kind) }
    }

    /// Plain `activate()`, not `activate(ignoringOtherApps:)`: the latter
    /// leaves `NSApp.isActive` false when the caller is the non-activating
    /// dropdown, and the window then opens without focus.
    private func bringToFront(_ window: NSWindow) {
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    /// Rescues a window that `makeWindow` measured before its body existed, by
    /// repeating that measurement now the tree has been built. Only ever grows,
    /// so a window auto-layout has already stretched keeps the extra height.
    ///
    /// The height test is what keeps this from nudging healthy windows: an
    /// unbuilt body measures near zero, and `minimumClampedHeight` is already
    /// this file's judgement of the point below which a window is not real.
    private func growToFitContent(_ window: NSWindow, kind: Kind) {
        guard window.frame.height < Self.minimumClampedHeight else { return }
        guard let hostingView = window.contentView else { return }
        let layout = layout(for: kind)

        let installedFrame = hostingView.frame
        hostingView.frame = NSRect(x: 0, y: 0, width: layout.width, height: 0)
        hostingView.layoutSubtreeIfNeeded()
        let contentHeight = hostingView.fittingSize.height
        hostingView.frame = installedFrame
        hostingView.layoutSubtreeIfNeeded()

        let height = layout.clampsToScreen
            ? Self.clampedHeight(contentHeight: contentHeight, visibleHeight: visibleHeight(window))
            : contentHeight
        guard height > window.frame.height else { return }

        window.setContentSize(NSSize(width: layout.width, height: height))
        window.center()
    }

    private func content(for kind: Kind) -> AnyView {
        if let contentOverride {
            return contentOverride(kind)
        }
        return switch kind {
        case .settings:
            AnyView(SettingsView(ai: ai).environment(settings))
        case .library:
            AnyView(LibraryView(ai: ai).environment(settings).environment(screenshotStore))
        case .onboarding:
            AnyView(OnboardingView(windows: self).environment(settings))
        case .about:
            AnyView(AboutView().environment(screenshotStore))
        }
    }

    /// Everything that differs between the windows. Every one of them
    /// is translucent, so transparency is applied outside this.
    private struct Layout {
        let width: CGFloat
        let title: String
        var extraStyle: NSWindow.StyleMask = []
        var minSize: NSSize?
        var titleVisibility: NSWindow.TitleVisibility = .visible
        var clampsToScreen = false
    }

    private func layout(for kind: Kind) -> Layout {
        switch kind {
        case .settings:
            Layout(
                width: Theme.Metrics.settingsWidth,
                title: "Shotput Settings",
                extraStyle: .miniaturizable,
                clampsToScreen: true
            )
        case .library:
            Layout(
                width: Theme.Metrics.libraryWidth,
                title: "Shotput Library",
                extraStyle: .resizable,
                minSize: NSSize(width: Theme.Metrics.libraryWidth, height: 400),
                clampsToScreen: true
            )
        case .onboarding:
            Layout(width: Theme.Metrics.onboardingWidth, title: "")
        case .about:
            Layout(width: Theme.Metrics.aboutWidth, title: "")
        }
    }

    /// Gap left between a clamped window and the edges of the screen.
    private static let screenMargin: CGFloat = 24

    /// Smallest window a clamp may produce, so a freak visible frame cannot
    /// shrink the window to nothing.
    private static let minimumClampedHeight: CGFloat = 240

    /// Height for a window whose content wants `contentHeight`. A window
    /// taller than the screen can be neither resized nor dragged into view,
    /// so it stops at the visible frame and scrolls the rest.
    static func clampedHeight(contentHeight: CGFloat, visibleHeight: CGFloat?) -> CGFloat {
        guard let visibleHeight else { return contentHeight }
        return min(contentHeight, max(minimumClampedHeight, visibleHeight - screenMargin))
    }

    private func makeWindow(for kind: Kind) -> NSWindow {
        let layout = layout(for: kind)
        var style: NSWindow.StyleMask = [.titled, .closable, .fullSizeContentView]
        style.insert(layout.extraStyle)

        let hostingView = NSHostingView(rootView: content(for: kind))
        hostingView.frame = NSRect(x: 0, y: 0, width: layout.width, height: 0)
        // SwiftUI only builds the tree on the first layout pass; until then
        // fittingSize reports an empty view.
        hostingView.layoutSubtreeIfNeeded()
        let contentHeight = hostingView.fittingSize.height

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: layout.width, height: contentHeight),
            styleMask: style,
            backing: .buffered,
            defer: false
        )
        window.title = layout.title
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.contentView = hostingView
        window.isOpaque = false
        window.backgroundColor = .clear
        window.titleVisibility = layout.titleVisibility
        if let minSize = layout.minSize {
            window.minSize = minSize
        }
        window.center()

        if layout.clampsToScreen {
            let height = Self.clampedHeight(contentHeight: contentHeight, visibleHeight: visibleHeight(window))
            if height < contentHeight {
                window.setContentSize(NSSize(width: layout.width, height: height))
                window.center()
            }
        }
        return window
    }
}
