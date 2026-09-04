import AppKit
import SwiftUI

/// The extra button an AI row offers beside Copy.
enum AIRowAction: Equatable {
    case none
    /// Described already: throw the description away and describe it again.
    case reindex
    /// Gave up: send it back through the queue.
    case retry

    var help: String? {
        switch self {
        case .none: nil
        case .reindex: "Describe again"
        case .retry: "Try describing again"
        }
    }
}

/// What one screenshot's `AIState` looks like in a row: an optional status
/// line under the meta, plus the action the hover cluster offers.
struct AIRowStatus: Equatable {
    var text: String?
    var symbol: String?
    /// Spinner in place of `symbol`.
    var isWorking = false
    var isWarning = false
    /// What `.help()` shows: the reason in full, for the rows whose line
    /// truncates it.
    var detail: String?
    var action: AIRowAction = .none
    /// The reason is worth more than the capture time on a 372pt row, so it
    /// takes the meta line for itself.
    var ownsMetaLine = false
    /// The previous title stays in the store until a new description lands,
    /// so a row on its way through the queue would otherwise present a stale
    /// title as the current one.
    var dimsTitle = false

    @MainActor
    init(state: AIState) {
        switch state {
        case .off:
            break
        case .described:
            action = .reindex
        case .queued:
            text = "Queued"
            symbol = "clock"
            dimsTitle = true
        case .describing:
            text = "Describing…"
            isWorking = true
            dimsTitle = true
        case .retrying(let attempt):
            text = "Retrying · attempt \(attempt + 1) of \(AIQueue.maxAttempts)"
            symbol = "arrow.clockwise"
            isWarning = true
            dimsTitle = true
        case .gaveUp(let reason, let tooltip):
            text = "Couldn't describe · \(reason)"
            symbol = "exclamationmark.triangle.fill"
            isWarning = true
            // The queue clips a long stored reason for display and moves the
            // whole thing here, so the tooltip is the only place it survives.
            detail = tooltip ?? reason
            action = .retry
            ownsMetaLine = true
            // Reachable with a title: a re-index drops the index record
            // first, so three failed attempts leave the old title on screen
            // with nothing behind it.
            dimsTitle = true
        }
    }
}

/// The 1b row body: title + sparkle, description, meta. Same action set and
/// drag behavior as the 1a `ScreenshotRow`, just a different layout and an
/// `AIRowItem`-driven background instead of a plain highlight.
struct AIScreenshotRow: View {
    let item: AIRowItem
    let isHighlighted: Bool
    let isCopied: Bool
    let onCopy: () -> Void
    let onCopyText: () -> Void
    let onAnnotate: () -> Void
    var onReindex: () -> Void = {}
    var onRetry: () -> Void = {}

    @State private var loadedThumbnail: NSImage?

    private var shot: Screenshot { item.screenshot }

    var body: some View {
        let status = AIRowStatus(state: item.state)
        HStack(alignment: .top, spacing: 10) {
            ScreenshotThumbnail(url: shot.url, style: .aiRow, loaded: $loadedThumbnail)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(shot.displayName)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(status.dimsTitle && shot.title != nil ? Theme.secondary(0.55) : Theme.label)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if item.showsSparkle {
                        SparkleMark(size: 9)
                            .fixedSize()
                    }
                }

                // One line of description here, the whole of it in the
                // Library: this row is for recognising a screenshot at a
                // glance, not for reading about it.
                if let summary = shot.summary {
                    Text(summary)
                        .font(.system(size: 10.5))
                        .foregroundStyle(Theme.secondary(0.65))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .help(summary)
                }

                HStack(spacing: 5) {
                    if !status.ownsMetaLine {
                        Text(item.meta)
                            .font(.system(size: 9.5))
                            .foregroundStyle(Theme.secondary(0.45))
                            .fixedSize()
                    }

                    stateMarker(status)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .rowActions(.topTrailing) {
                ScreenshotRowActions(
                    isHighlighted: isHighlighted,
                    isCopied: isCopied,
                    aiAction: status.action,
                    onCopy: onCopy,
                    onCopyText: onCopyText,
                    onAnnotate: onAnnotate,
                    onAIAction: status.action == .retry ? onRetry : onReindex
                )
            }
        }
        .contentShape(Rectangle())
        .padding(8)
        .background(backgroundFill, in: RoundedRectangle(cornerRadius: Theme.Radius.aiRow))
        .onTapGesture {
            onCopy()
        }
        .screenshotDrag(shot, thumbnail: loadedThumbnail)
    }

    /// Shares the meta line rather than taking one of its own: the row's job
    /// is to fit more screenshots on screen, not more words per screenshot.
    @ViewBuilder
    private func stateMarker(_ status: AIRowStatus) -> some View {
        if let text = status.text {
            let marker = HStack(spacing: 3) {
                if status.isWorking {
                    ProgressView()
                        .controlSize(.mini)
                        .scaleEffect(0.6)
                        .frame(width: 9, height: 9)
                } else if let symbol = status.symbol {
                    Image(systemName: symbol)
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(status.isWarning ? Theme.warn : Theme.secondary(0.45))
                }

                Text(text)
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(Theme.secondary(status.isWarning ? 0.75 : 0.5))
                    // The second line is free on the one state that needs
                    // it: a given-up screenshot has no description, so its
                    // text column is shorter than the thumbnail beside it.
                    .lineLimit(status.ownsMetaLine ? 2 : 1)
                    .truncationMode(.tail)
            }

            if let detail = status.detail {
                marker.help(detail)
            } else {
                marker
            }
        }
    }

    private var backgroundFill: Color {
        switch item.fill {
        case .top: Theme.ai.opacity(0.10)
        case .other: Theme.ai.opacity(0.06)
        case .none: isHighlighted ? Theme.neutral(0.13) : Color.clear
        }
    }
}
