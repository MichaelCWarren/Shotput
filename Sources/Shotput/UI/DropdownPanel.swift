import AppKit
import Quartz
import SwiftUI

/// The glass panel that drops from the status item. Non-activating so the
/// frontmost app never loses focus, but key so spec 05's search field can
/// take typing.
final class DropdownPanel: NSPanel {
    private let hostingView: NSHostingView<AnyView>
    private weak var anchorButton: NSStatusBarButton?

    private var globalClickMonitor: Any?
    private var localClickMonitor: Any?
    private var localKeyMonitor: Any?

    var rootView: AnyView {
        get { hostingView.rootView }
        // Swapping the root view updates fittingSize but leaves the hosting
        // view's own frame alone, so nothing posts frameDidChangeNotification.
        set {
            hostingView.rootView = newValue
            if isVisible { layout() }
        }
    }

    init(rootView: AnyView) {
        hostingView = NSHostingView(rootView: rootView)
        hostingView.sizingOptions = [.intrinsicContentSize]
        hostingView.postsFrameChangedNotifications = true

        super.init(
            contentRect: NSRect(x: 0, y: 0, width: Theme.Metrics.dropdownWidth, height: hostingView.fittingSize.height),
            styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        level = .popUpMenu
        collectionBehavior = [.canJoinAllSpaces, .transient, .fullScreenAuxiliary]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        animationBehavior = .utilityWindow
        contentView = hostingView

        NotificationCenter.default.addObserver(
            self, selector: #selector(hostingViewFrameChanged),
            name: NSView.frameDidChangeNotification, object: hostingView
        )
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// AppKit's last stop for Escape, reached only when nothing in the
    /// content took it. Without this the panel would sit there unclosable
    /// whenever SwiftUI focus has drifted off the list.
    override func cancelOperation(_ sender: Any?) {
        hide()
    }

    func show(relativeTo button: NSStatusBarButton?) {
        anchorButton = button
        layout()
        makeKeyAndOrderFront(nil)
        installMonitors()
    }

    func hide() {
        orderOut(nil)
        removeMonitors()
    }

    @objc private func hostingViewFrameChanged() {
        guard isVisible else { return }
        layout()
    }

    /// The top-right corner is the fixed point; height changes grow the
    /// panel downward, anchored to the status item (or the screen corner
    /// when the icon is unavailable, e.g. tucked into the overflow menu).
    private func layout() {
        let width = Theme.Metrics.dropdownWidth
        let height = hostingView.fittingSize.height
        guard let screenFrame = (anchorButton?.window?.screen ?? NSScreen.main)?.visibleFrame else { return }

        let topRight: CGPoint
        if let button = anchorButton, let buttonWindow = button.window {
            let screenRect = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
            topRight = CGPoint(x: screenRect.maxX, y: screenRect.minY - 6)
        } else {
            topRight = CGPoint(x: screenFrame.maxX - 10, y: screenFrame.maxY - 10)
        }

        var frame = NSRect(x: topRight.x - width, y: topRight.y - height, width: width, height: height)
        if frame.maxX > screenFrame.maxX { frame.origin.x = screenFrame.maxX - width }
        if frame.minX < screenFrame.minX { frame.origin.x = screenFrame.minX }
        if frame.maxY > screenFrame.maxY { frame.origin.y = screenFrame.maxY - height }
        if frame.minY < screenFrame.minY { frame.origin.y = screenFrame.minY }

        setFrame(frame, display: true)
    }

    private func installMonitors() {
        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
            self?.hide()
        }
        localClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
            guard let self else { return event }
            if event.window !== self, event.window !== anchorButton?.window, !(event.window is QLPreviewPanel) {
                hide()
            }
            return event
        }
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard let self else { return event }
            // A local monitor runs before the event reaches the window, so
            // handling Escape here would beat the panel's own search field to
            // it. Let events aimed at the panel through and close only when
            // nothing inside it wants Escape first.
            if event.keyCode == 53, event.window !== self {
                hide()
                return nil
            }
            return event
        }
    }

    private func removeMonitors() {
        if let globalClickMonitor { NSEvent.removeMonitor(globalClickMonitor) }
        if let localClickMonitor { NSEvent.removeMonitor(localClickMonitor) }
        if let localKeyMonitor { NSEvent.removeMonitor(localKeyMonitor) }
        globalClickMonitor = nil
        localClickMonitor = nil
        localKeyMonitor = nil
    }
}

/// Stand-in for the real dropdown content (spec 03). Sized so the panel is
/// visible and resizes correctly before that spec lands.
struct DropdownPlaceholderView: View {
    var height: CGFloat = 120

    var body: some View {
        Text("Screenshots")
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(Theme.label)
            .frame(width: Theme.Metrics.dropdownWidth, height: height)
            .glassEffect(.regular, in: .rect(cornerRadius: Theme.Radius.dropdown))
    }
}
