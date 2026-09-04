import AppKit
import SwiftUI

/// The Shotput mark: four capture brackets around a filled disc. The app icon
/// and the menu bar item render this same view, so `Resources/make-icon.swift`
/// compiles this file too.
struct CaptureGlyph: View {
    /// Side of the bracket frame. Every other measure is a ratio of it.
    let side: CGFloat

    private var lineWidth: CGFloat { side * 0.1455 }
    private var arm: CGFloat { side * 0.3409 }
    private var discSide: CGFloat { side * 0.3864 }

    var body: some View {
        ZStack {
            CaptureBrackets(arm: arm, cornerRadius: lineWidth * 0.85)
                .stroke(style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
            Circle()
                .frame(width: discSide, height: discSide)
        }
        .frame(width: side, height: side)
    }
}

/// Four corner marks of a screen-capture selection.
struct CaptureBrackets: Shape {
    let arm: CGFloat
    let cornerRadius: CGFloat

    func path(in rect: CGRect) -> Path {
        var p = Path()
        for (x, sx) in [(rect.minX, 1.0), (rect.maxX, -1.0)] {
            for (y, sy) in [(rect.minY, 1.0), (rect.maxY, -1.0)] {
                p.move(to: CGPoint(x: x, y: y + sy * arm))
                p.addArc(tangent1End: CGPoint(x: x, y: y),
                         tangent2End: CGPoint(x: x + sx * arm, y: y),
                         radius: cornerRadius)
                p.addLine(to: CGPoint(x: x + sx * arm, y: y))
            }
        }
        return p
    }
}

extension NSImage {
    /// The mark as a menu bar template image, drawn on the 18 pt square
    /// AppKit lays a status item's image out in.
    @MainActor static func captureGlyph() -> NSImage? {
        let canvas: CGFloat = 18
        let renderer = ImageRenderer(content:
            CaptureGlyph(side: 13)
                .foregroundStyle(.black)
                .frame(width: canvas, height: canvas))
        renderer.scale = 2
        guard let cg = renderer.cgImage else { return nil }
        let image = NSImage(cgImage: cg, size: NSSize(width: canvas, height: canvas))
        image.isTemplate = true
        return image
    }
}
