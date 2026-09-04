import SwiftUI

/// Replaces `DropdownFooter.keyHints` in AI mode, and only when there is
/// something to report: a reason descriptions are paused, or a queue still
/// draining. Naming the model on every render told the user nothing they
/// could act on and cost two lines of a short panel; Settings carries the
/// attribution, which is where someone looking for it goes.
struct AIStatusFooter: View {
    let ai: AICoordinator

    var body: some View {
        if let text = Self.text(blockedReason: ai.blockedReason, pending: ai.queue.pendingCount) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "sparkle")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.ai)

                Text(text)
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
    }

    /// Nil when the queue is idle and nothing is blocking it, so the footer
    /// disappears rather than restating a steady state.
    static func text(blockedReason: String?, pending: Int) -> AttributedString? {
        if let blockedReason { return AttributedString(blockedReason) }
        guard pending > 0 else { return nil }
        return AttributedString("Describing \(pending) screenshot\(pending == 1 ? "" : "s")…")
    }
}
