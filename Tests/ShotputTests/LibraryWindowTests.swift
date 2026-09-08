import Testing
import AppKit
import Foundation
@testable import Shotput

@Suite struct LibraryWindowTests {
    @Test func captionTextUsesFileTimeAndSize() {
        let shot = Screenshot(
            url: URL(fileURLWithPath: "/tmp/Screenshot 2026-09-03 at 9.41.02.png"),
            created: Date(),
            byteSize: 412_000
        )
        #expect(shot.captionText == "9.41.02 · 412 KB")
    }

    @Test func captionTextFallsBackToClockTime() {
        let shot = Screenshot(
            url: URL(fileURLWithPath: "/tmp/IMG_0001.png"),
            created: Date(),
            byteSize: 200_000
        )
        #expect(shot.captionText == "\(shot.timeText) · \(shot.sizeText)")
    }

    @Test func filterMatchesNameTitleSummaryCaseInsensitively() {
        let byName = Screenshot(url: URL(fileURLWithPath: "/tmp/Screenshot 2026-09-03 at 9.41.02.png"), created: Date(), byteSize: 100)
        let byTitle = Screenshot(url: URL(fileURLWithPath: "/tmp/Screenshot 2026-09-03 at 10.15.30.png"), created: Date(), byteSize: 100, title: "Stripe dashboard")
        let bySummary = Screenshot(url: URL(fileURLWithPath: "/tmp/Screenshot 2026-09-03 at 11.00.00.png"), created: Date(), byteSize: 100, summary: "checkout flow captured")
        let day = ScreenshotDay(id: Date(), label: "Today", shots: [byName, byTitle, bySummary])

        #expect(filterDays([day], query: "9.41").flatMap(\.shots).map(\.id) == [byName.id])
        #expect(filterDays([day], query: "stripe").flatMap(\.shots).map(\.id) == [byTitle.id])
        #expect(filterDays([day], query: "CHECKOUT").flatMap(\.shots).map(\.id) == [bySummary.id])
        #expect(filterDays([day], query: "").flatMap(\.shots).count == 3)
    }

    @Test func filterDropsEmptyDays() {
        let noMatch = Screenshot(url: URL(fileURLWithPath: "/tmp/Screenshot 2026-09-01 at 8.00.00.png"), created: Date(), byteSize: 100)
        let day1 = ScreenshotDay(id: Date(timeIntervalSince1970: 0), label: "Monday", shots: [noMatch])

        let matching = Screenshot(url: URL(fileURLWithPath: "/tmp/Screenshot 2026-09-02 at 9.00.00.png"), created: Date(), byteSize: 100, title: "Special match")
        let other = Screenshot(url: URL(fileURLWithPath: "/tmp/Screenshot 2026-09-02 at 9.30.00.png"), created: Date(), byteSize: 100)
        let day2 = ScreenshotDay(id: Date(timeIntervalSince1970: 86_400), label: "Tuesday", shots: [matching, other])

        let filtered = filterDays([day1, day2], query: "match")
        #expect(filtered.count == 1)
        #expect(filtered.first?.id == day2.id)
        #expect(filtered.first?.shots.map(\.id) == [matching.id])
        #expect(filtered.first?.countText == "1 screenshot")
    }

    @Test func plainClickReplacesSelection() {
        let a = URL(fileURLWithPath: "/tmp/a.png")
        let b = URL(fileURLWithPath: "/tmp/b.png")
        var selection = LibrarySelection()
        selection.click(a, in: [a, b], modifiers: [])
        selection.click(b, in: [a, b], modifiers: [])
        #expect(selection.ids == [b])
        #expect(selection.anchor == b)
    }

    @Test func commandClickToggles() {
        let a = URL(fileURLWithPath: "/tmp/a.png")
        let b = URL(fileURLWithPath: "/tmp/b.png")
        var selection = LibrarySelection()
        selection.click(a, in: [a, b], modifiers: .command)
        selection.click(b, in: [a, b], modifiers: .command)
        #expect(selection.ids == [a, b])
        selection.click(a, in: [a, b], modifiers: .command)
        #expect(selection.ids == [b])
    }

    @Test func shiftClickSelectsRangeAcrossDays() {
        let a = URL(fileURLWithPath: "/tmp/a.png")
        let b = URL(fileURLWithPath: "/tmp/b.png")
        let c = URL(fileURLWithPath: "/tmp/c.png")
        let d = URL(fileURLWithPath: "/tmp/d.png")
        let e = URL(fileURLWithPath: "/tmp/e.png")
        let visible = [a, b, c, d, e] // two days: [a, b] | [c, d, e]

        var selection = LibrarySelection()
        selection.click(b, in: visible, modifiers: [])
        selection.click(d, in: visible, modifiers: .shift)
        #expect(selection.ids == [b, c, d])
        #expect(selection.anchor == b)

        selection.click(a, in: visible, modifiers: .shift)
        #expect(selection.ids == [a, b, c, d])
    }

    @Test func shiftClickWithoutAnchorSelectsOnlyTheClick() {
        let a = URL(fileURLWithPath: "/tmp/a.png")
        let b = URL(fileURLWithPath: "/tmp/b.png")
        let c = URL(fileURLWithPath: "/tmp/c.png")
        var selection = LibrarySelection()
        selection.click(c, in: [a, b, c], modifiers: .shift)
        #expect(selection.ids == [c])
    }

