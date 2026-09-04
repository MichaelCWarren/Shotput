import Testing
import Foundation
import SwiftUI
@testable import Shotput

@Suite struct AIDropdownTests {
    private func makeShot(
        _ name: String,
        created: Date,
        title: String? = nil,
        summary: String? = nil,
        describedBy: String? = nil
    ) -> Screenshot {
        Screenshot(
            url: URL(fileURLWithPath: "/tmp/\(name)"),
            created: created,
            byteSize: 1,
            title: title,
            summary: summary,
            describedBy: describedBy
        )
    }

    private func makeDay(_ label: String, _ shots: [Screenshot]) -> ScreenshotDay {
        ScreenshotDay(id: shots.first?.created ?? Date(), label: label, shots: shots)
    }

    private func time(hour: Int, minute: Int, daysAgo: Int = 0) -> Date {
        let calendar = Calendar.current
        let base = calendar.date(byAdding: .day, value: -daysAgo, to: Date())!
        return calendar.date(bySettingHour: hour, minute: minute, second: 0, of: base)!
    }

    @Test @MainActor func semanticMatchMetaFormatsDayTimeAndScore() {
        let shot = makeShot("dialog.png", created: time(hour: 9, minute: 41))
        let day = makeDay("Today", [shot])
        let match = SearchMatch(shot: shot, score: 96, isSemantic: true)

        #expect(AIDropdownModel.matchMeta(for: match, in: [day]) == "Today 9:41 AM · 96% match")
    }

    @Test @MainActor func textMatchMetaHasNoPercent() {
        let shot = makeShot("dialog2.png", created: time(hour: 16, minute: 20, daysAgo: 1))
        let day = makeDay("Yesterday", [shot])
        let match = SearchMatch(shot: shot, score: 100, isSemantic: false)

        #expect(AIDropdownModel.matchMeta(for: match, in: [day]) == "Yesterday 4:20 PM · text match")
    }

    @Test @MainActor func matchOutsideAnyDayFallsBackToDate() {
        let created = time(hour: 12, minute: 0, daysAgo: 10)
        let shot = makeShot("orphan.png", created: created)
        let match = SearchMatch(shot: shot, score: 70, isSemantic: true)

        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d"
        let expectedPrefix = formatter.string(from: created)

        let meta = AIDropdownModel.matchMeta(for: match, in: [])
        #expect(meta.hasPrefix(expectedPrefix))
    }

    @Test @MainActor func rowMetaUsesDescribedBy() {
        let described = makeShot("shot.png", created: time(hour: 9, minute: 32), title: "Login screen", describedBy: "llava:13b")
        #expect(AIDropdownModel.rowMeta(for: described) == "9:32 AM · llava:13b")

        let titledOnly = makeShot("shot2.png", created: time(hour: 9, minute: 32), title: "Login screen")
        #expect(AIDropdownModel.rowMeta(for: titledOnly) == "9:32 AM")
    }

    @Test @MainActor func undescribedRowShowsDescribingPlaceholder() {
        let queued = makeShot("queued.png", created: time(hour: 9, minute: 32))
        let day = makeDay("Today", [queued])

        let sections = AIDropdownModel.sections(days: [day], matches: [], query: "")
        let row = try! #require(sections.first?.rows.first)

        #expect(row.meta == "9:32 AM · describing…")
        #expect(row.showsSparkle == false)
        #expect(row.screenshot.summary == nil)
    }

    @Test @MainActor func emptyQueryYieldsPlainDaySections() {
        let today = makeDay("Today", [makeShot("a.png", created: time(hour: 9, minute: 0))])
        let yesterday = makeDay("Yesterday", [makeShot("b.png", created: time(hour: 9, minute: 0, daysAgo: 1))])

        for query in ["", "   "] {
            let sections = AIDropdownModel.sections(days: [today, yesterday], matches: [], query: query)
            #expect(sections.map(\.label) == ["TODAY", "YESTERDAY"])
        }
    }

