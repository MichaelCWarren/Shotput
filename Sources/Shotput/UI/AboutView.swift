import AppKit
import SwiftUI

/// Version line for the About window. Read from the bundle rather than a
/// constant so a build can never disagree with its own Info.plist; the
/// bundle is a parameter because under `swift test` `Bundle.main` is the
/// test runner, which carries neither key.
enum AppVersion {
    static func text(for bundle: Bundle = .main) -> String {
        text(
            short: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
            build: bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        )
    }

    /// The build number is dropped when it repeats the marketing version,
    /// which is the usual state of a hand-edited Info.plist.
    static func text(short: String?, build: String?) -> String {
        guard let short, !short.isEmpty else { return "Version unknown" }
        guard let build, !build.isEmpty, build != short else { return "Version \(short)" }
        return "Version \(short) (\(build))"
    }
}

/// The scoreboard under the app name: how much of the disk this habit has
/// eaten, and how much of that the user has declared too precious to delete.
func aboutStats(for shots: [Screenshot]) -> (captured: String, size: String, pinned: String) {
    let bytes = shots.reduce(0) { $0 + $1.byteSize }
    return (
        captured: shots.count.formatted(),
        // ByteCountFormatter writes zero bytes as "Zero KB", which reads as a
        // bug rather than an empty folder.
        size: bytes == 0 ? "0 KB" : ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file),
        pinned: shots.count(where: \.isPinned).formatted()
    )
}

/// The line that reads the collection back to its owner. Graded, so a fresh
/// install isn't accused of hoarding and a four-figure folder doesn't get
/// away with it.
func hoardQuip(count: Int) -> String {
    switch count {
    case 0: "Nothing captured yet. Enjoy the silence."
    case 1..<25: "A modest start. These things compound."
    case 25..<200: "Comfortably past the point of naming them."
    case 200..<1000: "You could have written it down instead."
    default: "This is a filing system in the same way a landfill is."
    }
}

/// Tapping the mark cycles these. There is no other way through them, which
/// is the joke.
let aboutTaglines = [
    "Screenshots you take, use once, and never delete.",
    "A menu bar icon between you and 4,000 unnamed PNGs.",
    "Built because dragging from the Desktop is beneath us.",
    "Now with AI, so a robot can also not read your screenshots."
]

/// The About window: the mark, the version, and an honest look at the folder.
struct AboutView: View {
    @Environment(ScreenshotStore.self) private var store

    @State private var taglineIndex = 0
    @State private var hostWindow: NSWindow?

    var body: some View {
        ZStack(alignment: .top) {
            Theme.glassBackground(radius: Theme.Radius.onboarding)

            VStack(spacing: 0) {
                header
                scoreboard
                footer
            }
        }
        .ignoresSafeArea()
        .frame(width: Theme.Metrics.aboutWidth)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.onboarding))
        .background(ViewResolver(resolve: { $0.window }, onChange: { hostWindow = $0 }))
    }

    private var header: some View {
        VStack(spacing: 6) {
            CaptureGlyph(side: 34)
                .foregroundStyle(.white)
                .frame(width: 64, height: 64)
                .background(
                    LinearGradient(
                        colors: [Color(red: 0x4d / 255, green: 0xa3 / 255, blue: 0xe0 / 255), Theme.accent],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    ),
                    in: RoundedRectangle(cornerRadius: 16)
                )
                .onTapGesture { taglineIndex += 1 }
                .padding(.bottom, 6)

            Text("Shotput")
                .font(.system(size: 21, weight: .bold))
                .kerning(-0.2)
                .foregroundStyle(Theme.label)

            Text(AppVersion.text())
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(Theme.secondary(0.5))

            Text(aboutTaglines[taglineIndex % aboutTaglines.count])
                .font(.system(size: 12.5))
                .lineSpacing(5)
                .multilineTextAlignment(.center)
                .foregroundStyle(Theme.secondary(0.65))
                // Two lines whatever the tagline, so tapping the mark cycles
                // the text without resizing a window sized once on open.
                .lineLimit(2, reservesSpace: true)
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: 280)
                .padding(.top, 4)
        }
        .padding(.top, 50)
        .padding(.horizontal, 30)
        .padding(.bottom, 18)
    }

    private var scoreboard: some View {
        let stats = aboutStats(for: store.shots)
        return VStack(spacing: 10) {
            SettingsGroup {
                HStack(spacing: 0) {
                    stat(stats.captured, "captured")
                    Divider().frame(height: 26)
                    stat(stats.size, "on disk")
                    Divider().frame(height: 26)
                    stat(stats.pinned, "pinned")
                }
                .padding(.vertical, 12)
            }

            Text(hoardQuip(count: store.shots.count))
                .font(.system(size: 10.5))
                .multilineTextAlignment(.center)
                .foregroundStyle(Theme.secondary(0.5))
        }
        .padding(.horizontal, 26)
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(spacing: 3) {
            Text(value)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Theme.label)
            Text(label.uppercased())
                .font(.system(size: 9.5, weight: .semibold))
                .kerning(0.3)
                .foregroundStyle(Theme.secondary(0.45))
        }
        .frame(maxWidth: .infinity)
    }

    private var footer: some View {
        VStack(spacing: 10) {
            Text("No cloud, no telemetry, no account. Your screenshots stay as private as whatever you took them of.")
                .font(.system(size: 10.5))
                .lineSpacing(3)
                .multilineTextAlignment(.center)
                .foregroundStyle(Theme.secondary(0.45))
                .frame(maxWidth: 290)

            PillButton(title: "Fine", prominent: true, height: 26, fontSize: 12) {
                hostWindow?.close()
            }
        }
        .padding(.horizontal, 26)
        .padding(.top, 16)
        .padding(.bottom, 24)
    }
}
