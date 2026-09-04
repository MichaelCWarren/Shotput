import Testing
import Foundation
@testable import Shotput

/// A plain `var` captured by `onChange` would race across the FSEvents
/// queue and the test's own task; this box gives both sides one thing to
/// synchronize on.
private final class Box: @unchecked Sendable {
    var value = 0
}

@Suite struct FolderWatcherTests {
    // On the main actor because the watcher calls back on the main queue:
    // the wait below then reads `delivered` from the same place the callback
    // writes it, without the hop the other tests here need.
    @Test @MainActor func newFileTriggersOnChange() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let delivered = Box()
        try await confirmation(expectedCount: 1...) { fired in
            let watcher = FolderWatcher(folder: dir) {
                delivered.value += 1
                fired()
            }
            watcher.start()
            defer { watcher.stop() }

            try makeScreenshotFile(in: dir, name: "a.png")
            // FSEvents debounces 0.3 s and then delivers whenever the OS gets
            // to it, which on a loaded machine is not 0.3 s. Wait for the
            // callback rather than for a duration; the confirmation is what
            // fails if it never comes.
            _ = await poll { delivered.value > 0 }
        }
    }

    @Test func burstCoalesces() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let count = Box()
        let watcher = FolderWatcher(folder: dir) { count.value += 1 }
        watcher.start()
        defer { watcher.stop() }

        for i in 0..<5 {
            try makeScreenshotFile(in: dir, name: "burst-\(i).png")
            try await Task.sleep(for: .milliseconds(10))
        }
        // Two waits, because the assertion has two halves. The first is for
        // the delivery to arrive at all, however late the machine makes it.
        _ = await poll { count.value > 0 }
        // The second is the coalescing claim: the writes are 10 ms apart and
        // the debounce is 0.3 s, so a watcher firing per event would land the
        // rest well inside this.
        try await settle(0.5)

        #expect((1...2).contains(await MainActor.run { count.value }))
    }

    @Test func stopCancelsAPendingCallback() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let count = Box()
        // Long enough that the debounce is still pending when stop() lands.
        let watcher = FolderWatcher(folder: dir, latency: 0.6) { count.value += 1 }
        watcher.start()
        try makeScreenshotFile(in: dir, name: "a.png")
        try await settle(0.15)
        watcher.stop()
        try await settle(1)

        // The onChange work item runs on the main queue, so the read goes
        // there too rather than racing it from the test's own task.
        #expect(await MainActor.run { count.value } == 0)
    }

    /// Changing the capture folder while `screencapture` is writing races the
    /// FSEvents callback on the watcher queue against `stop()` on the main
    /// thread; run under `--sanitize=thread` this catches an unsynchronized
    /// access to the watcher's own state.
    @Test func restartsDuringWritesAreSafe() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let count = Box()
        for i in 0..<20 {
            let watcher = FolderWatcher(folder: dir, latency: 0.01) { count.value += 1 }
            watcher.start()
            try makeScreenshotFile(in: dir, name: "churn-\(i).png")
            try await Task.sleep(for: .milliseconds(5))
            watcher.stop()
        }

        try await settle(0.5)
        let afterStop = await MainActor.run { count.value }
        try await settle(0.5)

        #expect(await MainActor.run { count.value } == afterStop)
    }

    @Test func repeatCallsAndMissingFolderAreSafe() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let watcher = FolderWatcher(folder: dir) {}
        watcher.start()
        watcher.start()
        watcher.stop()
        watcher.stop()

        let missing = dir.appendingPathComponent("does-not-exist", isDirectory: true)
        let fired = Box()
        let missingWatcher = FolderWatcher(folder: missing) { fired.value += 1 }
        missingWatcher.start()
        missingWatcher.start()
        missingWatcher.stop()
        missingWatcher.stop()
        try await settle(0.5)

        #expect(fired.value == 0)
    }
}
