import Foundation
import Observation
import os

struct AIRecord: Codable, Equatable {
    var title: String
    var summary: String
    var describedBy: String
    var describedAt: Date
    var embedderID: String?
    var vector: [Float]?
}

/// What a screenshot that ran out of retries left behind. Persisted beside
/// the records so a failure the user hasn't seen yet survives a relaunch.
struct AIFailure: Codable, Equatable {
    var reason: String
    var failedAt: Date
    var attempts: Int
    /// The long form, for a tooltip: what `reason` says plus the raw server
    /// body it leaves out. Nil when there is nothing more to add.
    var detail: String?
}

/// `failures` is optional so an index written before it existed still
/// decodes at version 1 instead of being read as corrupt and thrown away.
private struct AIIndexEnvelope: Codable {
    var version: Int
    var records: [String: AIRecord]
    var failures: [String: AIFailure]?
}

@Observable
@MainActor
final class AIIndex {
    static var defaultFile: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Shotput", isDirectory: true).appendingPathComponent("ai-index.json")
    }

    private(set) var records: [String: AIRecord] = [:]
    private(set) var failures: [String: AIFailure] = [:]

    private let fileURL: URL
    private let logger = Logger(subsystem: "com.shotput.app", category: "ai-index")
    private var saveTask: Task<Void, Never>?
    private var isLoading = false
    private var holdsFileContents = false

    /// `applicationWillTerminate` can call `saveNow()` while `load()` is
    /// still decoding, when `records` is empty and writing it would erase
    /// every stored description. The same holds before a load starts, so
    /// saving waits until either a load has landed or something has been
    /// recorded.
    private var canSave: Bool { !isLoading && holdsFileContents }

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    func record(for url: URL) -> AIRecord? {
        records[url.path]
    }

    func set(_ record: AIRecord, for url: URL) {
        records[url.path] = record
        failures.removeValue(forKey: url.path)
        scheduleSave()
    }

    /// Replaces the vector without touching the description, so a change of
    /// embedder costs one text embed rather than a second describe.
    func setVector(_ vector: [Float], embedderID: String, for url: URL) {
        guard var record = records[url.path] else { return }
        record.vector = vector
        record.embedderID = embedderID
        records[url.path] = record
        scheduleSave()
    }

    func remove(_ url: URL) {
        records.removeValue(forKey: url.path)
        failures.removeValue(forKey: url.path)
        scheduleSave()
    }

    func prune(keeping urls: [URL]) {
        let keep = Set(urls.map(\.path))
        records = records.filter { keep.contains($0.key) }
        failures = failures.filter { keep.contains($0.key) }
        scheduleSave()
    }

    func failure(for url: URL) -> AIFailure? {
        failures[url.path]
    }

    func setFailure(_ failure: AIFailure, for url: URL) {
        failures[url.path] = failure
        scheduleSave()
    }

    func clearFailure(for url: URL) {
        guard failures.removeValue(forKey: url.path) != nil else { return }
        scheduleSave()
    }

    func clearFailures() {
        guard !failures.isEmpty else { return }
        failures = [:]
        scheduleSave()
    }

    /// A screenshot that gave up is deliberately not undescribed work: it
    /// stays out until the user retries it, or every sync would requeue it.
    func undescribed(in shots: [Screenshot]) -> [Screenshot] {
        shots.filter { records[$0.url.path] == nil && failures[$0.url.path] == nil }
    }

    func entriesWithVectors(embedderID: String) -> [(path: String, vector: [Float])] {
        records.compactMap { path, record in
            guard record.embedderID == embedderID, let vector = record.vector else { return nil }
            return (path, vector)
        }
    }

    func load() async {
        isLoading = true
        let fileURL = self.fileURL
        let outcome = await Task.detached(priority: .userInitiated) {
            Self.read(from: fileURL)
        }.value

        switch outcome {
        case .loaded(let records, let failures):
            self.records = records
            self.failures = failures
        case .empty:
            records = [:]
            failures = [:]
        case .corrupt:
            logger.error("AI index at \(self.fileURL.path, privacy: .public) is corrupt or from an unsupported version; starting empty")
            records = [:]
            failures = [:]
        }
        isLoading = false
        // A corrupt or absent file still counts as loaded, or one bad file
        // would leave the index permanently unwritable.
        holdsFileContents = true
    }

    /// Flushes synchronously, for tests and for `applicationWillTerminate`.
    func saveNow() {
        guard canSave else { return }
        saveTask?.cancel()
        saveTask = nil
        guard let data = Self.encode(records, failures) else { return }
        Self.write(data, to: fileURL)
    }

    private func scheduleSave() {
        guard !isLoading else { return }
        // A record set outside a load makes memory the newer copy.
        holdsFileContents = true
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled, let self else { return }
            let snapshot = records
            let failures = self.failures
            let data = await Task.detached(priority: .utility) { Self.encode(snapshot, failures) }.value
            // The file write stays on the actor so it can't outlive its own
            // cancellation and land on top of a newer `saveNow()`.
            guard !Task.isCancelled, let data else { return }
            Self.write(data, to: fileURL)
        }
    }

    private enum LoadOutcome {
        case loaded([String: AIRecord], [String: AIFailure])
        case empty
        case corrupt
    }

    /// Decoding the whole index (every record carries an embedding vector)
    /// and stat-ing every path are both too slow to sit on the main actor at
    /// launch, so the caller runs this detached.
    private nonisolated static func read(from fileURL: URL) -> LoadOutcome {
        guard let data = try? Data(contentsOf: fileURL) else { return .empty }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let envelope = try? decoder.decode(AIIndexEnvelope.self, from: data), envelope.version == 1 else {
            return .corrupt
        }
        return .loaded(
            envelope.records.filter { FileManager.default.fileExists(atPath: $0.key) },
            (envelope.failures ?? [:]).filter { FileManager.default.fileExists(atPath: $0.key) }
        )
    }

    /// Every record carries an embedding vector, so encoding the whole index
    /// is slow enough that `scheduleSave` runs this detached.
    private nonisolated static func encode(_ records: [String: AIRecord], _ failures: [String: AIFailure]) -> Data? {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try? encoder.encode(AIIndexEnvelope(version: 1, records: records, failures: failures))
    }

    private nonisolated static func write(_ data: Data, to fileURL: URL) {
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
    }
}
