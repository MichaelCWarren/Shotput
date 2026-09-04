import Testing
import Foundation
@testable import Shotput

@Suite @MainActor struct CleanupTests {
    /// `runNow` moves real (throwaway, temp-dir) files to the real Trash;
    /// this removes the copy it leaves behind there so repeat runs don't
    /// pile up.
    private func removeFromTrash(named name: String) {
        guard let trashDir = FileManager.default.urls(for: .trashDirectory, in: .userDomainMask).first else { return }
        try? FileManager.default.removeItem(at: trashDir.appendingPathComponent(name))
    }

    @Test func trashesUnpinnedOlderThanInterval() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let settings = testSettings(folder: dir)
        settings.cleanupInterval = .week
        settings.cleanupAction = .trash
        let store = ScreenshotStore(settings: settings, pinsFile: dir.appendingPathComponent("pins.json"))
        defer { store.stop() }

        let now = Date()
        let oldURL = try makeScreenshotFile(in: dir, name: "old.png", created: now.addingTimeInterval(-8 * 86_400))
        try makeScreenshotFile(in: dir, name: "recent.png", created: now.addingTimeInterval(-86_400))
        store.rescan()

        let scheduler = CleanupScheduler(store: store, settings: settings, now: { now }, checkInterval: 3600)
        defer { scheduler.stop() }

        #expect(scheduler.itemsDue().map(\.url) == [oldURL])

        scheduler.runNow()
        defer { removeFromTrash(named: oldURL.lastPathComponent) }

        #expect(!FileManager.default.fileExists(atPath: oldURL.path))
        #expect(store.shot(for: oldURL) == nil)
    }

    @Test func keepPinnedSkipsPinned() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let settings = testSettings(folder: dir)
        settings.cleanupInterval = .week
        settings.cleanupAction = .trash
        settings.keepPinned = true
        let store = ScreenshotStore(settings: settings, pinsFile: dir.appendingPathComponent("pins.json"))
        defer { store.stop() }

        let now = Date()
        let url = try makeScreenshotFile(in: dir, name: "pinned.png", created: now.addingTimeInterval(-8 * 86_400))
        store.rescan()
        store.togglePin(url)

        let scheduler = CleanupScheduler(store: store, settings: settings, now: { now }, checkInterval: 3600)
        defer { scheduler.stop() }

        #expect(scheduler.itemsDue().isEmpty)

        settings.keepPinned = false
        #expect(scheduler.itemsDue().map(\.url) == [url])
    }

    @Test func neverIntervalDoesNothing() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let settings = testSettings(folder: dir)
        settings.cleanupInterval = .never
        let store = ScreenshotStore(settings: settings, pinsFile: dir.appendingPathComponent("pins.json"))
        defer { store.stop() }

        let now = Date()
        try makeScreenshotFile(in: dir, name: "ancient.png", created: now.addingTimeInterval(-100 * 86_400))
        store.rescan()

        let scheduler = CleanupScheduler(store: store, settings: settings, now: { now }, checkInterval: 3600)
        defer { scheduler.stop() }

        #expect(scheduler.itemsDue().isEmpty)
        #expect(scheduler.nextDeadline == nil)
        #expect(scheduler.nextRunText == nil)
    }

    @Test func deleteActionRemovesOutright() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let settings = testSettings(folder: dir)
        settings.cleanupInterval = .week
        settings.cleanupAction = .delete
        let store = ScreenshotStore(settings: settings, pinsFile: dir.appendingPathComponent("pins.json"))
        defer { store.stop() }

        let now = Date()
        // Unique name: the Trash check below is by file name, so a leftover
        // copy from any other test or run would answer for this one.
        let name = "delete-outright-\(UUID().uuidString).png"
        let url = try makeScreenshotFile(in: dir, name: name, created: now.addingTimeInterval(-8 * 86_400))
        store.rescan()

        let scheduler = CleanupScheduler(store: store, settings: settings, now: { now }, checkInterval: 3600)
        defer { scheduler.stop() }

        scheduler.runNow()
        // Runs even when the assertions below fail, so a regression to
        // trashing never leaves the file in the user's real Trash.
        defer { removeFromTrash(named: name) }

        #expect(!FileManager.default.fileExists(atPath: url.path))
        let trashDir = try #require(FileManager.default.urls(for: .trashDirectory, in: .userDomainMask).first)
        #expect(!FileManager.default.fileExists(atPath: trashDir.appendingPathComponent(name).path))
    }

    @Test func settingsChangeTriggersARun() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let settings = testSettings(folder: dir)
        settings.cleanupInterval = .never
        let store = ScreenshotStore(settings: settings, pinsFile: dir.appendingPathComponent("pins.json"))
        defer { store.stop() }

        // Real Date.init here (not a fixed `now`), so the two `lastRun`
        // timestamps below are provably different, not just non-nil.
        let url = try makeScreenshotFile(in: dir, name: "ancient.png", created: Date().addingTimeInterval(-100 * 86_400))
        store.rescan()

        let scheduler = CleanupScheduler(store: store, settings: settings, checkInterval: 3600)
        defer { scheduler.stop() }
        scheduler.start()
        // start()'s own run lands off the launch path, and a settings change
        // made while that run is still in flight is sequenced after it, so
        // both waits here are for the condition, not for a duration.
        #expect(await poll { scheduler.lastRun != nil })
        let firstRun = try #require(scheduler.lastRun)

        settings.cleanupInterval = .week
        defer { removeFromTrash(named: url.lastPathComponent) }

        #expect(await poll { (scheduler.lastRun ?? firstRun) > firstRun })
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test func footerTextMatchesDesign() {
        let now = Date()

        #expect(CleanupScheduler.footerText(interval: .week, action: .trash, nextDeadline: now.addingTimeInterval(3 * 3600), now: now)
            == "Trashes after 7 days · next in 3 h")
        #expect(CleanupScheduler.footerText(interval: .never, action: .trash, nextDeadline: nil, now: now) == "Never trashes")
        #expect(CleanupScheduler.footerText(interval: .week, action: .delete, nextDeadline: now.addingTimeInterval(3600), now: now)
            .hasPrefix("Deletes after"))
        #expect(CleanupScheduler.footerText(interval: .week, action: .trash, nextDeadline: now.addingTimeInterval(-3600), now: now)
            .hasSuffix("next in 1 m"))
        #expect(CleanupScheduler.nextRunText(deadline: nil, now: now) == nil)
    }
}