    @Test @MainActor func queryWithResultsBuildsMatchesThenAllSections() {
        let todayShot = makeShot("today.png", created: time(hour: 9, minute: 41))
        let yesterdayShot = makeShot("yesterday.png", created: time(hour: 16, minute: 20, daysAgo: 1))
        let today = makeDay("Today", [todayShot])
        let yesterday = makeDay("Yesterday", [yesterdayShot])

        // Deliberately out of day order, to prove section order comes from
        // `matches` (SemanticSearch's own score ordering), not from `days`.
        let matches = [
            SearchMatch(shot: yesterdayShot, score: 80, isSemantic: true),
            SearchMatch(shot: todayShot, score: 90, isSemantic: true)
        ]

        let sections = AIDropdownModel.sections(days: [today, yesterday], matches: matches, query: "dialog")

        #expect(sections.map(\.label) == ["2 MATCHES", "ALL · TODAY", "ALL · YESTERDAY"])
        #expect(sections[0].rows.map(\.screenshot.id) == [yesterdayShot.id, todayShot.id])
        #expect(sections[0].rows[0].fill == .top)
        #expect(sections[0].rows[1].fill == .other)
    }

    @Test @MainActor func singleMatchLabelIsSingular() {
        #expect(AIDropdownModel.matchesLabel(count: 1) == "1 MATCH")
    }

    @Test @MainActor func queryWithNoResultsShowsNoMatchesLabel() {
        let today = makeDay("Today", [makeShot("a.png", created: time(hour: 9, minute: 0))])
        let yesterday = makeDay("Yesterday", [makeShot("b.png", created: time(hour: 9, minute: 0, daysAgo: 1))])

        let sections = AIDropdownModel.sections(days: [today, yesterday], matches: [], query: "dialog")

        #expect(sections.map(\.label) == ["NO MATCHES", "ALL · TODAY", "ALL · YESTERDAY"])
        #expect(sections[0].rows.isEmpty)
    }

    @MainActor
    private final class SearchRecorder {
        var calls: [(query: String, shotsCount: Int, limit: Int)] = []
    }

    /// Holds every scheduled debounce open until the test lets it go. Timing a
    /// burst against a real debounce window instead means sleeping between
    /// keystrokes, and a loaded machine stretches those sleeps past the window.
    @MainActor
    private final class DebounceGate {
        private(set) var entered = 0
        private(set) var finished = 0
        private var waiting: [CheckedContinuation<Void, Never>] = []

        func wait() async {
            entered += 1
            await withCheckedContinuation { waiting.append($0) }
            finished += 1
        }

        func releaseAll() {
            let pending = waiting
            waiting = []
            for continuation in pending { continuation.resume() }
        }
    }

    @Test @MainActor func searchIsDebounced() async throws {
        let recorder = SearchRecorder()
        let gate = DebounceGate()
        let shots = [
            makeShot("a.png", created: Date()),
            makeShot("b.png", created: Date()),
            makeShot("c.png", created: Date())
        ]

        let model = AIDropdownModel(debounceWait: { _ in await gate.wait() }) { query, shots, limit in
            recorder.calls.append((query, shots.count, limit))
            return []
        }
        model.allShots = shots

        // Each keystroke lands only once the previous one's debounce is
        // provably waiting, so every schedule really is superseded mid-wait.
        model.query = "e"
        #expect(await poll { gate.entered == 1 })
        model.query = "er"
        #expect(await poll { gate.entered == 2 })
        model.query = "err"
        #expect(await poll { gate.entered == 3 })
        #expect(recorder.calls.isEmpty)

        gate.releaseAll()

        #expect(await poll { gate.finished == 3 && recorder.calls.count == 1 })
        #expect(recorder.calls.count == 1)
        #expect(recorder.calls.first?.query == "err")
        #expect(recorder.calls.first?.shotsCount == shots.count)
        #expect(recorder.calls.first?.limit == 8)
    }

    @Test @MainActor func searchReachesScreenshotsOlderThanTheVisibleDays() async throws {
        let today = makeShot("today.png", created: time(hour: 9, minute: 41), title: "Login screen")
        let old = makeShot("old.png", created: time(hour: 11, minute: 5, daysAgo: 9), title: "Stack trace")
        let days = [makeDay("Today", [today])]

        let model = AIDropdownModel(debounceInterval: .milliseconds(10)) { query, shots, _ in
            shots
                .filter { ($0.title ?? "").localizedCaseInsensitiveContains(query) }
                .map { SearchMatch(shot: $0, score: 88, isSemantic: true) }
        }
        // The whole store, wider than the two days the row list shows.
        model.allShots = [today, old]
        model.query = "stack"

        #expect(await poll { model.matches.count == 1 })

        let sections = AIDropdownModel.sections(days: days, matches: model.matches, query: model.query)
        #expect(sections.map(\.label) == ["1 MATCH", "ALL · TODAY"])

        let row = try #require(sections.first?.rows.first)
        #expect(row.screenshot.id == old.id)

        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d"
        #expect(row.meta == "\(formatter.string(from: old.created)) 11:05 AM · 88% match")
    }

