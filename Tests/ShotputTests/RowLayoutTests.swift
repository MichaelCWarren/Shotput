import AppKit
import SwiftUI
import Testing
@testable import Shotput

/// Lays a dropdown row out the way the panel does and reports what actually
/// landed on screen. Nothing here reads the view code: the frames come off
/// the layers SwiftUI rendered into, so a row that reflows when it lights up
/// shows the same numbers a user would see move.
@MainActor
final class RowLayoutHarness<V: View> {
    private let host: NSHostingView<V>
    private let window: NSWindow

    init(_ view: V, width: CGFloat = Theme.Metrics.dropdownWidth - 24) {
        host = NSHostingView(rootView: view)
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: width, height: 200),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.contentView = host
        host.wantsLayer = true
        host.frame = NSRect(x: 0, y: 0, width: width, height: host.fittingSize.height)
        host.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        host.displayIfNeeded()
    }

    var size: CGSize { host.frame.size }

    /// The width the row would take if nothing constrained it.
    var idealWidth: CGFloat { host.fittingSize.width }

    /// One rect per run of text the row draws, in row coordinates. SwiftUI
    /// gives each `Text` a drawing layer of its own; the glyphs inside the
    /// action buttons sit under the glass layer, which this walk skips.
    var textFrames: [CGRect] {
        guard let root = host.layer else { return [] }
        var frames: [CGRect] = []
        collectText(under: root, root: root, into: &frames)
        return frames.sorted { ($0.minY, $0.minX) < ($1.minY, $1.minX) }
    }

    /// The controls the row put on screen. SwiftUI backs a button, and the
    /// describing row's spinner, with a real view.
    var controls: [CGRect] { host.subviews.map(\.frame) }

    /// Where the action buttons start, for a row whose only controls are
    /// those buttons.
    var buttonsStart: CGFloat? { controls.map(\.minX).min() }

    private func collectText(under layer: CALayer, root: CALayer, into frames: inout [CGRect]) {
        for sublayer in layer.sublayers ?? [] {
            let kind = String(describing: type(of: sublayer))
            if kind.contains("SDF") || kind.contains("Backdrop") { continue }
            if kind == "CGDrawingLayer" {
                frames.append(sublayer.convert(sublayer.bounds, to: root))
            }
            collectText(under: sublayer, root: root, into: &frames)
        }
    }
}

@Suite @MainActor struct RowLayoutTests {
    private let width = Theme.Metrics.dropdownWidth - 24
    private let longTitle = "A very long AI generated title that will certainly truncate here"
    private let summary = "A summary line describing the screenshot contents in some detail"

    private func shot(title: String?, summary: String? = nil) -> Screenshot {
        Screenshot(
            url: URL(fileURLWithPath: "/tmp/Screenshot 2026-09-03 at 9.41.02.png"),
            created: Date(timeIntervalSince1970: 1_756_890_062),
            byteSize: 412_000,
            title: title,
            summary: summary
        )
    }

    private func row(_ shot: Screenshot, highlighted: Bool, copied: Bool = false) -> RowLayoutHarness<ScreenshotRow> {
        RowLayoutHarness(
            ScreenshotRow(
                shot: shot,
                meta: "9:41 AM · 412 KB · trashes in 7 d",
                isHighlighted: highlighted,
                isCopied: copied,
                onCopy: {}, onCopyText: {}, onAnnotate: {}
            ),
            width: width
        )
    }

    private func aiRow(_ shot: Screenshot, state: AIState, highlighted: Bool, copied: Bool = false) -> RowLayoutHarness<AIScreenshotRow> {
        let item = AIRowItem(
            screenshot: shot,
            meta: "9:41 AM · 412 KB",
            fill: .none,
            showsSparkle: shot.title != nil,
            state: state
        )
        return RowLayoutHarness(
            AIScreenshotRow(
                item: item,
                isHighlighted: highlighted,
                isCopied: copied,
                onCopy: {}, onCopyText: {}, onAnnotate: {}
            ),
            width: width
        )
    }

    private func expectSameGeometry(
        _ plain: RowLayoutHarness<some View>,
        _ other: RowLayoutHarness<some View>,
        _ what: Comment,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        #expect(plain.size == other.size, what, sourceLocation: sourceLocation)
        #expect(plain.idealWidth == other.idealWidth, what, sourceLocation: sourceLocation)
        #expect(plain.textFrames == other.textFrames, what, sourceLocation: sourceLocation)
    }

