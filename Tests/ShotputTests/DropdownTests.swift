import Testing
import SwiftUI
@testable import Shotput

@Suite struct DropdownTests {
    @Test func selectionMoveDownFromNothingPicksFirst() {
        let a = URL(fileURLWithPath: "/tmp/a.png")
        let b = URL(fileURLWithPath: "/tmp/b.png")
        let c = URL(fileURLWithPath: "/tmp/c.png")

        var s = DropdownSelection(ids: [a, b, c])
        s.moveDown()
        #expect(s.selectedID == a)
    }

    @Test func selectionMoveUpFromNothingPicksLast() {
        let a = URL(fileURLWithPath: "/tmp/a.png")
        let b = URL(fileURLWithPath: "/tmp/b.png")
        let c = URL(fileURLWithPath: "/tmp/c.png")

        var s = DropdownSelection(ids: [a, b, c])
        s.moveUp()
        #expect(s.selectedID == c)
    }

    @Test func selectionClampsAtEnds() {
        let a = URL(fileURLWithPath: "/tmp/a.png")
        let b = URL(fileURLWithPath: "/tmp/b.png")
        let c = URL(fileURLWithPath: "/tmp/c.png")

        var s = DropdownSelection(ids: [a, b, c])
        s.selectedID = c
        s.moveDown()
        s.moveDown()
        #expect(s.selectedID == c)

        s.selectedID = a
        s.moveUp()
        #expect(s.selectedID == a)
    }

    @Test func selectionOnEmptyListIsNoOp() {
        var s = DropdownSelection(ids: [])
        s.moveDown()
        s.moveUp()
        #expect(s.selectedID == nil)
    }

    @Test func reconcileDropsMissingSelection() {
        let a = URL(fileURLWithPath: "/tmp/a.png")
        let b = URL(fileURLWithPath: "/tmp/b.png")
        let c = URL(fileURLWithPath: "/tmp/c.png")

        var s = DropdownSelection(ids: [a, b, c])
        s.selectedID = b
        s.reconcile(ids: [a, c])
        #expect(s.selectedID == nil)

        s.selectedID = a
        s.reconcile(ids: [a, b])
        #expect(s.selectedID == a)
    }

    @Test func keyMapping() {
        #expect(DropdownKey.action(key: .return, modifiers: []) == .copy)
        #expect(DropdownKey.action(key: .return, modifiers: .option) == .copyText)
        #expect(DropdownKey.action(key: .space, modifiers: []) == .preview)
        #expect(DropdownKey.action(key: .escape, modifiers: []) == .close)
        #expect(DropdownKey.action(key: .upArrow, modifiers: []) == .up)
        #expect(DropdownKey.action(key: .downArrow, modifiers: []) == .down)
        #expect(DropdownKey.action(key: KeyEquivalent("a"), modifiers: []) == nil)
    }

    @Test @MainActor func copiedClearsAfterDelay() async throws {
        let a = URL(fileURLWithPath: "/tmp/a.png")

        let flash = CopiedFlash()
        flash.markCopied(a, clearAfter: .milliseconds(20))
        #expect(flash.copiedID == a)

        // CopiedFlash clears itself off an internal Task.sleep with no
        // awaitable handle, so a single fixed-time check races the clear
        // under load. Poll instead of sleeping-then-checking once.
        #expect(await poll { flash.copiedID == nil })
    }

    @Test @MainActor func copiedLatestWins() async throws {
        let a = URL(fileURLWithPath: "/tmp/a.png")
        let b = URL(fileURLWithPath: "/tmp/b.png")

        let flash = CopiedFlash()
        flash.markCopied(a, clearAfter: .milliseconds(20))
        // Far out, so b's own clear can never be what ends the flash inside
        // the window below. At 500 ms a loaded machine could overshoot into
        // it and fail this for a reason the test is not about.
        flash.markCopied(b, clearAfter: .seconds(30))
        #expect(flash.copiedID == b)

        // The bug is a's 20 ms clear taking the flash away from b, so watch
        // for that continuously across a window that covers the deadline
        // rather than checking once after it.
        let stolen = await poll(timeout: .milliseconds(200)) { flash.copiedID != b }
        #expect(stolen == false)
        #expect(flash.copiedID == b)
    }

