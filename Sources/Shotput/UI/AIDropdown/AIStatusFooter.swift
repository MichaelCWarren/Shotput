import SwiftUI

/// Replaces `DropdownFooter.keyHints` in AI mode. Reads `ai.provider`,
/// `ai.blockedReason` and `ai.queue.pendingCount` fresh on every render so
/// cloud gating and queue drain show up without reopening the panel.
struct AIStatusFooter: View {
    let ai: AICoordinator

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "sparkle")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.ai)

            Text(Self.text(credit: ai.provider?.credit, blockedReason: ai.blockedReason, pending: ai.queue.pendingCount))
                .font(.system(size: 10.5))
                .lineSpacing(10.5 * 0.4)
                .foregroundStyle(Theme.secondary(0.7))

            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 12)
        .background(Theme.ai.opacity(0.08))
        .topHairline()
        .padding(.top, 6)
    }

    static func text(credit: String?, blockedReason: String?, pending: Int) -> AttributedString {
        guard let credit else {
            return AttributedString(blockedReason ?? "AI descriptions paused")
        }

        var boldCredit = AttributedString(credit)
        boldCredit.inlinePresentationIntent = .stronglyEmphasized

        var result = AttributedString("Titles & descriptions by ") + boldCredit + AttributedString(" · indexed locally")
        if pending > 0 {
            result += AttributedString(" · \(pending) pending")
        }
        return result
    }
}
