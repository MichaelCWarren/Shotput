import AppKit
import SwiftUI

/// What the Library shows for a query: every screenshot whose text contains
/// it, plus whatever the semantic pass matched. The two are unioned rather
/// than one replacing the other, because the substring pass answers on the
/// keystroke while the semantic pass lands a debounce later, and a row that
/// plainly contains what was typed must not vanish in between. An empty
/// `semanticIDs` is the AI-off case and the not-yet-landed case alike.
func searchedDays(_ days: [ScreenshotDay], query: String, semanticIDs: Set<URL>) -> [ScreenshotDay] {
    let substring = filterDays(days, query: query)
    guard !semanticIDs.isEmpty else { return substring }
    return filterDays(days, keeping: semanticIDs.union(substring.flatMap(\.shots).map(\.id)))
}

/// The days that hold `ids`, dropping every other screenshot and any day
/// left with none, the way `filterDays(_:query:)` does for a substring.
func filterDays(_ days: [ScreenshotDay], keeping ids: Set<URL>) -> [ScreenshotDay] {
    days.compactMap { day in
        let shots = day.shots.filter { ids.contains($0.id) }
        guard !shots.isEmpty else { return nil }
        return ScreenshotDay(id: day.id, label: day.label, shots: shots)
    }
}

/// What a drag started on `draggedID` carries: the whole selection when the
/// dragged screenshot is part of it, otherwise that screenshot alone. The
/// second half is the one that matters — dragging a tile outside the
/// selection must not drop the selection's files on the target.
@MainActor
func dragPayload(for draggedID: URL, selection: Set<URL>, in days: [ScreenshotDay]) -> [DraggedScreenshot] {
    guard selection.contains(draggedID) else {
        return draggedScreenshots(for: [draggedID], in: days)
    }
    let ids = days.flatMap(\.shots).map(\.id).filter(selection.contains)
    return draggedScreenshots(for: ids, in: days)
}

/// The payload for a drag of `ids`, in on-screen order and skipping any
/// screenshot the store has since dropped.
@MainActor
func draggedScreenshots(for ids: [URL], in days: [ScreenshotDay]) -> [DraggedScreenshot] {
    var shots: [URL: Screenshot] = [:]
    for day in days {
        for shot in day.shots where shots[shot.id] == nil {
            shots[shot.id] = shot
        }
    }
    return ids.compactMap { id in
        shots[id].map(DraggedScreenshot.init)
    }
}

/// The AI context-menu items act on the whole selection, like Copy and Pin,
/// so the count goes in the label rather than leaving it to be guessed.
func reindexMenuLabel(count: Int) -> String {
    count > 1 ? "Describe \(count) Again with AI" : "Describe Again with AI"
}

func retryMenuLabel(count: Int) -> String {
    count > 1 ? "Retry \(count) AI Descriptions" : "Retry AI Description"
}

/// Grid tile: 16:10 thumbnail with pin/selected/AI badges, the AI title and
/// the caption below.
struct LibraryTile: View {
    let shot: Screenshot
    let isSelected: Bool
    let ai: AICoordinator?

    /// Roughly a display's shape, so a screenshot fills the box without much
    /// of a crop, and the tile grows with its column instead of letterboxing.
    private static let aspect: CGFloat = 16.0 / 10.0

    @State private var thumbnail: NSImage?

    var body: some View {
        let state = ai?.state(for: shot.url) ?? .off
        let status = AIRowStatus(state: state)
        let gaveUp = switch state {
        case .gaveUp: true
        default: false
        }

        VStack(alignment: .leading, spacing: 4) {
            Color.clear
                .aspectRatio(Self.aspect, contentMode: .fit)
                .overlay {
                    if let thumbnail {
                        Image(nsImage: thumbnail)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    } else {
                        Theme.neutral(0.14)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.tile))
                .clipped()
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radius.tile)
                        .strokeBorder(
                            isSelected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.separator),
                            lineWidth: isSelected ? 2.5 : 0.5
                        )
                )
                .shadow(color: .black.opacity(isSelected ? 0.15 : 0.12), radius: 4, x: 0, y: 1)
                .overlay(alignment: .topLeading) {
                    if shot.isPinned {
                        LibraryBadge(systemImage: "pin.fill", foreground: Theme.pin, background: .white.opacity(0.85), shadowOpacity: 0.2)
                            .padding(5)
                    }
                }
                .overlay(alignment: .topTrailing) {
                    if isSelected {
                        LibraryBadge(systemImage: "checkmark", foreground: .white, background: .accentColor, shadowOpacity: 0.25)
                            .padding(5)
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    LibraryAIBadge(status: status)
                        .padding(5)
                }

            VStack(alignment: .leading, spacing: 1) {
                // A failure takes the line even when a title is there: that
                // title belongs to the run before the one that failed.
                if let title = shot.title, !gaveUp {
                    HStack(spacing: 4) {
                        Text(title)
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(status.dimsTitle ? Theme.secondary(0.4) : Theme.label)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        SparkleMark(size: 8)
                            .fixedSize()
                            .opacity(status.dimsTitle ? 0.4 : 1)
                    }
                } else if let text = status.text {
                    Text(text)
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundStyle(Theme.secondary(status.isWarning ? 0.75 : 0.5))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }

                Text(shot.captionText)
                    .font(.system(size: 9.5))
                    .foregroundStyle(Theme.secondary(0.6))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .contentShape(Rectangle())
        .task(id: shot.url) {
            thumbnail = await ThumbnailCache.shared.thumbnail(for: shot.url)
        }
    }
}

