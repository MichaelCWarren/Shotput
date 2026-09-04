import AppKit
import Foundation

struct Screenshot: Identifiable, Hashable {
    let url: URL
    let created: Date
    let byteSize: Int64

    var id: URL { url }
    var name: String { url.deletingPathExtension().lastPathComponent }

    /// AI-generated title, or the file name when nothing has been generated yet.
    var title: String?
    var summary: String?
    var describedBy: String?

    var isPinned: Bool = false

    var displayName: String { title ?? name }

    var sizeText: String {
        ByteCountFormatter.string(fromByteCount: byteSize, countStyle: .file)
    }

    var timeText: String {
        Self.timeFormatter.string(from: created)
    }

    /// The library tile caption: the clock time out of the file name
    /// ("Screenshot 2026-09-03 at 9.41.02" → "9.41.02"), or `timeText` for
    /// files that were never named by macOS's screenshot tool.
    var captionText: String {
        let clockTime: String
        if let range = name.range(of: " at ", options: .backwards) {
            clockTime = String(name[range.upperBound...])
        } else {
            clockTime = timeText
        }
        return "\(clockTime) · \(sizeText)"
    }

    /// "9:41 AM · 412 KB · trashes in 7 d"
    func metaText(cleanup: CleanupInterval) -> String {
        var parts = [timeText, sizeText]
        if isPinned {
            parts.append("pinned")
        } else if let days = cleanup.days {
            let deadline = created.addingTimeInterval(TimeInterval(days) * 86_400)
            let remaining = deadline.timeIntervalSinceNow
            parts.append(remaining <= 0 ? "trashing now" : "trashes in \(Self.shortDuration(remaining))")
        }
        return parts.joined(separator: " · ")
    }

    /// Shared because this is read for every visible row on every render,
    /// and building a DateFormatter costs ~40x what formatting does.
    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "h:mm a"
        return f
    }()

    static func shortDuration(_ seconds: TimeInterval) -> String {
        let hours = Int(seconds / 3600)
        if hours >= 48 { return "\(hours / 24) d" }
        if hours >= 1 { return "\(hours) h" }
        return "\(max(1, Int(seconds / 60))) m"
    }
}

/// Day bucket used by the dropdown (TODAY / YESTERDAY) and the library.
struct ScreenshotDay: Identifiable {
    let id: Date
    let label: String
    var shots: [Screenshot]

    var countText: String {
        shots.count == 1 ? "1 screenshot" : "\(shots.count) screenshots"
    }
}

enum CleanupInterval: String, CaseIterable, Identifiable {
    case day, week, month, never

    var id: String { rawValue }

    var label: String {
        switch self {
        case .day: "24 h"
        case .week: "7 days"
        case .month: "30 days"
        case .never: "Never"
        }
    }

    var days: Int? {
        switch self {
        case .day: 1
        case .week: 7
        case .month: 30
        case .never: nil
        }
    }
}

enum CleanupAction: String, CaseIterable, Identifiable {
    case trash, delete

    var id: String { rawValue }
    var label: String {
        switch self {
        case .trash: "Move to Trash"
        case .delete: "Delete immediately"
        }
    }
}
