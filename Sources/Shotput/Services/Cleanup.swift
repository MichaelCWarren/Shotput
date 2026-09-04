import Foundation
import Observation
import os

@Observable
@MainActor
final class CleanupScheduler {
    private(set) var lastRun: Date?

    private let store: ScreenshotStore
    private let settings: SettingsStore
    private let now: () -> Date
    private let checkInterval: TimeInterval
    private let logger = Logger(subsystem: "com.shotput.app", category: "cleanup")

    private var timer: Timer?
    private var observationToken: ObservationToken?
    private var launchRun: Task<Void, Never>?
    private var launchRunActive = false
    private var pendingRun = false

    init(store: ScreenshotStore, settings: SettingsStore, now: @escaping () -> Date = Date.init, checkInterval: TimeInterval = 15 * 60) {
        self.store = store
        self.settings = settings
        self.now = now
        self.checkInterval = checkInterval
    }

    func itemsDue() -> [Screenshot] {
        guard let days = settings.cleanupInterval.days else { return [] }
        let cutoff = now()
        return store.shots.filter { isDue($0, days: days, cutoff: cutoff) }
    }

    func runNow() {
        // The launch run is still trashing its own due list; two passes over
        // the same files would fight. This one goes right after it instead.
        guard !launchRunActive else {
            pendingRun = true
            return
        }
        let due = itemsDue().map(\.url)
        applyRemoval(Self.removeFiles(due, action: settings.cleanupAction, logger: logger))
    }

    func start() {
        // Trashing at launch is file I/O over every due screenshot, so it
        // runs off the launch path and off the main thread.
        launchRunActive = true
        launchRun = Task { [weak self] in
            guard let self else { return }
            let due = itemsDue().map(\.url)
            let action = settings.cleanupAction
            let removed = await Task.detached(priority: .utility) { [logger] in
                Self.removeFiles(due, action: action, logger: logger)
            }.value
            launchRunActive = false
            guard !Task.isCancelled else { return }
            applyRemoval(removed)
            if pendingRun {
                pendingRun = false
                runNow()
            }
        }
        timer = Timer.scheduledTimer(withTimeInterval: checkInterval, repeats: true) { [weak self] _ in
            DispatchQueue.main.async {
                self?.runNow()
            }
        }
        observationToken = ObservationLoop.track { [settings] in
            _ = settings.cleanupInterval
            _ = settings.cleanupAction
            _ = settings.keepPinned
        } onChange: { [weak self] in
            self?.runNow()
        }
    }

    func stop() {
        launchRun?.cancel()
        launchRun = nil
        launchRunActive = false
        pendingRun = false
        timer?.invalidate()
        timer = nil
        observationToken?.cancel()
        observationToken = nil
    }

    var nextDeadline: Date? {
        guard let days = settings.cleanupInterval.days else { return nil }
        let lifetime = TimeInterval(days) * 86_400
        var earliest: Date?
        for shot in store.shots where !(shot.isPinned && settings.keepPinned) {
            let deadline = shot.created.addingTimeInterval(lifetime)
            if earliest == nil || deadline < earliest! {
                earliest = deadline
            }
        }
        return earliest
    }

    var nextRunText: String? {
        Self.nextRunText(deadline: nextDeadline, now: now())
    }

    var footerText: String {
        Self.footerText(interval: settings.cleanupInterval, action: settings.cleanupAction, nextDeadline: nextDeadline, now: now())
    }

    private func applyRemoval(_ removed: [URL]) {
        if !removed.isEmpty {
            store.remove(removed)
        }
        lastRun = now()
    }

    /// Returns the URLs it managed to remove; a failure on one file leaves
    /// the rest to be retried on the next run.
    private nonisolated static func removeFiles(_ urls: [URL], action: CleanupAction, logger: Logger) -> [URL] {
        var removed: [URL] = []
        for url in urls {
            do {
                try ScreenshotActions.remove([url], action: action)
                removed.append(url)
            } catch {
                logger.error("Cleanup failed for \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
        return removed
    }

    private func isDue(_ shot: Screenshot, days: Int, cutoff: Date) -> Bool {
        guard !(shot.isPinned && settings.keepPinned) else { return false }
        let deadline = shot.created.addingTimeInterval(TimeInterval(days) * 86_400)
        return deadline <= cutoff
    }

    static func nextRunText(deadline: Date?, now: Date) -> String? {
        guard let deadline else { return nil }
        let remaining = deadline.timeIntervalSince(now)
        return "next in \(Screenshot.shortDuration(max(remaining, 60)))"
    }

    static func footerText(interval: CleanupInterval, action: CleanupAction, nextDeadline: Date?, now: Date) -> String {
        guard interval.days != nil else { return "Never trashes" }
        let verb = action == .trash ? "Trashes" : "Deletes"
        var text = "\(verb) after \(interval.label)"
        if let runText = nextRunText(deadline: nextDeadline, now: now) {
            text += " · \(runText)"
        }
        return text
    }
}
