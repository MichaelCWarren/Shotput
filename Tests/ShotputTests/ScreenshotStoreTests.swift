import Testing
import Foundation
import Combine
@testable import Shotput

@Suite @MainActor struct ScreenshotStoreTests {
    @Test func daysBucketTodayYesterdayOlder() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let settings = testSettings(folder: dir)
        let store = ScreenshotStore(settings: settings, pinsFile: dir.appendingPathComponent("pins.json"))
        defer { store.stop() }

        let now = Date()
        let threeDaysAgo = now.addingTimeInterval(-3 * 86_400)
        try makeScreenshotFile(in: dir, name: "today.png", created: now)
        try makeScreenshotFile(in: dir, name: "yesterday.png", created: now.addingTimeInterval(-86_400))
        try makeScreenshotFile(in: dir, name: "older.png", created: threeDaysAgo)
        store.rescan()

        let formatter = DateFormatter()
        formatter.dateFormat = "EEEE, MMM d"
        let olderLabel = formatter.string(from: threeDaysAgo)

        #expect(store.days.map(\.label) == ["Today", "Yesterday", olderLabel])
        #expect(store.days.allSatisfy { $0.shots.count == 1 })
    }

    @Test func shotsSortedNewestFirst() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let settings = testSettings(folder: dir)
        let store = ScreenshotStore(settings: settings, pinsFile: dir.appendingPathComponent("pins.json"))
        defer { store.stop() }

        let older = try makeScreenshotFile(in: dir, name: "older.png", created: Date().addingTimeInterval(-600))
        let newer = try makeScreenshotFile(in: dir, name: "newer.png", created: Date())
        store.rescan()

        #expect(store.shots.first?.url == newer)
        #expect(store.shots.last?.url == older)
    }

    @Test func countTextUsesFolderName() throws {
        let base = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: base) }
        let dir = base.appendingPathComponent("Desktop-Test", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let settings = testSettings(folder: dir)
        let store = ScreenshotStore(settings: settings, pinsFile: base.appendingPathComponent("pins.json"))
        defer { store.stop() }

        try makeScreenshotFile(in: dir, name: "a.png")
        try makeScreenshotFile(in: dir, name: "b.png")
        store.rescan()

        #expect(store.countText == "2 on Desktop-Test")
    }

    @Test func initialScanDoesNotEmitNewCapture() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try makeScreenshotFile(in: dir, name: "a.png")
        try makeScreenshotFile(in: dir, name: "b.png")

        let settings = testSettings(folder: dir)
        let store = ScreenshotStore(settings: settings, pinsFile: dir.appendingPathComponent("pins.json"))
        defer { store.stop() }

        try await confirmation(expectedCount: 0) { fired in
            let cancellable = store.newCapture.sink { _ in fired() }
            store.start()
            try await settle(0.4)
            cancellable.cancel()
        }
    }

    @Test func rescanEmitsNewCaptureOnce() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let settings = testSettings(folder: dir)
        let store = ScreenshotStore(settings: settings, pinsFile: dir.appendingPathComponent("pins.json"))
        defer { store.stop() }
        store.start()
        try await settle(0.1)

        var capturedURL: URL?
        try await confirmation(expectedCount: 1) { fired in
            let cancellable = store.newCapture.sink { shot in
                capturedURL = shot.url
                fired()
            }
            let newURL = try makeScreenshotFile(in: dir, name: "new.png")
            store.rescan()
            store.rescan()
            try await settle(0.5)
            cancellable.cancel()
            #expect(capturedURL == newURL)
        }
    }

    @Test func pinPersistsAcrossInstances() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let pinsFile = dir.appendingPathComponent("pins.json")
        let settings = testSettings(folder: dir)
        let url = try makeScreenshotFile(in: dir, name: "a.png")

        let first = ScreenshotStore(settings: settings, pinsFile: pinsFile)
        defer { first.stop() }
        first.rescan()
        first.togglePin(url)

        let second = ScreenshotStore(settings: settings, pinsFile: pinsFile)
        defer { second.stop() }
        second.start()

        #expect(second.shot(for: url)?.isPinned == true)
        let data = try Data(contentsOf: pinsFile)
        let paths = try JSONDecoder().decode([String].self, from: data)
        #expect(paths.contains(url.path))
    }

    @Test func rescanPrunesPinsForMissingFiles() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let settings = testSettings(folder: dir)
        let store = ScreenshotStore(settings: settings, pinsFile: dir.appendingPathComponent("pins.json"))
        defer { store.stop() }

        let url = try makeScreenshotFile(in: dir, name: "a.png")
        store.rescan()
        store.togglePin(url)
        #expect(store.pinnedURLs.contains(url))

        try FileManager.default.removeItem(at: url)
        store.rescan()

        #expect(!store.pinnedURLs.contains(url))
    }

    @Test func applyDescriptionSurvivesRescan() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let settings = testSettings(folder: dir)
        let store = ScreenshotStore(settings: settings, pinsFile: dir.appendingPathComponent("pins.json"))
        defer { store.stop() }

        let url = try makeScreenshotFile(in: dir, name: "a.png")
        store.rescan()
        store.applyDescription(for: url, title: "A title", summary: "A summary", describedBy: "appleLocal")
        store.rescan()

        #expect(store.shot(for: url)?.title == "A title")
    }

    @Test func applyDescriptionsReattachesOnRelaunch() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let settings = testSettings(folder: dir)
        let store = ScreenshotStore(settings: settings, pinsFile: dir.appendingPathComponent("pins.json"))
        defer { store.stop() }

        let urlA = try makeScreenshotFile(in: dir, name: "a.png")
        let urlB = try makeScreenshotFile(in: dir, name: "b.png")
        store.rescan()
        #expect(store.shot(for: urlA)?.title == nil)
        #expect(store.shot(for: urlB)?.title == nil)

        store.applyDescriptions([
            urlA: (title: "A title", summary: "A summary", describedBy: "appleLocal"),
            urlB: (title: "B title", summary: "B summary", describedBy: "appleLocal"),
        ])

        #expect(store.shot(for: urlA)?.title == "A title")
        #expect(store.shot(for: urlA)?.summary == "A summary")
        #expect(store.shot(for: urlA)?.describedBy == "appleLocal")
        #expect(store.shot(for: urlB)?.title == "B title")

        // The day bucket holds its own copy of each shot, so a rebuild is
        // the only way its title tracks the one just applied to `shots`.
        let dayShotA = store.days.flatMap(\.shots).first { $0.url == urlA }
        #expect(dayShotA?.title == "A title")
        #expect(dayShotA == store.shot(for: urlA))
    }

    @Test func applyDescriptionsNoMatchIsNoOp() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let settings = testSettings(folder: dir)
        let store = ScreenshotStore(settings: settings, pinsFile: dir.appendingPathComponent("pins.json"))
        defer { store.stop() }

        let url = try makeScreenshotFile(in: dir, name: "a.png")
        store.rescan()

        // `days` isn't Equatable, so unlike `shots` its Observable setter
        // can't suppress a same-content reassignment: any rebuild fires
        // this regardless of whether the values inside actually changed.
        var changeCount = 0
        let token = ObservationLoop.track {
            _ = store.days
        } onChange: {
            changeCount += 1
        }
        defer { token.cancel() }

        let strayURL = dir.appendingPathComponent("not-tracked.png")
        store.applyDescriptions([strayURL: (title: "Nope", summary: "Nope", describedBy: "appleLocal")])
        try await settle(0.2)

        #expect(changeCount == 0)
        #expect(store.shot(for: url)?.title == nil)
        #expect(store.shots.count == 1)
    }

    @Test func applyDescriptionsPartialMatchOnlyUpdatesMatched() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let settings = testSettings(folder: dir)
        let store = ScreenshotStore(settings: settings, pinsFile: dir.appendingPathComponent("pins.json"))
        defer { store.stop() }

        let urlA = try makeScreenshotFile(in: dir, name: "a.png")
        let urlB = try makeScreenshotFile(in: dir, name: "b.png")
        store.rescan()

        store.applyDescriptions([urlA: (title: "A title", summary: "A summary", describedBy: "appleLocal")])

        #expect(store.shot(for: urlA)?.title == "A title")
        #expect(store.shot(for: urlB)?.title == nil)
        #expect(store.shot(for: urlB)?.summary == nil)
        #expect(store.shots.count == 2)
    }

    @Test func applyDescriptionsEmptyDictionaryIsNoOp() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let settings = testSettings(folder: dir)
        let store = ScreenshotStore(settings: settings, pinsFile: dir.appendingPathComponent("pins.json"))
        defer { store.stop() }

        try makeScreenshotFile(in: dir, name: "a.png")
        store.rescan()

        var changeCount = 0
        let token = ObservationLoop.track {
            _ = store.days
        } onChange: {
            changeCount += 1
        }
        defer { token.cancel() }

        store.applyDescriptions([:])
        try await settle(0.2)

        #expect(changeCount == 0)
    }

    @Test func removeDropsEntryImmediately() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let settings = testSettings(folder: dir)
        let store = ScreenshotStore(settings: settings, pinsFile: dir.appendingPathComponent("pins.json"))
        defer { store.stop() }

        let url = try makeScreenshotFile(in: dir, name: "a.png")
        store.rescan()
        #expect(store.shot(for: url) != nil)

        store.remove([url])

        #expect(store.shot(for: url) == nil)
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    @Test func folderChangeRescansNewFolder() async throws {
        let dirA = try makeTempDir("A")
        let dirB = try makeTempDir("B")
        defer {
            try? FileManager.default.removeItem(at: dirA)
            try? FileManager.default.removeItem(at: dirB)
        }
        try makeScreenshotFile(in: dirA, name: "a.png")
        try makeScreenshotFile(in: dirB, name: "b1.png")
        try makeScreenshotFile(in: dirB, name: "b2.png")

        let settings = testSettings(folder: dirA)
        let store = ScreenshotStore(settings: settings, pinsFile: dirA.appendingPathComponent("pins.json"))
        defer { store.stop() }
        store.start()
        try await settle(0.2)

        settings.captureFolder = dirB
        // The folder change rescans off an observation callback, so wait for
        // the rescan rather than for half a second.
        _ = await poll { store.shots.count == 2 }

        #expect(store.shots.count == 2)
        #expect(store.countText.contains(dirB.lastPathComponent))
    }
}