    @Test @MainActor func matchRowFollowsADescriptionThatArrivesAfterTheSearch() async throws {
        let recorder = SearchRecorder()
        let queued = makeShot("queued.png", created: time(hour: 9, minute: 32))

        // Matches on the file name: the path that hits while a shot is still
        // undescribed, so the match carries a title-less screenshot.
        let model = AIDropdownModel(debounceInterval: .milliseconds(10)) { query, shots, limit in
            recorder.calls.append((query, shots.count, limit))
            return shots
                .filter { $0.name.localizedCaseInsensitiveContains(query) }
                .map { SearchMatch(shot: $0, score: 100, isSemantic: false) }
        }
        model.allShots = [queued]
        model.query = "queued"

        #expect(await poll { model.matches.count == 1 })
        let pending = AIDropdownModel.sections(days: [makeDay("Today", [queued])], matches: model.matches, query: model.query)
        #expect(try #require(pending.first?.rows.first).showsSparkle == false)

        let described = makeShot(
            "queued.png",
            created: queued.created,
            title: "Login screen",
            summary: "A login form with an email field",
            describedBy: "llava:13b"
        )
        model.allShots = [described]

        let sections = AIDropdownModel.sections(days: [makeDay("Today", [described])], matches: model.matches, query: model.query)
        #expect(sections.map(\.label) == ["1 MATCH", "ALL · TODAY"])

        let row = try #require(sections.first?.rows.first)
        #expect(row.screenshot.title == "Login screen")
        #expect(row.screenshot.summary == "A login form with an email field")
        #expect(row.showsSparkle)
        // The description must not have cost another embedding pass, now or
        // after a debounce interval. A short window is the assertion here,
        // not a concession to speed: 60 ms is six debounce intervals, so a
        // re-search would already have been recorded, and stretching it only
        // spends the time again on every run.
        #expect(await poll(timeout: .milliseconds(60)) { recorder.calls.count > 1 } == false)
    }

    @Test func spaceAlwaysTypesIntoTheField() {
        #expect(SemanticSearchField.forwardedKey(.space, modifiers: []) == nil)
        #expect(SemanticSearchField.forwardedKey(.downArrow, modifiers: []) == .down)
        #expect(SemanticSearchField.forwardedKey(.upArrow, modifiers: []) == .up)
        #expect(SemanticSearchField.forwardedKey(.return, modifiers: []) == .copy)
        #expect(SemanticSearchField.forwardedKey(.return, modifiers: .option) == .copyText)
    }

    @Test func footerTextBoldsCreditAndOmitsZeroPending() throws {
        let withPending = AIStatusFooter.text(credit: "llava via Ollama Cloud", blockedReason: nil, pending: 2)
        #expect(String(withPending.characters) == "Titles & descriptions by llava via Ollama Cloud · indexed locally · 2 pending")

        let boldRuns = withPending.runs.filter { $0.inlinePresentationIntent == .stronglyEmphasized }
        #expect(boldRuns.count == 1)
        let boldRun = try #require(boldRuns.first)
        #expect(String(withPending[boldRun.range].characters) == "llava via Ollama Cloud")

        let zeroPending = AIStatusFooter.text(credit: "llava via Ollama Cloud", blockedReason: nil, pending: 0)
        #expect(String(zeroPending.characters) == "Titles & descriptions by llava via Ollama Cloud · indexed locally")
    }

    @Test func footerShowsBlockedReasonWhenNoCredit() {
        let blocked = AIStatusFooter.text(credit: nil, blockedReason: "Ollama Cloud needs “Send images to cloud” on", pending: 3)
        #expect(String(blocked.characters) == "Ollama Cloud needs “Send images to cloud” on")
        #expect(blocked.runs.filter { $0.inlinePresentationIntent == .stronglyEmphasized }.isEmpty)

        let fallback = AIStatusFooter.text(credit: nil, blockedReason: nil, pending: 0)
        #expect(String(fallback.characters) == "AI descriptions paused")
    }
}
