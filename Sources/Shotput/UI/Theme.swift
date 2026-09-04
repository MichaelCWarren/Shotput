import AppKit
import SwiftUI

/// Colors, radii and type scale transcribed from the canvas design.
enum Theme {
    static let accent = Color(red: 0x0a / 255, green: 0x63 / 255, blue: 0xc2 / 255)
    static let ai = Color(red: 0x7a / 255, green: 0x4d / 255, blue: 0xd8 / 255)
    static let green = Color(red: 0x34 / 255, green: 0xc7 / 255, blue: 0x59 / 255)
    static let greenText = Color(red: 0x2c / 255, green: 0x9e / 255, blue: 0x46 / 255)
    static let warn = Color(red: 0xf5 / 255, green: 0xb7 / 255, blue: 0x22 / 255)
    static let pin = Color(red: 0xc4 / 255, green: 0x7b / 255, blue: 0x0a / 255)

    /// The design's #1c1c1e / #3c3c43 text greys are Apple's light-appearance
    /// label colours written out as literals, so they cannot follow the
    /// appearance. The `opacity` the call sites pass is the design's own
    /// strength ladder and stays a plain multiplier.
    static let label = Color.primary
    static func secondary(_ opacity: Double) -> Color { label.opacity(opacity) }

    static let fill = Color(red: 120 / 255, green: 120 / 255, blue: 128 / 255)

    /// Neutral fill used behind pills and controls: rgba(120,120,128,.14)
    static func neutral(_ opacity: Double) -> Color { fill.opacity(opacity) }

    /// Windows keep their radius at or under the 16 pt macOS rounds a titled
    /// window's own frame at, so a clip corner never cuts inside the system
    /// one and leaves a notch. The borderless panels are unconstrained.
    enum Radius {
        static let dropdown: CGFloat = 16
        static let window: CGFloat = 12
        static let onboarding: CGFloat = 14
        static let toast: CGFloat = 13
        static let row: CGFloat = 9
        static let aiRow: CGFloat = 10
        static let tile: CGFloat = 8
        static let group: CGFloat = 10
    }

    enum Metrics {
        static let dropdownWidth: CGFloat = 372
        static let settingsWidth: CGFloat = 480
        static let libraryWidth: CGFloat = 690
        static let onboardingWidth: CGFloat = 440
        static let toastWidth: CGFloat = 330
    }

    /// The frosted backdrop every window and panel draws behind its content.
    /// Plain system glass, the same material the dropdown applies directly:
    /// a tint here made the windows read as a different surface to it.
    static func glassBackground(radius: CGFloat) -> some View {
        Color.clear
            .glassEffect(.regular, in: .rect(cornerRadius: radius))
    }
}

/// The uppercase grey section label used throughout (TODAY, STORAGE, …).
struct SectionLabel: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .kerning(0.22)
            .foregroundStyle(Theme.secondary(0.5))
    }
}

/// Keyboard-cap styling from `.kbd` in the design.
struct KeyCap: View {
    let text: String
    var size: CGFloat = 9.5
    var horizontalPadding: CGFloat = 5
    var verticalPadding: CGFloat = 2
    var body: some View {
        Text(text)
            // Not monospaced: that face hands ⌃ and ⇧ the same advance as a
            // letter, which shrinks them and, at 11pt, leaves ⇧'s ink wider
            // than the cell it sits in, overlapping the glyph after it.
            .font(.system(size: size, weight: .medium))
            .foregroundStyle(Theme.secondary(0.65))
            .padding(.horizontal, horizontalPadding)
            .padding(.vertical, verticalPadding)
            .background(Theme.neutral(0.14), in: RoundedRectangle(cornerRadius: 4))
    }
}

/// Grouped-settings container: `.row` in the design. GroupBox is the system
/// equivalent but supplies its own content padding, which would inset the
/// full-bleed row dividers, and its corner radius is not settable.
struct SettingsGroup<Content: View>: View {
    var radius: CGFloat = Theme.Radius.group
    @ViewBuilder var content: Content
    var body: some View {
        VStack(spacing: 0) { content }
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.6), in: RoundedRectangle(cornerRadius: radius))
            .overlay(
                RoundedRectangle(cornerRadius: radius)
                    .strokeBorder(.separator, lineWidth: 0.5)
            )
    }
}

/// The chrome behind the Library's search field, which has no SwiftUI
/// equivalent: `.searchable` needs a navigation container the window doesn't
/// have, and no text-field style draws a search glyph.
private struct PopupChrome: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 12)
            .frame(height: 28)
            .background(Theme.neutral(0.14), in: RoundedRectangle(cornerRadius: 9))
            .overlay(
                RoundedRectangle(cornerRadius: 9)
                    .strokeBorder(.separator, lineWidth: 0.5)
            )
    }
}

