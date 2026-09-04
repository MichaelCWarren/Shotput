import AppKit
import Foundation

/// Finder-style multi-select for the library grid/list. Plain data, no
/// store or window access, so the click/shift/⌘ logic is testable without
/// building a `ScreenshotStore` or an `NSWindow`.
struct LibrarySelection {
    var ids: Set<URL> = []
    var anchor: URL?

    /// `visible` is the on-screen order (filtered, day-ordered, then
    /// shot-ordered) so a shift-click range can span day sections.
    mutating func click(_ id: URL, in visible: [URL], modifiers: NSEvent.ModifierFlags) {
        if modifiers.contains(.command) {
            if ids.contains(id) {
                ids.remove(id)
            } else {
                ids.insert(id)
            }
            anchor = id
        } else if modifiers.contains(.shift) {
            let start = anchor.flatMap { visible.firstIndex(of: $0) } ?? 0
            guard let end = visible.firstIndex(of: id) else { return }
            let range = start <= end ? start...end : end...start
            ids.formUnion(visible[range])
        } else {
            ids = [id]
            anchor = id
        }
    }

    mutating func selectAll(_ visible: [URL]) {
        ids = Set(visible)
    }

    mutating func prune(keeping: Set<URL>) {
        ids.formIntersection(keeping)
    }

    func selected(from days: [ScreenshotDay]) -> [Screenshot] {
        days.flatMap(\.shots).filter { ids.contains($0.id) }
    }
}

/// Case-insensitive substring match against name, title and summary; a day
/// with no surviving shots is dropped so empty sections don't render.
func filterDays(_ days: [ScreenshotDay], query: String) -> [ScreenshotDay] {
    guard !query.isEmpty else { return days }
    let needle = query.lowercased()
    return days.compactMap { day in
        let shots = day.shots.filter { shot in
            shot.name.lowercased().contains(needle)
                || (shot.title ?? "").lowercased().contains(needle)
                || (shot.summary ?? "").lowercased().contains(needle)
        }
        guard !shots.isEmpty else { return nil }
        return ScreenshotDay(id: day.id, label: day.label, shots: shots)
    }
}

/// The footer's "**N selected** · size" text, split so the view can bold
/// just the count.
func footerParts(for shots: [Screenshot]) -> (count: String, size: String) {
    let count = "\(shots.count) selected"
    let size = ByteCountFormatter.string(fromByteCount: shots.reduce(0) { $0 + $1.byteSize }, countStyle: .file)
    return (count, size)
}

func pinMenuLabel(for shots: [Screenshot]) -> String {
    !shots.isEmpty && shots.allSatisfy(\.isPinned) ? "Unpin" : "Pin"
}
