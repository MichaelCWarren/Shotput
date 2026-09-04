import Foundation

/// Wires the AI index, queue and registry together. Built in `ShotputApp.init`
/// and passed explicitly to every view that needs it — the dropdown directly,
/// Settings and the Library through `WindowManager`. Nothing reaches it through
/// the delegate or the environment.
@MainActor
final class AICoordinator {
    let index: AIIndex
    let queue: AIQueue

    private let settings: SettingsStore
    private let store: ScreenshotStore
    private let registry: ProviderRegistry

    private var storeToken: ObservationToken?
    private var settingsToken: ObservationToken?
    private var startTask: Task<Void, Never>?

    // `AIIndex(fileURL: AIIndex.defaultFile)` can't sit in the parameter
    // list itself: default-argument expressions are evaluated as if from a
    // nonisolated caller, and both are main-actor-isolated.
    init(settings: SettingsStore, store: ScreenshotStore, index: AIIndex? = nil, registry: ProviderRegistry = .live) {
        self.settings = settings
        self.store = store
        self.registry = registry
        let index = index ?? AIIndex(fileURL: AIIndex.defaultFile)
        self.index = index
        queue = AIQueue(
            index: index,
            settings: { settings.ai },
            resolveProvider: { registry.provider(for: $0) },
            blockedReason: { registry.blockedReason(for: $0) },
            resolveEmbedder: { registry.embedder(for: $0) }
        )
    }

    var provider: DescriptionProvider? { registry.provider(for: settings.ai) }
    var blockedReason: String? { queue.blockedReason ?? registry.blockedReason(for: settings.ai) }

    var status: AIStatus {
        var status = queue.status
        status.blockedReason = blockedReason
        return status
    }

    var failures: [AIFailureItem] { queue.failures }

    func state(for url: URL) -> AIState { queue.state(for: url) }

    func retry(_ url: URL) { queue.retry(url) }

    func retryAllFailed() { queue.retryAllFailed() }

    /// Throws away this screenshot's description and describes it again.
    func reindex(_ url: URL) { queue.reindex(url) }

    func reindexAll() { queue.redescribeAll(store.shots) }

    func makeSearch() -> SemanticSearch {
        SemanticSearch(index: index, embedder: registry.embedder(for: settings.ai))
    }

    func start() {
        queue.onDescribed = { [weak store] url, record in
            store?.applyDescription(for: url, title: record.title, summary: record.summary, describedBy: record.describedBy)
        }

        // Nothing may observe the store before `load()` finishes: a `sync()`
        // against an empty index would queue every already-described
        // screenshot for a second describe.
        startTask = Task { [weak self] in
            guard let self else { return }
            await index.load()
            guard !Task.isCancelled else { return }
            applyRecords()
            queue.sync(store.shots)

            storeToken = ObservationLoop.track { [store] in
                _ = store.shots
            } onChange: { [weak self] in
                guard let self else { return }
                applyRecords()
                queue.sync(store.shots)
            }

            // The store already resets .ollamaCloud back to .ollamaLocal when
            // sendToCloud goes off, so this one listener covers every settings
            // change without a second one.
            settingsToken = ObservationLoop.track { [settings] in
                _ = settings.ai
            } onChange: { [weak self] in
                guard let self else { return }
                queue.settingsChanged(store.shots)
            }
        }
    }

    func stop() {
        startTask?.cancel()
        startTask = nil
        storeToken?.cancel()
        storeToken = nil
        settingsToken?.cancel()
        settingsToken = nil
    }

    /// Rescans (a folder change, a relaunch) bring shots back with nil
    /// title/summary/describedBy even when the index already has a record;
    /// this re-attaches it instead of leaving the row blank.
    private func applyRecords() {
        var descriptions: [URL: (title: String, summary: String, describedBy: String)] = [:]
        for shot in store.shots where shot.title == nil {
            guard let record = index.record(for: shot.url) else { continue }
            descriptions[shot.url] = (record.title, record.summary, record.describedBy)
        }
        guard !descriptions.isEmpty else { return }
        store.applyDescriptions(descriptions)
    }
}
