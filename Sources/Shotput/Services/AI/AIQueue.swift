import Foundation
import Observation

/// The settings that decide whether a describe can succeed. `aiEnabled` is
/// not one of them: AI off blocks the queue and records no failures, so
/// switching it back on has nothing to un-stick.
private struct AIConfiguration: Equatable {
    var provider: AIProvider
    var model: String
    var host: String
    var sendToCloud: Bool
    var cloudKey: String

    init(_ settings: AISettings) {
        provider = settings.provider
        model = settings.model
        host = settings.ollamaHost
        sendToCloud = settings.sendToCloud
        cloudKey = settings.cloudKey
    }
}

@Observable
@MainActor
final class AIQueue {
    private(set) var pendingCount = 0
    private(set) var isRunning = false
    private(set) var blockedReason: String?
    private(set) var lastError: String?
    private(set) var describingURL: URL?

    var onDescribed: ((URL, AIRecord) -> Void)?

    /// Two more tries after the first failure, then the item is recorded as
    /// given up so one bad screenshot can't jam the queue forever.
    static let maxAttempts = 3

    /// Comfortably above what a reason written today can reach, so only the
    /// unbounded stored ones are ever cut.
    private static let reasonLimit = 120

    private let index: AIIndex
    private let settings: () -> AISettings
    private let resolveProvider: (AISettings) -> DescriptionProvider?
    private let blockedReasonFor: (AISettings) -> String?
    private let resolveEmbedder: (AISettings) -> Embedder?

    private var queue: [URL] = []
    /// Mirrors `queue`, because the Library asks for the state of every tile
    /// on screen and a scan of the array per tile is quadratic.
    private var queuedURLs: Set<URL> = []
    private var failureCounts: [URL: Int] = [:]
    private var worker: Task<Void, Never>?
    @ObservationIgnored private var configuration: AIConfiguration

    init(
        index: AIIndex,
        settings: @escaping () -> AISettings,
        resolveProvider: @escaping (AISettings) -> DescriptionProvider?,
        blockedReason: @escaping (AISettings) -> String?,
        resolveEmbedder: @escaping (AISettings) -> Embedder?
    ) {
        self.index = index
        self.settings = settings
        configuration = AIConfiguration(settings())
        self.resolveProvider = resolveProvider
        self.blockedReasonFor = blockedReason
        self.resolveEmbedder = resolveEmbedder
    }

    func sync(_ screenshots: [Screenshot]) {
        let urls = screenshots.map(\.url)
        index.prune(keeping: urls)

        let urlSet = Set(urls)
        queue.removeAll { !urlSet.contains($0) }
        failureCounts = failureCounts.filter { urlSet.contains($0.key) }

        let queued = Set(queue)
        let newURLs = index.undescribed(in: screenshots).map(\.url).filter { !queued.contains($0) }
        queue = newURLs + queue

        queueDidChange()
        kick()
    }

    /// Installing the missing model, fixing the host or supplying the key
    /// should un-stick the screenshots that gave up because of it, so a real
    /// change to the AI settings drops every give-up and lets the ordinary
    /// sync queue them again. A write that resolves to the same
    /// configuration is not a change: settings persist on every `didSet`,
    /// and sweeping on each incidental save would spend an attempt, and for
    /// a cloud provider real money, re-running failures that still fail.
    func settingsChanged(_ screenshots: [Screenshot]) {
        let resolved = AIConfiguration(settings())
        guard resolved != configuration else {
            kick()
            return
        }
        configuration = resolved
        index.clearFailures()
        sync(screenshots)
    }

    func kick() {
        guard worker == nil else { return }
        blockedReason = nil
        isRunning = true
        worker = Task { [weak self] in
            await self?.run()
        }
    }

    func drain() async {
        await worker?.value
    }

    func redescribeAll(_ screenshots: [Screenshot]) {
        for shot in screenshots {
            index.remove(shot.url)
            requeue(shot.url, atFront: false)
        }
        queueDidChange()
        kick()
    }