/// `Screenshot`'s derived text and identity, which the library tiles and the
/// thumbnail views read.
@Suite struct ScreenshotDisplayTests {
    @Test func captionUsesTheClockTimeOnlyForACaptureName() {
        let created = Date(timeIntervalSinceReferenceDate: 0)
        let capture = Screenshot(url: URL(fileURLWithPath: "/tmp/Screenshot 2026-09-03 at 9.41.02.png"), created: created, byteSize: 1024)
        #expect(capture.captionText.hasPrefix("9.41.02 · "))

        // A file admitted by the xattr rather than the name: "at" is part of
        // a sentence, not a timestamp.
        let named = Screenshot(url: URL(fileURLWithPath: "/tmp/Coffee at the park.png"), created: created, byteSize: 1024)
        #expect(named.captionText == "\(named.timeText) · \(named.sizeText)")
    }

    @Test func theThumbnailKeyChangesWhenTheFileBehindTheURLDoes() {
        let url = URL(fileURLWithPath: "/tmp/a.png")
        let created = Date(timeIntervalSinceReferenceDate: 0)
        let before = Screenshot(url: url, created: created, byteSize: 1024)
        var after = Screenshot(url: url, created: created, byteSize: 2048)

        #expect(before.thumbnailKey != after.thumbnailKey)

        // A description arriving is not a new picture, so the view keyed on
        // this must not reload for one.
        after = before
        after.title = "A title"
        after.isPinned = true
        #expect(before.thumbnailKey == after.thumbnailKey)
    }
}