extension View {
    func popupChrome() -> some View { modifier(PopupChrome()) }

    /// Hairline along the top edge, separating a footer from the list above.
    func topHairline() -> some View {
        overlay(Divider(), alignment: .top)
    }
}

/// Divider inset from the leading edge, matching `.div`.
struct RowDivider: View {
    var body: some View {
        Divider().padding(.leading, 14)
    }
}

/// Capsule button used for Copy / Grant / library footer / toast actions.
/// `.glass` and `.glassProminent` pick their own metrics, so `height` selects
/// a control size rather than setting a frame: 22 in the toast is the small
/// size, 24-26 elsewhere is regular.
struct PillButton: View {
    let title: String
    var systemImage: String?
    var prominent: Bool = false
    var enabled: Bool = true
    var height: CGFloat = 24
    var fontSize: CGFloat = 11
    var weight: Font.Weight = .semibold
    let action: () -> Void

    @ViewBuilder
    var body: some View {
        if prominent {
            button.buttonStyle(.glassProminent)
        } else {
            button.buttonStyle(.glass)
        }
    }

    private var button: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let systemImage {
                    Image(systemName: systemImage).font(.system(size: fontSize * 0.82, weight: .semibold))
                }
                Text(title).font(.system(size: fontSize, weight: weight))
            }
        }
        .buttonBorderShape(.capsule)
        .controlSize(height < 24 ? .small : .regular)
        .disabled(!enabled)
    }
}

/// Circular icon button. `.glass` picks its own metrics, so `diameter`
/// selects a control size rather than setting a frame.
struct CircleIconButton: View {
    var systemImage: String?
    var text: String?
    var diameter: CGFloat = 26
    var active: Bool = false
    let action: () -> Void

    init(systemImage: String, diameter: CGFloat = 26, active: Bool = false, action: @escaping () -> Void) {
        self.systemImage = systemImage
        self.diameter = diameter
        self.active = active
        self.action = action
    }

    init(text: String, diameter: CGFloat = 26, active: Bool = false, action: @escaping () -> Void) {
        self.text = text
        self.diameter = diameter
        self.active = active
        self.action = action
    }

    @ViewBuilder
    var body: some View {
        if active {
            button.buttonStyle(.glassProminent)
        } else {
            button.buttonStyle(.glass)
        }
    }

    private var button: some View {
        Button(action: action) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: diameter * 0.44, weight: .medium))
            } else if let text {
                Text(text)
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
            }
        }
        .buttonBorderShape(.circle)
        .controlSize(diameter < 24 ? .small : .regular)
    }
}

/// The rounded thumbnail every screenshot row draws: a neutral placeholder
/// until `ThumbnailCache` answers. `loaded` is bound back out for the rows
/// that hand the same image to their drag preview.
struct ScreenshotThumbnail: View {
    enum Style {
        case row, aiRow, libraryRow

        var size: CGSize {
            switch self {
            case .row, .libraryRow: CGSize(width: 56, height: 36)
            case .aiRow: CGSize(width: 64, height: 42)
            }
        }

        var cornerRadius: CGFloat {
            switch self {
            case .row, .libraryRow: 6
            case .aiRow: 7
            }
        }
    }

    let url: URL
    let style: Style
    @Binding var loaded: NSImage?

    var body: some View {
        switch style {
        case .row:
            image.shadow(color: imageShadow, radius: 0, x: 0, y: 0.5)
        case .aiRow:
            image
                .shadow(color: imageShadow, radius: 0, x: 0, y: 0.5)
                .shadow(color: imageShadow, radius: 3, x: 0, y: 1)
        case .libraryRow:
            image
                .overlay(
                    RoundedRectangle(cornerRadius: style.cornerRadius)
                        .strokeBorder(.separator, lineWidth: 0.5)
                )
                .shadow(color: .black.opacity(0.1), radius: 3, x: 0, y: 1)
        }
    }

    private var image: some View {
        Group {
            if let loaded {
                Image(nsImage: loaded)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Theme.neutral(0.14)
            }
        }
        .frame(width: style.size.width, height: style.size.height)
        .clipShape(RoundedRectangle(cornerRadius: style.cornerRadius))
        .task(id: url) {
            loaded = await ThumbnailCache.shared.thumbnail(for: url)
        }
    }

    /// The dropdown rows shadow the picture, not the well it sits in, so an
    /// unloaded placeholder stays flat.
    private var imageShadow: Color {
        loaded == nil ? .clear : .black.opacity(0.1)
    }
}

/// The AI sparkle mark used beside generated titles.
struct SparkleMark: View {
    var size: CGFloat = 9
    var body: some View {
        Image(systemName: "sparkle")
            .font(.system(size: size, weight: .semibold))
            .foregroundStyle(Theme.ai)
    }
}
