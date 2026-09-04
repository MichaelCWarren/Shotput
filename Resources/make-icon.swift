// Generates Resources/AppIcon.icns. Run: ./Resources/make-icon.sh
//
// The mark itself lives in Sources/Shotput/UI/CaptureGlyph.swift, which the
// menu bar item draws too; make-icon.sh compiles it alongside this file.
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

            CaptureGlyph(side: frameSide)
                .foregroundStyle(.white)
        }
        .frame(width: s, height: s)
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
