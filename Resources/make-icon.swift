// Generates Resources/AppIcon.icns. Run: ./Resources/make-icon.sh
//
// Geometry was measured off /System/Applications/{Preview,Notes}.app icons on
// macOS 26.6: an 824/1024 body on a continuous-corner rounded square whose
// radius is 22.94% of the body, with a soft drop shadow filling the margin.
import AppKit
import SwiftUI

struct IconView: View {
    let s: CGFloat

    private var bodySide: CGFloat { s * 824 / 1024 }
    private var frameSide: CGFloat { s * 0.44 }
    private var lineWidth: CGFloat { s * 0.064 }
    private var arm: CGFloat { s * 0.150 }
    private var discSide: CGFloat { s * 0.17 }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: bodySide * 0.2294, style: .continuous)
                .fill(LinearGradient(
                    colors: [Color(red: 0.231, green: 0.576, blue: 0.925),
                             Color(red: 0.039, green: 0.373, blue: 0.749)],
                    startPoint: .top, endPoint: .bottom))
                .overlay(
                    RoundedRectangle(cornerRadius: bodySide * 0.2294, style: .continuous)
                        .strokeBorder(LinearGradient(
                            colors: [.white.opacity(0.45), .white.opacity(0.0)],
                            startPoint: .top, endPoint: .bottom), lineWidth: s * 0.005))
                .frame(width: bodySide, height: bodySide)
                .shadow(color: .black.opacity(0.22), radius: s * 0.030, y: s * 0.010)

            CaptureBrackets(arm: arm, cornerRadius: lineWidth * 0.85)
                .stroke(style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .foregroundStyle(.white)
                .frame(width: frameSide, height: frameSide)

            Circle()
                .fill(.white)
                .frame(width: discSide, height: discSide)
        }
        .frame(width: s, height: s)
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

@main @MainActor enum MakeIcon {
    static func main() throws {
        let out = URL(fileURLWithPath: CommandLine.arguments[1])
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

        for (nominal, scale) in [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1),
                                 (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)] {
            let pixels = CGFloat(nominal * scale)
            let renderer = ImageRenderer(content: IconView(s: pixels))
            renderer.scale = 1
            guard let cg = renderer.cgImage else { fatalError("render failed at \(pixels)") }
            let rep = NSBitmapImageRep(cgImage: cg)
            rep.size = NSSize(width: pixels, height: pixels)
            guard let png = rep.representation(using: .png, properties: [:]) else {
                fatalError("png encode failed at \(pixels)")
            }
            let suffix = scale == 2 ? "@2x" : ""
            try png.write(to: out.appendingPathComponent("icon_\(nominal)x\(nominal)\(suffix).png"))
        }
    }
}