    var status: AIStatus {
        AIStatus(
            describedCount: index.records.count,
            pendingCount: pendingCount,
            failedCount: index.failures.count,
            isRunning: isRunning,
            blockedReason: blockedReason,
            lastError: lastError
        )
    }

    /// Newest first, which is the order the user asked about them in.
    var failures: [AIFailureItem] {
        index.failures
            .map {
                let display = Self.displayable($0.value)
                return AIFailureItem(
                    url: URL(fileURLWithPath: $0.key),
                    reason: display.reason,
                    failedAt: display.failedAt,
                    attempts: $0.value.attempts,
                    detail: display.detail
                )
            }
            .sorted { $0.failedAt > $1.failedAt }
    }

    /// Off wins over everything, including a description from an earlier
    /// session: while AI is disabled nothing here is live, and a row that
    /// still marked itself described would be presenting a switched-off
    /// feature as a running one.
    func state(for url: URL) -> AIState {
        guard settings().aiEnabled else { return .off }
        if index.record(for: url) != nil { return .described }
        if describingURL == url { return .describing }
        if let failure = index.failure(for: url) {
            let display = Self.displayable(failure)
            return .gaveUp(reason: display.reason, detail: display.detail)
        }
        guard queuedURLs.contains(url) else { return .off }
        if let attempt = failureCounts[url], attempt > 0 { return .retrying(attempt: attempt) }
        return .queued
    }

    /// Forgets that this screenshot gave up. For one that already has a
    /// description, `reindex` is the operation, not this.
    func retry(_ url: URL) {
        index.clearFailure(for: url)
        requeue(url, atFront: true)
        queueDidChange()
        kick()
    }

    func retryAllFailed() {
        let urls = index.failures.keys.map { URL(fileURLWithPath: $0) }
        index.clearFailures()
        for url in urls {
            requeue(url, atFront: false)
        }
        queueDidChange()
        kick()
    }

    /// Describes this screenshot again whatever state it is in, so one menu
    /// item covers a wrong description, a given-up one and a new model.
    /// Dropping the record first is the point: it takes the old vector out
    /// of semantic search before the replacement is in flight, and it is
    /// what makes the state read as queued rather than described.
    func reindex(_ url: URL) {
        index.remove(url)
        requeue(url, atFront: true)
        queueDidChange()
        kick()
    }

    private func run() async {
        defer {
            isRunning = false
            worker = nil
        }

        await describeQueued()
        await backfillVectors()
    }

    /// A screenshot described while no embedder was available keeps its
    /// description and gets no vector, which leaves it invisible to
    /// semantic search forever. The stored title and summary are enough to
    /// build one later, so it costs a text embed rather than a describe.
    private func backfillVectors() async {
        let current = settings()
        guard current.aiEnabled, let embedder = resolveEmbedder(current) else { return }
        let missing = index.records
            .filter { $0.value.vector == nil }
            .map { (url: URL(fileURLWithPath: $0.key), text: "\($0.value.title). \($0.value.summary)") }

        for entry in missing {
            guard !Task.isCancelled else { return }
            do {
                let vector = try await embedder.embed(entry.text)
                index.setVector(vector, embedderID: embedder.id, for: entry.url)
            } catch {
                // A dead host fails the same way for every remaining record,
                // so one failure ends the pass; the next kick retries it.
                lastError = error.localizedDescription
                return
            }
        }
    }

