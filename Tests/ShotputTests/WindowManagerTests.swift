import Testing
import AppKit
import SwiftUI
@testable import Shotput

@Suite @MainActor struct WindowManagerTests {
    @Test func singleInstancePerKind() {
        _ = NSApplication.shared
        let settings = SettingsStore(defaults: UserDefaults(suiteName: "ShotputTests.wm1")!, secrets: InMemorySecretStore())
        let store = ScreenshotStore(settings: settings, pinsFile: FileManager.default.temporaryDirectory.appendingPathComponent("ShotputTests-\(UUID()).json"))
        let manager = WindowManager(settings: settings, screenshotStore: store)

        manager.show(.settings)
        let first = manager.window(for: .settings)
        #expect(manager.window(for: .library) == nil)

        manager.show(.settings)
        let second = manager.window(for: .settings)
        #expect(first === second)

        manager.window(for: .settings)?.orderOut(nil)
    }

    @Test func titlesAndWidths() {
        _ = NSApplication.shared
        let settings = SettingsStore(defaults: UserDefaults(suiteName: "ShotputTests.wm2")!, secrets: InMemorySecretStore())
        let store = ScreenshotStore(settings: settings, pinsFile: FileManager.default.temporaryDirectory.appendingPathComponent("ShotputTests-\(UUID()).json"))
        let manager = WindowManager(settings: settings, screenshotStore: store)

        manager.show(.settings)
        manager.show(.library)
        manager.show(.onboarding)

        #expect(manager.window(for: .settings)?.title == "Shotput Settings")
        #expect(manager.window(for: .library)?.title == "Shotput Library")
        #expect(manager.window(for: .onboarding)?.title == "")

        #expect(manager.window(for: .settings)?.contentView?.frame.width == Theme.Metrics.settingsWidth)
        #expect(manager.window(for: .library)?.contentView?.frame.width == Theme.Metrics.libraryWidth)
        #expect(manager.window(for: .onboarding)?.contentView?.frame.width == Theme.Metrics.onboardingWidth)

        #expect(manager.window(for: .onboarding)?.isOpaque == false)

        manager.window(for: .settings)?.orderOut(nil)
        manager.window(for: .library)?.orderOut(nil)
        manager.window(for: .onboarding)?.orderOut(nil)
    }

    @Test func clampedHeightStopsAtTheVisibleFrame() {
        // 1440x900 MacBook Air: 900 less the menu bar, Dock hidden.
        let visible: CGFloat = 875

        let clamped = WindowManager.clampedHeight(contentHeight: 942, visibleHeight: visible)
        #expect(clamped < 942)
        #expect(clamped <= visible)

        #expect(WindowManager.clampedHeight(contentHeight: 600, visibleHeight: visible) == 600)
        #expect(WindowManager.clampedHeight(contentHeight: 942, visibleHeight: nil) == 942)
        #expect(WindowManager.clampedHeight(contentHeight: 942, visibleHeight: 10) == 240)
    }

    @Test func settingsWindowFitsASmallDisplay() {
        _ = NSApplication.shared
        let settings = SettingsStore(defaults: UserDefaults(suiteName: "ShotputTests.wm3")!, secrets: InMemorySecretStore())
        settings.sendToCloud = true
        settings.aiProvider = .ollamaLocal
        let store = ScreenshotStore(settings: settings, pinsFile: FileManager.default.temporaryDirectory.appendingPathComponent("ShotputTests-\(UUID()).json"))
        let visible: CGFloat = 875
        let manager = WindowManager(settings: settings, screenshotStore: store, visibleHeight: { _ in visible })

        manager.show(.settings)
        manager.show(.onboarding)

        // The settings body is taller than this display whatever the current
        // layout makes it, so the window has to come out at exactly the clamp.
        // Naming a content height here would only pin the layout of the day —
        // the clamp caps anything that overflows at the same number.
        let settingsWindow = manager.window(for: .settings)
        #expect(settingsWindow?.frame.height ?? .infinity <= visible)
        #expect(settingsWindow?.frame.height == WindowManager.clampedHeight(contentHeight: .greatestFiniteMagnitude, visibleHeight: visible))

        // Onboarding is never clamped, so it keeps whatever height its content
        // asks for. Pinning that number only records the layout of the day;
        // these are the two ways the height can be wrong. The floor catches a
        // window built before its body had any content, which measures around
        // 10pt — three step rows and a button cannot come to less than 300.
        let onboarding = manager.window(for: .onboarding)
        #expect(onboarding?.frame.height ?? 0 > 300)
        #expect(onboarding?.frame.height ?? .infinity <= visible)

        manager.window(for: .settings)?.orderOut(nil)
        manager.window(for: .onboarding)?.orderOut(nil)
    }

    @Test func aWindowMeasuredBeforeItsBodyExistedIsCorrected() async {
        _ = NSApplication.shared
        let settings = SettingsStore(defaults: UserDefaults(suiteName: "ShotputTests.wm4")!, secrets: InMemorySecretStore())
        let store = ScreenshotStore(settings: settings, pinsFile: FileManager.default.temporaryDirectory.appendingPathComponent("ShotputTests-\(UUID()).json"))
        // Tall enough that the clamp cannot be what limits the window here.
        let manager = WindowManager(
            settings: settings,
            screenshotStore: store,
            visibleHeight: { _ in 2000 },
            content: { _ in AnyView(SettlesAfterFirstLayout()) }
        )

        manager.show(.settings)

        // Guards the test itself: the correction is only worth anything while
        // the window really is built as a sliver first. If this ever passes at
        // full height, the stand-in has stopped reproducing the bug.
        let atCreation = manager.window(for: .settings)?.frame.height ?? 0
        #expect(atCreation < SettlesAfterFirstLayout.settledHeight)

        // Polled rather than slept, so a loaded machine cannot fail this for
        // being slow; a missing correction still fails, just at the deadline.
        _ = await poll { (manager.window(for: .settings)?.frame.height ?? 0) >= SettlesAfterFirstLayout.settledHeight }

        #expect(manager.window(for: .settings)?.frame.height ?? 0 >= SettlesAfterFirstLayout.settledHeight)

        manager.window(for: .settings)?.orderOut(nil)
    }

