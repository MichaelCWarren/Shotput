import SwiftUI

/// Colors, radii and type scale transcribed from the canvas design.
enum Theme {
    static let accent = Color(red: 0x0a / 255, green: 0x63 / 255, blue: 0xc2 / 255)
    static let ai = Color(red: 0x7a / 255, green: 0x4d / 255, blue: 0xd8 / 255)
    static let green = Color(red: 0x34 / 255, green: 0xc7 / 255, blue: 0x59 / 255)
    static let greenText = Color(red: 0x2c / 255, green: 0x9e / 255, blue: 0x46 / 255)
    static let warn = Color(red: 0xf5 / 255, green: 0xb7 / 255, blue: 0x22 / 255)
    static let pin = Color(red: 0xc4 / 255, green: 0x7b / 255, blue: 0x0a / 255)

    static let label = Color(red: 0x1c / 255, green: 0x1c / 255, blue: 0x1e / 255)
    static func secondary(_ opacity: Double) -> Color {
        Color(red: 60 / 255, green: 60 / 255, blue: 67 / 255).opacity(opacity)
    }
    static let fill = Color(red: 120 / 255, green: 120 / 255, blue: 128 / 255)

    /// Neutral fill used behind pills and controls: rgba(120,120,128,.14)
    static func neutral(_ opacity: Double) -> Color { fill.opacity(opacity) }

    enum Radius {
        static let dropdown: CGFloat = 22
        static let window: CGFloat = 16
        static let onboarding: CGFloat = 20
        static let toast: CGFloat = 18
        static let row: CGFloat = 12
        static let aiRow: CGFloat = 14
        static let tile: CGFloat = 10
        static let group: CGFloat = 14
    }

    enum Metrics {
        static let dropdownWidth: CGFloat = 372
        static let settingsWidth: CGFloat = 480
        static let libraryWidth: CGFloat = 690
        static let onboardingWidth: CGFloat = 440
        static let toastWidth: CGFloat = 330
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
    var body: some View {
        Text(text)
            .font(.system(size: size, weight: .medium, design: .monospaced))
            .foregroundStyle(Theme.secondary(0.65))
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(Theme.neutral(0.14), in: RoundedRectangle(cornerRadius: 4))
    }
}

/// Grouped-settings container: `.row` in the design.
struct SettingsGroup<Content: View>: View {
    var radius: CGFloat = Theme.Radius.group
    @ViewBuilder var content: Content
    var body: some View {
        VStack(spacing: 0) { content }
            .background(.white.opacity(0.6), in: RoundedRectangle(cornerRadius: radius))
            .overlay(
                RoundedRectangle(cornerRadius: radius)
                    .strokeBorder(.black.opacity(0.07), lineWidth: 0.5)
            )
    }
}

/// Hairline divider inset from the leading edge, matching `.div`.
struct RowDivider: View {
    var body: some View {
        Rectangle()
            .fill(.black.opacity(0.08))
            .frame(height: 0.5)
            .padding(.leading, 14)
    }
}

/// Filled pill button used for Copy / Grant / Continue / library footer.
/// The size defaults match the dropdown's 24pt pill; the library footer uses
/// height 26 / fontSize 11.5, and the toast uses height 22.
struct PillButton: View {
    let title: String
    var systemImage: String?
    var prominent: Bool = false
    var enabled: Bool = true
    var height: CGFloat = 24
    var fontSize: CGFloat = 11
    var weight: Font.Weight = .semibold
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let systemImage {
                    Image(systemName: systemImage).font(.system(size: fontSize * 0.82, weight: .semibold))
                }
                Text(title).font(.system(size: fontSize, weight: weight))
            }
            .foregroundStyle(prominent ? .white : Theme.label)
            .padding(.horizontal, 10)
            .frame(height: height)
            .background(
                prominent ? AnyShapeStyle(Theme.accent.opacity(0.92)) : AnyShapeStyle(Theme.neutral(0.16)),
                in: Capsule()
            )
            .opacity(enabled ? 1 : 0.45)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }
}

/// Circular icon button (search / gear in the dropdown header).
struct CircleIconButton: View {
    let systemImage: String
    var diameter: CGFloat = 26
    var active: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: diameter * 0.44, weight: .medium))
                .foregroundStyle(active ? Color.white : Theme.secondary(0.7))
                .frame(width: diameter, height: diameter)
                .background(
                    active ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(Theme.neutral(0.14)),
                    in: Circle()
                )
        }
        .buttonStyle(.plain)
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