    private func describeQueued() async {
        while let url = queue.first {
            let current = settings()

            guard current.aiEnabled else {
                blockedReason = AIError.aiDisabled.errorDescription
                return
            }
            guard let provider = resolveProvider(current) else {
                blockedReason = blockedReasonFor(current)
                return
            }
            // The store already keeps a cloud provider from being selected
            // while sendToCloud is off; this is the last check before
            // bytes would leave the machine, so it stays even so.
            if provider.isCloud, !current.sendToCloud {
                blockedReason = AIError.cloudBlocked.errorDescription
                return
            }
            // A provider case that reads "local" proves nothing about where
            // its bytes land, so the last word goes to the destination.
            if let destination = provider.destination, !destination.isLoopbackHost, !current.sendToCloud {
                blockedReason = AIError.offMachineBlocked(destination).errorDescription
                return
            }

            do {
                describingURL = url
                defer { describingURL = nil }
                let description = try await provider.describe(imageURL: url)
                var vector: [Float]?
                var embedderID: String?
                if let embedder = resolveEmbedder(current) {
                    do {
                        vector = try await embedder.embed("\(description.title). \(description.summary)")
                        embedderID = embedder.id
                    } catch {
                        lastError = error.localizedDescription
                    }
                }
                let record = AIRecord(
                    title: description.title,
                    summary: description.summary,
                    describedBy: provider.modelLabel,
                    describedAt: Date(),
                    embedderID: embedderID,
                    vector: vector
                )
                index.set(record, for: url)
                onDescribed?(url, record)
                dequeue(url, resetFailures: true)
            } catch let error as AIError {
                switch error {
                case .providerUnavailable, .unreachable, .requiresSecureConnection, .aiDisabled, .cloudBlocked, .offMachineBlocked, .missingCloudKey:
                    blockedReason = error.errorDescription
                    return
                case .imageUnreadable:
                    // A second read of the same bytes goes the same way, so
                    // this one gives up without spending the other attempts.
                    lastError = error.errorDescription
                    if queuedURLs.contains(url) {
                        giveUp(url, error: error, attempts: 1)
                    }
                    dequeue(url, resetFailures: true)
                case .http, .badResponse:
                    fail(url, error: error)
                }
            } catch {
                fail(url, error: error)
            }
        }
    }

    /// Removes by identity, never by position: `sync` runs on the main actor
    /// while `describe` is suspended, and can reorder or empty the queue
    /// under the item being described.
    private func dequeue(_ url: URL, resetFailures: Bool) {
        queue.removeAll { $0 == url }
        if resetFailures { failureCounts[url] = nil }
        queueDidChange()
    }

    /// Requeues at the tail up to two more times; the last failure records
    /// the item as given up, where Settings can show it and the user can
    /// send it back through.
    private func fail(_ url: URL, error: Error) {
        let reason = error.localizedDescription
        lastError = reason
        let wasQueued = queuedURLs.contains(url)
        queue.removeAll { $0 == url }
        let count = (failureCounts[url] ?? 0) + 1
        // `!wasQueued` means a `sync` dropped this URL while it was in
        // flight, so its file is gone: nothing to retry and nothing to show.
        if !wasQueued {
            failureCounts[url] = nil
        } else if count >= Self.maxAttempts {
            failureCounts[url] = nil
            giveUp(url, error: error, attempts: count)
        } else {
            failureCounts[url] = count
            queue.append(url)
        }
        queueDidChange()
    }

    /// Records written before the reasons were shortened still hold whole
    /// JSON bodies, so the length rule is applied on the way out as well as
    /// on the way in. The stored text is not lost: it becomes the tooltip.
    private static func displayable(_ failure: AIFailure) -> (reason: String, failedAt: Date, detail: String?) {
        let oneLine = failure.reason.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard oneLine.count > reasonLimit else {
            return (oneLine, failure.failedAt, failure.detail)
        }
        return (String(oneLine.prefix(reasonLimit)) + "…", failure.failedAt, failure.detail ?? failure.reason)
    }

    private func giveUp(_ url: URL, error: Error, attempts: Int) {
        let reason = error.localizedDescription
        let detail = (error as? AIError)?.debugDescription
        index.setFailure(
            AIFailure(reason: reason, failedAt: Date(), attempts: attempts, detail: detail == reason ? nil : detail),
            for: url
        )
    }

    /// The caller runs `queueDidChange()` and `kick()`, so a bulk requeue
    /// pays for them once.
    private func requeue(_ url: URL, atFront: Bool) {
        failureCounts[url] = nil
        guard !queuedURLs.contains(url) else { return }
        if atFront {
            queue.insert(url, at: 0)
        } else {
            queue.append(url)
        }
    }

    private func queueDidChange() {
        queuedURLs = Set(queue)
        pendingCount = queue.count
    }
}
