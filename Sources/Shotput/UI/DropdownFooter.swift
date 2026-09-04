import SwiftUI

enum DropdownFooter {
    struct keyHints: View {
        var body: some View {
            // 10, not the design's 14, and a leading frame rather than a
            // trailing Spacer whose gap would count as a fifth: at 10 the four
            // hints need 370 of the dropdown's 372pt, and any wider gap wraps
            // the last hint onto a second line.
            HStack(spacing: 10) {
                HStack(spacing: 5) {
                    KeyCap(text: "⏎")
                    Text("copy")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.secondary(0.55))
                }

                HStack(spacing: 5) {
                    KeyCap(text: "⌥⏎")
                    Text("copy text")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.secondary(0.55))
                }

                HStack(spacing: 5) {
                    KeyCap(text: "space")
                    Text("preview")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.secondary(0.55))
                }

                Text("drag row → any app")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.secondary(0.55))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
            .background(.quinary)
            .topHairline()
            .padding(.top, 8)
        }
    }

    struct cleanup: View {
        let text: String
        let onOpenLibrary: () -> Void

        var body: some View {
            HStack(spacing: 6) {
                Image(systemName: "clock.badge")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.secondary(0.55))
                Text(text)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.secondary(0.6))

                Spacer()

                Button("Open Library", action: onOpenLibrary)
                    .font(.system(size: 11, weight: .medium))
                    .buttonStyle(.link)
            }
            .padding(.horizontal, 16)
            .padding(.top, 10)
            .padding(.bottom, 12)
            .topHairline()
        }
    }
}