    @Test @MainActor func copiedSameShotTwiceKeepsTheFlash() async throws {
        let a = URL(fileURLWithPath: "/tmp/a.png")

        let flash = CopiedFlash()
        flash.markCopied(a, clearAfter: .milliseconds(20))
        // Same reason as copiedLatestWins: the second deadline has to sit
        // well outside the window so only the first clear can trip this.
        flash.markCopied(a, clearAfter: .seconds(30))
        #expect(flash.copiedID == a)

        // The first task's clear lands ~20 ms in. Poll for the regression
        // (a nil flash) rather than sleeping once, then assert it never came.
        // 200 ms is ten times that deadline and is paid on every run, so it
        // stays short.
        let cleared = await poll(timeout: .milliseconds(200)) { flash.copiedID == nil }
        #expect(cleared == false)
        #expect(flash.copiedID == a)
    }

    @Test func visibleDaysTakesTwo() {
        let a = ScreenshotDay(id: Date(), label: "Today", shots: [])
        let b = ScreenshotDay(id: Date().addingTimeInterval(-86400), label: "Yesterday", shots: [])
        let c = ScreenshotDay(id: Date().addingTimeInterval(-172800), label: "Mon Sep 1", shots: [])

        #expect(DropdownModel.visibleDays([a, b, c]).map(\.label) == ["Today", "Yesterday"])
        #expect(DropdownModel.visibleDays([a]).map(\.label) == ["Today"])
    }

    @Test @MainActor func shotsCoverTheWholeStoreWhileDaysStopAtTwo() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let settings = testSettings(folder: dir)
        let store = ScreenshotStore(settings: settings, pinsFile: dir.appendingPathComponent("pins.json"))
        defer { store.stop() }

        try makeScreenshotFile(in: dir, name: "today.png", created: Date())
        try makeScreenshotFile(in: dir, name: "yesterday.png", created: Date().addingTimeInterval(-86400))
        let old = try makeScreenshotFile(in: dir, name: "old.png", created: Date().addingTimeInterval(-9 * 86400))
        store.rescan()

        let model = DropdownModel(
            store: store,
            settings: settings,
            cleanup: CleanupScheduler(store: store, settings: settings),
            windows: WindowManager(settings: settings, screenshotStore: store),
            dismiss: {}
        )

        #expect(model.days.count == 2)
        #expect(model.days.flatMap(\.shots).contains { $0.id == old } == false)
        #expect(model.shots.count == 3)
        #expect(model.shots.contains { $0.id == old })
    }

    @Test @MainActor func focusedShotPrefersSelectionThenHoverThenNil() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let settings = testSettings(folder: dir)
        let store = ScreenshotStore(settings: settings, pinsFile: dir.appendingPathComponent("pins.json"))
        defer { store.stop() }

        let selected = try makeScreenshotFile(in: dir, name: "selected.png", created: Date())
        let hovered = try makeScreenshotFile(in: dir, name: "hovered.png", created: Date().addingTimeInterval(-60))
        store.rescan()

        let model = DropdownModel(
            store: store,
            settings: settings,
            cleanup: CleanupScheduler(store: store, settings: settings),
            windows: WindowManager(settings: settings, screenshotStore: store),
            dismiss: {}
        )

        model.hoveredID = hovered
        #expect(model.focusedShot?.id == hovered)

        model.selection.selectedID = selected
        #expect(model.focusedShot?.id == selected)

        model.selection.selectedID = nil
        model.hoveredID = nil
        #expect(model.focusedShot == nil)
    }
}
