import Foundation

/// Which purple-tinted background an AI row gets: `.top` is the best match,
/// `.other` the rest of the matches section, `.none` a plain day row.
enum AIRowFill: Equatable {
    case top, other, none
}

struct AIRowItem: Identifiable, Equatable {
    var screenshot: Screenshot
    var meta: String
    var fill: AIRowFill
    var showsSparkle: Bool
    var state: AIState = .off

    var id: Screenshot.ID { screenshot.id }
}

struct AIDropdownSection: Identifiable, Equatable {
    var label: String
    var rows: [AIRowItem]

    var id: String { label }
}

/// Owns the semantic search field's state: query text, debounce, and the
/// resulting sections. `sections`/`matchMeta`/`rowMeta`/`matchesLabel` are
/// static so tests can call them without a coordinator or a window.
@MainActor
@Observable
final class AIDropdownModel {
    var query: String = "" {
        didSet {
            guard query != oldValue else { return }
            scheduleSearch()
        }
    }
    private(set) var matches: [SearchMatch] = []

    /// Every screenshot across `model.days`, kept in sync by `DropdownView`
    /// whenever the store's set of screenshots changes.
    var allShots: [Screenshot] = [] {
        didSet {
            var refreshed = matches
            if Self.refresh(&refreshed, from: allShots) {
                matches = refreshed
            }
        }
    }

    private let search: (String, [Screenshot], Int) async -> [SearchMatch]
    private let debounceInterval: Duration

    /// Waits out the debounce window before a scheduled search runs.
    /// `Task.sleep` is a wall-clock wait that scheduling jitter can stretch
    /// past the interval, so tests swap this out and release each keystroke's
    /// wait by hand.
    private let debounceWait: (Duration) async -> Void
    private var searchTask: Task<Void, Never>?

    init(
        debounceInterval: Duration = .milliseconds(200),
        debounceWait: @escaping (Duration) async -> Void = { try? await Task.sleep(for: $0) },
        search: @escaping (String, [Screenshot], Int) async -> [SearchMatch]
    ) {
        self.debounceInterval = debounceInterval
        self.debounceWait = debounceWait
        self.search = search
    }

    convenience init(ai: AICoordinator?, debounceInterval: Duration = .milliseconds(200)) {
        guard let ai else {
            self.init(debounceInterval: debounceInterval) { _, _, _ in [] }
            return
        }
        let semanticSearch = ai.makeSearch()
        self.init(debounceInterval: debounceInterval) { query, shots, limit in
            await semanticSearch.search(query, in: shots, limit: limit)
        }
    }

    private func scheduleSearch() {
        searchTask?.cancel()
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            matches = []
            return
        }
        let pendingQuery = query
        let shots = allShots
        searchTask = Task { [debounceInterval, debounceWait, search] in
            await debounceWait(debounceInterval)
            guard !Task.isCancelled else { return }
            var results = await search(pendingQuery, shots, 8)
            guard !Task.isCancelled else { return }
            Self.refresh(&results, from: self.allShots)
            self.matches = results
        }
    }

    /// A `SearchMatch` carries the screenshot as it looked when the search
    /// ran, and a description can land minutes later. Re-reading the store
    /// keeps the match rows current for the cost of one pass; re-running the
    /// search would spend an embedding pass per description instead.
    @discardableResult
    private static func refresh(_ matches: inout [SearchMatch], from shots: [Screenshot]) -> Bool {
        guard !matches.isEmpty else { return false }
        let matched = Set(matches.map(\.shot.id))
        var latest: [Screenshot.ID: Screenshot] = [:]
        for shot in shots where matched.contains(shot.id) {
            latest[shot.id] = shot
        }
        var changed = false
        for index in matches.indices {
            guard let shot = latest[matches[index].shot.id], shot != matches[index].shot else { continue }
            matches[index].shot = shot
            changed = true
        }
        return changed
    }

    /// `state` is one O(1) lookup per row against the queue, so a hover
    /// re-render costs the same pass it always did.
    static func sections(
        days: [ScreenshotDay],
        matches: [SearchMatch],
        query: String,
        state: (URL) -> AIState = { _ in .off }
    ) -> [AIDropdownSection] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return days.map { daySection(for: $0, label: $0.label.uppercased(), state: state) }
        }

        let allSections = days.map { daySection(for: $0, label: "ALL · \($0.label.uppercased())", state: state) }

        guard !matches.isEmpty else {
            return [AIDropdownSection(label: "NO MATCHES", rows: [])] + allSections
        }

        let matchRows = matches.enumerated().map { index, match in
            AIRowItem(
                screenshot: match.shot,
                meta: matchMeta(for: match, in: days),
                fill: index == 0 ? .top : .other,
                showsSparkle: match.shot.title != nil,
                state: state(match.shot.url)
            )
        }
        return [AIDropdownSection(label: matchesLabel(count: matches.count), rows: matchRows)] + allSections
    }

    private static func daySection(for day: ScreenshotDay, label: String, state: (URL) -> AIState) -> AIDropdownSection {
        AIDropdownSection(
            label: label,
            rows: day.shots.map { shot in
                let shotState = state(shot.url)
                return AIRowItem(
                    screenshot: shot,
                    meta: rowMeta(for: shot, state: shotState),
                    fill: .none,
                    showsSparkle: shot.title != nil,
                    state: shotState
                )
            }
        )
    }

    static func matchesLabel(count: Int) -> String {
        count == 1 ? "1 MATCH" : "\(count) MATCHES"
    }

    static func matchMeta(for match: SearchMatch, in days: [ScreenshotDay]) -> String {
        let day = days.first { $0.shots.contains { $0.id == match.shot.id } }
        let dayText = day?.label ?? shortDate(match.shot.created)
        if match.isSemantic {
            return "\(dayText) \(match.shot.timeText) · \(match.score)% match"
        }
        return "\(dayText) \(match.shot.timeText) · text match"
    }

    /// The row's own status line owns the AI state once there is one to read,
    /// so the meta only guesses at "describing…" when it has no state to go on.
    static func rowMeta(for shot: Screenshot, state: AIState = .off) -> String {
        if let describedBy = shot.describedBy, shot.title != nil {
            return "\(shot.timeText) · \(describedBy)"
        }
        if state == .off, shot.title == nil {
            return "\(shot.timeText) · describing…"
        }
        return shot.timeText
    }

    private static func shortDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "MMM d"
        return f.string(from: date)
    }
}
