import AppKit
import SwiftUI

/// Hands SwiftUI the AppKit object behind a view when it needs a real one: the
/// window an `NSAlert` sheets onto, or the view an `NSSharingServicePicker`
/// anchors its popover to.
///
/// The callback writes `@State`, which re-renders the parent and calls
/// `updateNSView` again, so reporting unconditionally would feed itself
/// forever. The coordinator remembers what it last handed over and stays quiet
/// until that changes.
struct ViewResolver<Value: AnyObject>: NSViewRepresentable {
    let resolve: (NSView) -> Value?
    let onChange: (Value?) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = ResolvingView()
        // A view has no window until SwiftUI installs it, and nothing
        // promises another render pass after that, so the move into the
        // window has to do the reporting itself.
        view.onMoveToWindow = { [weak coordinator = context.coordinator] view in
            coordinator?.reportResolved(from: view)
        }
        context.coordinator.take(resolve: resolve, onChange: onChange)
        context.coordinator.report(resolve(view), to: onChange)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.take(resolve: resolve, onChange: onChange)
        context.coordinator.report(resolve(nsView), to: onChange)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator {
        private weak var reported: AnyObject?
        private var resolve: ((NSView) -> Value?)?
        private var onChange: ((Value?) -> Void)?

        func report(_ value: Value?, to onChange: @escaping (Value?) -> Void) {
            guard reported !== value else { return }
            reported = value
            // A view-tree pass cannot write state, so land it on the next turn.
            DispatchQueue.main.async { onChange(value) }
        }

        /// Keeps the newest closures, since each render pass builds fresh ones
        /// and the view outlives any single pass.
        func take(resolve: @escaping (NSView) -> Value?, onChange: @escaping (Value?) -> Void) {
            self.resolve = resolve
            self.onChange = onChange
        }

        func reportResolved(from view: NSView) {
            guard let resolve, let onChange else { return }
            report(resolve(view), to: onChange)
        }
    }
}

private final class ResolvingView: NSView {
    var onMoveToWindow: ((NSView) -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        onMoveToWindow?(self)
    }
}
