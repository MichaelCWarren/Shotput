import AppKit
import SwiftUI

/// The floating, non-activating panel the capture toast lives in. Its frame
/// is always exactly the toast's own size, so a click anywhere outside the
/// 330-wide card never reaches the panel and never steals focus from the
/// frontmost app.
final class ToastPanel: NSPanel {
    private let hostingView: NSHostingView<ToastView>

    /// Bumped by `present` and `dismiss` and checked by the slide-out's
    /// completion handler, so a dismissal that a new capture interrupted can no
    /// longer order the panel out from under the toast that replaced it.
    private var animationGeneration = 0

    /// Moves the panel to `frame` at `alpha` over `duration`, then calls the
    /// completion. `NSAnimationContext` only advances while something pumps a
    /// run loop, so tests swap this out and step each slide by hand.
    var slide: (ToastPanel, CGRect, CGFloat, TimeInterval, @escaping () -> Void) -> Void = { panel, frame, alpha, duration, completion in
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(frame, display: true)
            panel.animator().alphaValue = alpha
        }, completionHandler: completion)
    }

    var rootView: ToastView {
        get { hostingView.rootView }
        set { hostingView.rootView = newValue }
    }

    init(rootView: ToastView) {
        hostingView = NSHostingView(rootView: rootView)
        hostingView.sizingOptions = [.intrinsicContentSize]
        hostingView.postsFrameChangedNotifications = true

        super.init(
            contentRect: NSRect(x: 0, y: 0, width: Theme.Metrics.toastWidth, height: hostingView.fittingSize.height),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        level = .floating
        isFloatingPanel = true
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        isReleasedWhenClosed = false
        contentView = hostingView

        NotificationCenter.default.addObserver(
            self, selector: #selector(hostingViewFrameChanged),
            name: NSView.frameDidChangeNotification, object: hostingView
        )
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// The screen that owns the menu bar, anchored top right with a 16 pt
    /// inset on both edges. A pure function so the anchoring math is
    /// testable without creating a panel.
    static func targetFrame(in visibleFrame: CGRect, size: CGSize) -> CGRect {
        CGRect(
            x: visibleFrame.maxX - 16 - size.width,
            y: visibleFrame.maxY - 16 - size.height,
            width: size.width,
            height: size.height
        )
    }

    private var fittedSize: CGSize {
        CGSize(width: Theme.Metrics.toastWidth, height: hostingView.fittingSize.height)
    }

    /// Slides in from offscreen right of the final position, over 0.28 s.
    /// Safe to call mid-dismissal, which is what a second capture arriving
    /// during the slide-out does: it restarts from offscreen at zero alpha and
    /// supersedes the running animation.
    func present() {
        guard let screen = NSScreen.screens.first else { return }
        animationGeneration += 1
        let final = Self.targetFrame(in: screen.visibleFrame, size: fittedSize)
        let start = final.offsetBy(dx: final.width + 16, dy: 0)

        setFrame(start, display: false)
        alphaValue = 0
        orderFrontRegardless()

        slide(self, final, 1, 0.28) {}
    }

    /// Reverses `present()` over 0.2 s, then orders out. `completion` runs
    /// only if nothing superseded the slide-out while it was running.
    func dismiss(completion: @escaping () -> Void) {
        animationGeneration += 1
        let generation = animationGeneration

        guard let screen = NSScreen.screens.first else {
            orderOut(nil)
            completion()
            return
        }
        let final = Self.targetFrame(in: screen.visibleFrame, size: fittedSize)
        let offscreen = final.offsetBy(dx: final.width + 16, dy: 0)

        slide(self, offscreen, 0, 0.2) { [weak self] in
            guard let self, self.animationGeneration == generation else { return }
            self.orderOut(nil)
            completion()
        }
    }

    /// Re-anchors in place without animating, for a content swap while
    /// already visible or a thumbnail arriving late.
    func reposition() {
        guard isVisible, let screen = NSScreen.screens.first else { return }
        setFrame(Self.targetFrame(in: screen.visibleFrame, size: fittedSize), display: true)
    }

    @objc private func hostingViewFrameChanged() {
        reposition()
    }
}
