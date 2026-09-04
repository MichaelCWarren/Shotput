import SwiftUI

struct DropdownHeader: View {
    let countText: String
    let onSettings: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 0) {
                Text("Screenshots")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.label)
                Text(countText)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.secondary(0.55))
            }

            Spacer()

            CircleIconButton(systemImage: "gear", action: onSettings)
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 8)
    }
}