/// List row: the 1a dropdown row's measurements, plus the AI description and
/// the badges the dropdown row never needed.
struct LibraryRow: View {
    let shot: Screenshot
    let isSelected: Bool
    let ai: AICoordinator?

    @State private var thumbnail: NSImage?

    var body: some View {
        let status = AIRowStatus(state: ai?.state(for: shot.url) ?? .off)
        let dimmed = status.dimsTitle && shot.title != nil

        HStack(alignment: .top, spacing: 10) {
            ScreenshotThumbnail(url: shot.url, style: .libraryRow, loaded: $thumbnail)

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Text(shot.displayName)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(dimmed ? Theme.secondary(0.45) : Theme.label)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if shot.title != nil {
                        SparkleMark(size: 9)
                            .fixedSize()
                            .opacity(dimmed ? 0.4 : 1)
                    }
                }

                // The Library is where a description gets read, so the row
                // takes as many lines as the summary needs. The dropdown is
                // the glance surface and keeps its own shorter text.
                if let summary = shot.summary {
                    Text(summary)
                        .font(.system(size: 10.5))
                        .lineSpacing(10.5 * 0.4)
                        .foregroundStyle(Theme.secondary(dimmed ? 0.35 : 0.65))
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack(spacing: 5) {
                    Text("\(shot.timeText) · \(shot.sizeText)")
                        .font(.system(size: 10.5))
                        .foregroundStyle(Theme.secondary(0.55))
                        .lineLimit(1)
                        .fixedSize()

                    if shot.isPinned {
                        LibraryBadge(systemImage: "pin.fill", foreground: Theme.pin, background: .white.opacity(0.85), shadowOpacity: 0.2)
                    }

                    LibraryAIStatusChip(status: status)
                }
            }

            Spacer(minLength: 8)

            if isSelected {
                LibraryBadge(systemImage: "checkmark", foreground: .white, background: .accentColor, shadowOpacity: 0.25)
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .background(
            isSelected ? Color.accentColor.opacity(0.12) : Color.clear,
            in: RoundedRectangle(cornerRadius: Theme.Radius.row)
        )
        .contentShape(Rectangle())
    }
}

/// The status a list row carries beside its time and size. The give-up
/// reason is on the line itself, so the user doesn't have to hover to learn
/// it, with the untruncated text as the tooltip.
private struct LibraryAIStatusChip: View {
    let status: AIRowStatus

    var body: some View {
        if let text = status.text {
            let line = HStack(spacing: 3) {
                if status.isWorking {
                    ProgressView()
                        .controlSize(.mini)
                        .scaleEffect(0.62)
                        .frame(width: 10, height: 10)
                } else if let symbol = status.symbol {
                    Image(systemName: symbol)
                        .font(.system(size: 8.5, weight: .semibold))
                        .foregroundStyle(status.isWarning ? Theme.warn : Theme.secondary(0.5))
                }

                Text(text)
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.secondary(status.isWarning ? 0.75 : 0.5))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            if let detail = status.detail {
                line.help(detail)
            } else {
                line
            }
        }
    }
}

/// Bottom-right mark on a tile's thumbnail while the queue has something to
/// say about it. Described screenshots carry their sparkle on the title
/// instead, so the badge is only progress and failure.
private struct LibraryAIBadge: View {
    let status: AIRowStatus

    var body: some View {
        badge
            // The badge's white chip doesn't follow the appearance, so its
            // contents mustn't either: in dark mode a system-tinted spinner
            // and a `Color.primary` glyph both come out white on white.
            .environment(\.colorScheme, .light)
    }

    @ViewBuilder
    private var badge: some View {
        if status.isWorking {
            ProgressView()
                .controlSize(.mini)
                .scaleEffect(0.66)
                .frame(width: 17, height: 17)
                .background(.white.opacity(0.85), in: Circle())
                .shadow(color: .black.opacity(0.2), radius: 3, x: 0, y: 1)
        } else if let symbol = status.symbol {
            let mark = LibraryBadge(
                systemImage: symbol,
                foreground: status.isWarning ? Theme.warn : Theme.secondary(0.55),
                background: .white.opacity(0.85),
                shadowOpacity: 0.2
            )
            if let detail = status.detail {
                mark.help(detail)
            } else {
                mark
            }
        }
    }
}

/// The 17×17 circular badge shared by the pin (top-left) and selected-check
/// (top-right) marks, in both grid and list layouts.
private struct LibraryBadge: View {
    let systemImage: String
    let foreground: Color
    let background: Color
    let shadowOpacity: Double

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(foreground)
            .frame(width: 17, height: 17)
            .background(background, in: Circle())
            .shadow(color: .black.opacity(shadowOpacity), radius: 3, x: 0, y: 1)
    }
}
