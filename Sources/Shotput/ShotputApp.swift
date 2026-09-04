import AppKit
import SwiftUI
import os

/// App delegate: owns the status item, the dropdown panel, the global
/// hotkey, and the stores. Everything it builds is handed to whoever needs
/// it, so nothing has to reach back through `NSApp.delegate`.
@MainActor
final class ShotputApp: NSObject, NSApplicationDelegate {
    let settings: SettingsStore
    let windows: WindowManager
    var panel: DropdownPanel!
    let screenshotStore: ScreenshotStore
    let cleanup: CleanupScheduler
    let ai: AICoordinator
    var statusItem: NSStatusItem!
    var hotkey: Hotkey?
    var toastController: ToastController!

    private let hotkeyLogger = Logger(subsystem: "com.shotput.app", category: "hotkey")

    override init() {
        settings = SettingsStore()
        screenshotStore = ScreenshotStore(settings: settings)
        ai = AICoordinator(settings: settings, store: screenshotStore)
        windows = WindowManager(settings: settings, screenshotStore: screenshotStore, ai: ai)
        cleanup = CleanupScheduler(store: screenshotStore, settings: settings)
        super.init()

        // The model's dismiss needs the panel and the panel needs the model's
        // view, so the pair can only be built after `super.init()` makes
        // `self` capturable.
        let model = DropdownModel(
            store: screenshotStore,
            settings: settings,
            cleanup: cleanup,
            windows: windows,
            dismiss: { [weak self] in self?.panel?.hide() }
        )
        panel = DropdownPanel(rootView: AnyView(DropdownView(model: model, ai: ai)))
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        NSApp.mainMenu = Self.makeMainMenu()

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "camera", accessibilityDescription: "Shotput")
            button.image?.isTemplate = true
            button.target = self
            button.action = #selector(statusItemClicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        statusItem = item

        hotkey = Hotkey(keyCode: Hotkey.controlShiftS.keyCode, modifiers: Hotkey.controlShiftS.modifiers) { [weak self] in
            self?.togglePanel()
        }
        if hotkey == nil {
            hotkeyLogger.log("Failed to register the global hotkey")
        }

        settings.launchAtLogin = LoginItem.isEnabled

        toastController = ToastController(store: screenshotStore, settings: settings)

        screenshotStore.start()
        ai.start()
        cleanup.start()

        if !settings.onboardingComplete {
            windows.show(.onboarding)
        }
    }

    /// An `LSUIElement` app launches with no main menu, and AppKit dispatches
    /// the edit and window commands through menu key equivalents, so without
    /// this menu ⌘X/⌘C/⌘V/⌘A and ⌘W reach nothing: every text field in the
    /// app is read-only in practice and no window can be closed from the
    /// keyboard. `.accessory` keeps the bar itself off screen.
    static func makeMainMenu(appName: String = "Shotput") -> NSMenu {
        let mainMenu = NSMenu()

        // AppKit treats the first submenu as the app menu whatever it holds,
        // so Edit in slot one would be drawn under the app's name.
        //
        // No Quit here, deliberately. The status item's menu is meant to be
        // the only way out of the app, and a ⌘Q that no menu item claims is
        // simply swallowed by AppKit.
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(
            withTitle: "About \(appName)",
            action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
            keyEquivalent: ""
        )
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)

        // nil targets, so each command walks the responder chain to whichever
        // field editor is first responder.
        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)

        // Also nil-targeted: `performClose:` walks to the key window, and
        // NSWindow's own validation greys the item out for anything it cannot
        // close, which is what keeps ⌘W off the borderless dropdown panel.
        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowItem.submenu = windowMenu
        mainMenu.addItem(windowItem)

        return mainMenu
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationWillTerminate(_ notification: Notification) {
        ai.index.saveNow()
    }

    @objc private func statusItemClicked() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            showContextMenu()
        } else {
            togglePanel()
        }
    }

    private func togglePanel() {
        if panel.isVisible {
            panel.hide()
        } else {
            panel.show(relativeTo: statusItem.button)
        }
    }

    private func showContextMenu() {
        let menu = NSMenu()
        menu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Permissions…", action: #selector(openPermissions), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Open Library", action: #selector(openLibrary), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Shotput", action: #selector(quit), keyEquivalent: "").target = self
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func openSettings() {
        windows.show(.settings)
    }

    @objc private func openPermissions() {
        windows.show(.onboarding)
    }

    @objc private func openLibrary() {
        windows.show(.library)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