    /// An anchor the search query filtered out is no anchor: the range has
    /// to collapse onto the click, not start at the first surviving tile.
    @Test func shiftClickWithAFilteredOutAnchorSelectsOnlyTheClick() {
        let a = URL(fileURLWithPath: "/tmp/a.png")
        let b = URL(fileURLWithPath: "/tmp/b.png")
        let c = URL(fileURLWithPath: "/tmp/c.png")
        var selection = LibrarySelection()
        selection.click(a, in: [a, b, c], modifiers: [])
        selection.ids = []
        selection.click(c, in: [b, c], modifiers: .shift)
        #expect(selection.ids == [c])
    }

    @Test func selectAllSelectsOnlyVisible() {
        let a = Screenshot(url: URL(fileURLWithPath: "/tmp/keep-a.png"), created: Date(), byteSize: 100)
        let b = Screenshot(url: URL(fileURLWithPath: "/tmp/keep-b.png"), created: Date(), byteSize: 100)
        let c = Screenshot(url: URL(fileURLWithPath: "/tmp/keep-c.png"), created: Date(), byteSize: 100)
        let d = Screenshot(url: URL(fileURLWithPath: "/tmp/hidden-d.png"), created: Date(), byteSize: 100)
        let e = Screenshot(url: URL(fileURLWithPath: "/tmp/hidden-e.png"), created: Date(), byteSize: 100)
        let day = ScreenshotDay(id: Date(), label: "Today", shots: [a, b, c, d, e])

        let visibleIDs = filterDays([day], query: "keep").flatMap(\.shots).map(\.id)
        var selection = LibrarySelection()
        selection.selectAll(visibleIDs)
        #expect(selection.ids == Set([a.id, b.id, c.id]))
    }

    @Test func pruneRemovesMissingIds() {
        let a = URL(fileURLWithPath: "/tmp/a.png")
        let b = URL(fileURLWithPath: "/tmp/b.png")
        let c = URL(fileURLWithPath: "/tmp/c.png")
        var selection = LibrarySelection(ids: [a, b])
        selection.prune(keeping: [a, c])
        #expect(selection.ids == [a])
    }

    @Test func previewerServesEverySelectedUrl() {
        let a = URL(fileURLWithPath: "/tmp/a.png")
        let b = URL(fileURLWithPath: "/tmp/b.png")
        let previewer = QuickLookPreviewer()
        previewer.urls = [a, b]

        #expect(previewer.numberOfPreviewItems(in: nil) == 2)
        #expect(previewer.previewPanel(nil, previewItemAt: 1) as? NSURL == b as NSURL)
        // The panel can ask for a stale index between reloads.
        #expect(previewer.previewPanel(nil, previewItemAt: 7) == nil)
    }

    @Test func footerTextCountsAndSums() {
        let first = Screenshot(url: URL(fileURLWithPath: "/tmp/first.png"), created: Date(), byteSize: 412_000)
        let second = Screenshot(url: URL(fileURLWithPath: "/tmp/second.png"), created: Date(), byteSize: 1_100_000)

        let both = footerParts(for: [first, second])
        #expect(both.count == "2 selected")
        #expect(both.size == ByteCountFormatter.string(fromByteCount: 1_512_000, countStyle: .file))

        let one = footerParts(for: [first])
        #expect(one.count == "1 selected")
    }

    @Test func pinMenuLabel() {
        let pinnedA = Screenshot(url: URL(fileURLWithPath: "/tmp/pinned-a.png"), created: Date(), byteSize: 100, isPinned: true)
        let pinnedB = Screenshot(url: URL(fileURLWithPath: "/tmp/pinned-b.png"), created: Date(), byteSize: 100, isPinned: true)
        let unpinned = Screenshot(url: URL(fileURLWithPath: "/tmp/unpinned.png"), created: Date(), byteSize: 100)

        #expect(Shotput.pinMenuLabel(for: [pinnedA, pinnedB]) == "Unpin")
        #expect(Shotput.pinMenuLabel(for: [pinnedA, unpinned]) == "Pin")
    }
}

/// `ViewResolver` backs both the settings window's alert anchor and the
/// library footer's share anchor, and its whole job is to report a resolved
/// AppKit object without re-triggering the render that resolved it.
@Suite @MainActor struct ViewResolverTests {
    @Test func reportsOnlyWhenTheResolvedObjectChanges() async {
        let coordinator = ViewResolver<NSView>.Coordinator()
        let view = NSView()
        var reported: [NSView?] = []
        let record: (NSView?) -> Void = { reported.append($0) }

        // Stands in for makeNSView plus a burst of updateNSView passes.
        coordinator.report(view, to: record)
        coordinator.report(view, to: record)
        coordinator.report(view, to: record)
        #expect(await poll { reported.count == 1 })
        #expect(reported.first ?? nil === view)

        coordinator.report(nil, to: record)
        coordinator.report(nil, to: record)
        #expect(await poll { reported.count == 2 })
        #expect((reported.last ?? NSView()) == nil)
    }
}