    /// ⌘W and the title bar button both end in `close()`, so what this covers
    /// is the reuse afterwards: the manager hands the same window back, and a
    /// window kept past its close is still a usable one rather than a husk.
    @Test func aClosedWindowReopens() {
        _ = NSApplication.shared
        let settings = SettingsStore(defaults: UserDefaults(suiteName: "ShotputTests.wm5")!, secrets: InMemorySecretStore())
        let store = ScreenshotStore(settings: settings, pinsFile: FileManager.default.temporaryDirectory.appendingPathComponent("ShotputTests-\(UUID()).json"))
        let manager = WindowManager(settings: settings, screenshotStore: store, visibleHeight: { _ in 875 })

        manager.show(.settings)
        let opened = manager.window(for: .settings)
        #expect(opened?.isVisible == true)
        // Nothing may be released out from under the manager's dictionary.
        #expect(opened?.isReleasedWhenClosed == false)
        let heightWhenOpened = opened?.frame.height ?? 0

        opened?.close()
        #expect(opened?.isVisible == false)

        manager.show(.settings)
        let reopened = manager.window(for: .settings)
        #expect(reopened === opened)
        #expect(reopened?.isVisible == true)
        #expect(reopened?.contentView != nil)
        #expect(reopened?.frame.height == heightWhenOpened)

        manager.window(for: .settings)?.orderOut(nil)
    }
}

/// A body with no height until a turn after its first layout pass, which is
/// what leaves the window measured as a sliver. The real screens cannot stand
/// in for this: they settle during the measurement and so never reproduce it.
///
/// The scroll view is load-bearing, not decoration. It reports the height its
/// content asks for, so a measurement still works, but it accepts any height
/// offered, so auto-layout will not grow the window on its own afterwards —
/// without it this passes whether the window is ever corrected or not.
private struct SettlesAfterFirstLayout: View {
    static let settledHeight: CGFloat = 600

    @State private var height: CGFloat = 0

    var body: some View {
        ScrollView {
            Color.clear.frame(height: height)
        }
        .onAppear { Task { height = Self.settledHeight } }
    }
}

@Suite @MainActor struct MainMenuTests {
    private func submenu(_ title: String, in menu: NSMenu) -> NSMenu? {
        menu.items.first { $0.submenu?.title == title }?.submenu
    }

    @Test func quitIsOnlyOnTheStatusItemMenu() {
        let menu = ShotputApp.makeMainMenu()

        let everyItem = menu.items.flatMap { $0.submenu?.items ?? [] }
        #expect(everyItem.allSatisfy { $0.action != #selector(NSApplication.terminate(_:)) })
        // Nothing else may claim ⌘Q either, or it would shadow the absence.
        #expect(everyItem.allSatisfy { !($0.keyEquivalent == "q" && $0.keyEquivalentModifierMask == .command) })
    }

    @Test func theAppMenuIsFirstAndNotEmpty() {
        let menu = ShotputApp.makeMainMenu(appName: "Shotput")

        // Slot one is drawn under the app's name whatever it holds, so Edit
        // must not be there. An empty menu would read as a broken app menu.
        let appMenu = menu.items.first?.submenu
        #expect(appMenu?.title != "Edit")
        #expect(appMenu?.items.isEmpty == false)
        #expect(appMenu?.items.first?.title == "About Shotput")
        #expect(appMenu?.items.first?.action == #selector(NSApplication.orderFrontStandardAboutPanel(_:)))
    }

    @Test func closeIsBoundToCommandW() {
        let menu = ShotputApp.makeMainMenu()

        let close = submenu("Window", in: menu)?.items.first { $0.title == "Close" }
        #expect(close?.keyEquivalent == "w")
        #expect(close?.keyEquivalentModifierMask == .command)
        #expect(close?.action == #selector(NSWindow.performClose(_:)))
        // A target here would pin the command to one object; nil is what
        // sends it down the responder chain to whichever window is key.
        #expect(close?.target == nil)
    }

    @Test func editCommandsStillReachTheFieldEditor() {
        let menu = ShotputApp.makeMainMenu()
        let edit = submenu("Edit", in: menu)

        let expected: [(String, Selector, String)] = [
            ("Undo", Selector(("undo:")), "z"),
            ("Redo", Selector(("redo:")), "Z"),
            ("Cut", #selector(NSText.cut(_:)), "x"),
            ("Copy", #selector(NSText.copy(_:)), "c"),
            ("Paste", #selector(NSText.paste(_:)), "v"),
            ("Select All", #selector(NSText.selectAll(_:)), "a"),
        ]
        for (title, action, key) in expected {
            let item = edit?.items.first { $0.title == title }
            #expect(item?.action == action, "\(title) is missing or misbound")
            #expect(item?.keyEquivalent == key)
            #expect(item?.target == nil)
        }
    }
}