    private func expectStable(
        _ plain: RowLayoutHarness<some View>,
        _ highlighted: RowLayoutHarness<some View>,
        _ what: Comment,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        expectSameGeometry(plain, highlighted, what, sourceLocation: sourceLocation)
        // Otherwise a row that simply stopped offering the buttons would
        // satisfy every line above.
        #expect(plain.controls.count < highlighted.controls.count, what, sourceLocation: sourceLocation)
    }

    @Test func highlightingLeavesAPlainRowsTextWhereItWas() {
        let long = shot(title: longTitle)
        expectStable(row(long, highlighted: false), row(long, highlighted: true), "long title")

        let short = shot(title: "Invoice")
        expectStable(row(short, highlighted: false), row(short, highlighted: true), "short title")
    }

    /// Each state brings its own number of buttons and its own text: three
    /// buttons for a queued row, four once the row offers a retry, and two
    /// lines of status where a described row has a summary.
    @Test(arguments: [
        AIState.described,
        .queued,
        .describing,
        .retrying(attempt: 1),
        .gaveUp(reason: "Ollama is not running on localhost:11434", detail: nil),
    ])
    func highlightingLeavesAnAIRowsTextWhereItWas(state: AIState) {
        let described = shot(title: longTitle, summary: summary)
        expectStable(
            aiRow(described, state: state, highlighted: false),
            aiRow(described, state: state, highlighted: true),
            "\(state) with a summary"
        )

        let bare = shot(title: longTitle)
        expectStable(
            aiRow(bare, state: state, highlighted: false),
            aiRow(bare, state: state, highlighted: true),
            "\(state) without a summary"
        )
    }

    /// The Copy pill gives way to a "Copied" badge that is not the width of
    /// the buttons it replaced.
    @Test func copyingLeavesTheTextWhereItWas() {
        let long = shot(title: longTitle, summary: summary)
        expectSameGeometry(
            row(long, highlighted: false),
            row(long, highlighted: true, copied: true),
            "copied plain row"
        )
        expectSameGeometry(
            aiRow(long, state: .described, highlighted: false),
            aiRow(long, state: .described, highlighted: true, copied: true),
            "copied AI row"
        )
    }

    /// The buttons hang over the row rather than pushing the title aside, so
    /// the title has to stop being drawn where they start.
    @Test func aLongTitleFadesOutBeforeTheButtons() throws {
        let long = shot(title: longTitle)
        #expect(row(long, highlighted: false).controls.isEmpty)
        let buttonsStart = try Int(#require(row(long, highlighted: true).buttonsStart))
        let titleBand = 8...24

        let plainInk = ink(in: long, highlighted: false, band: titleBand)
        let highlightedInk = ink(in: long, highlighted: true, band: titleBand)

        #expect(plainInk.contains { $0 > buttonsStart })
        #expect(highlightedInk.allSatisfy { $0 < buttonsStart })
        // Only the run of title under the buttons goes: the fade is a
        // handful of points wide, not half the row.
        #expect((highlightedInk.max() ?? 0) > buttonsStart - 30)
    }

    /// The x positions where the row draws dark pixels, rendered on white so
    /// text is the only thing that is dark.
    private func ink(in shot: Screenshot, highlighted: Bool, band: ClosedRange<Int>) -> [Int] {
        let renderer = ImageRenderer(
            content: ScreenshotRow(
                shot: shot,
                meta: "9:41 AM · 412 KB · trashes in 7 d",
                isHighlighted: highlighted,
                isCopied: false,
                onCopy: {}, onCopyText: {}, onAnnotate: {}
            )
            .frame(width: width)
            .background(Color.white)
            .environment(\.colorScheme, .light)
        )
        renderer.scale = 1
        // The buttons report their width back into the row's state, so the
        // first pass is the one that measures them and the second is the one
        // that knows how much of the title to fade.
        _ = renderer.nsImage
        RunLoop.current.run(until: Date())

        guard let image = renderer.nsImage,
              let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff) else { return [] }
        return (0..<bitmap.pixelsWide).filter { x in
            band.contains { y in
                y < bitmap.pixelsHigh && (bitmap.colorAt(x: x, y: y)?.brightnessComponent ?? 1) < 0.8
            }
        }
    }
}
