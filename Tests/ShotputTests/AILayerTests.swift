import Testing
import AppKit
import Foundation
@testable import Shotput

/// An injected `kind`, a fixed result to return or throw, and a hook fired on
/// entry to `describe` so a test can count calls with `confirmation`.
struct StubProvider: DescriptionProvider {
    let kind: AIProvider
    let modelLabel: String
    let description: AIDescription?
    let error: AIError?
    let onDescribe: @Sendable () -> Void

    init(
        kind: AIProvider = .ollamaLocal,
        modelLabel: String = "stub-model",
        description: AIDescription? = nil,
        error: AIError? = nil,
        onDescribe: @escaping @Sendable () -> Void = {}
    ) {
        self.kind = kind
        self.modelLabel = modelLabel
        self.description = description
        self.error = error
        self.onDescribe = onDescribe
    }

    func describe(imageURL: URL) async throws -> AIDescription {
        onDescribe()
        if let error { throw error }
        return description ?? AIDescription(title: "Stub title", summary: "Stub summary")
    }
}

/// Suspends inside `describe` so a test can run code on the main actor while
/// an item is in flight, the way `AICoordinator`'s store observation does.
@MainActor
final class DescribeGate {
    var duringDescribe: (URL) -> Void = { _ in }
    private(set) var describeCalls: [URL] = []

    nonisolated func hit(_ url: URL) async {
        await MainActor.run {
            describeCalls.append(url)
            duringDescribe(url)
        }
    }
}

struct GateProvider: DescriptionProvider {
    let kind = AIProvider.ollamaLocal
    let modelLabel = "stub-model"
    let gate: DescribeGate
    var error: AIError?

    func describe(imageURL: URL) async throws -> AIDescription {
        await gate.hit(imageURL)
        if let error { throw error }
        return AIDescription(title: "T", summary: "S")
    }
}

/// Fails only the named file, so one run can hold an item that is retrying
/// while another is in flight.
struct SelectiveProvider: DescriptionProvider {
    let kind = AIProvider.ollamaLocal
    let modelLabel = "stub-model"
    let failing: String
    let gate: DescribeGate

    func describe(imageURL: URL) async throws -> AIDescription {
        await gate.hit(imageURL)
        if imageURL.lastPathComponent == failing { throw AIError.badResponse("nope") }
        return AIDescription(title: "T", summary: "S")
    }
}

/// Lets a test change what the provider does between drains: fail then
/// succeed for a retry, or return a new description for a re-index.
final class StubBox: @unchecked Sendable {
    var error: AIError?
    var description = AIDescription(title: "T", summary: "S")
    var describeCalls = 0
    init(error: AIError? = nil) { self.error = error }
}

struct StubEmbedder: Embedder {
    let id: String
    let vector: [Float]

    func embed(_ text: String) async throws -> [Float] { vector }
}

/// Reads as a local provider but points at a host off this Mac, which is
/// what the queue's own destination check exists for.
struct RemoteHostProvider: DescriptionProvider {
    let kind = AIProvider.ollamaLocal
    let modelLabel = "stub-model"
    var destination: URL? { URL(string: "http://box.lan:11434") }
    let onDescribe: @Sendable () -> Void

    func describe(imageURL: URL) async throws -> AIDescription {
        onDescribe()
        return AIDescription(title: "T", summary: "S")
    }
}

/// An embedder that can't answer, the way `NLEmbedding` behaves on a
/// machine where the sentence model is missing.
struct DeadEmbedder: Embedder {
    let id = "dead"

    func embed(_ text: String) async throws -> [Float] {
        throw AIError.badResponse("NLEmbedding returned no vector")
    }
}

/// Read by the queue's `settings` closure, so a test can change settings
/// mid-run without a real `SettingsStore`.
final class SettingsBox: @unchecked Sendable {
    var value: AISettings
    init(_ value: AISettings) { self.value = value }
}

/// Routes a `StubProvider`'s fixed `onDescribe` closure to whatever
/// `confirm()` the current test phase is checking, since the provider is
/// built once but `queueStopsWhenAIOff` runs two separate confirmations.
final class CallHook: @unchecked Sendable {
    private var body: @Sendable () -> Void = {}
    func set(_ body: @escaping @Sendable () -> Void) { self.body = body }
    func call() { body() }
}

private func storedTitles(at url: URL) throws -> [String] {
    struct Envelope: Decodable { var records: [String: AIRecord] }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let envelope = try decoder.decode(Envelope.self, from: Data(contentsOf: url))
    return envelope.records.values.map(\.title).sorted()
}

private func writeIndexEnvelope(at url: URL, records: [String: AIRecord], failures: [String: AIFailure] = [:]) throws {
    struct Envelope: Encodable { var version: Int; var records: [String: AIRecord]; var failures: [String: AIFailure] }
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try encoder.encode(Envelope(version: 1, records: records, failures: failures)).write(to: url)
}

@Suite struct AILayerTests {
    @Test func normalizedTrimsAndTruncates() {
        let title = String(repeating: "a", count: 40) + " " + String(repeating: "b", count: 28) + "."
        let summary = String(repeating: "x", count: 90) + "\n" + String(repeating: "y", count: 109)
        let description = AIDescription(title: title, summary: summary)

        let normalized = description.normalized()

        #expect(normalized.title == String(repeating: "a", count: 40))
        #expect(normalized.summary == String(repeating: "x", count: 90))
        #expect(normalized.title.count <= 48)
        #expect(normalized.summary.count <= 120)
    }

    @Test @MainActor func indexRoundTrip() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fileURL = dir.appendingPathComponent("ai-index.json")
        let index = AIIndex(fileURL: fileURL)
        let urlA = try makeScreenshotFile(in: dir, name: "a.png")
        let urlB = try makeScreenshotFile(in: dir, name: "b.png")
        // A whole-second timestamp: .iso8601 has no fractional-second component,
        // so a `Date()` here would never round-trip equal.
        let describedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let withVector = AIRecord(title: "Title A", summary: "Summary A", describedBy: "llava:13b", describedAt: describedAt, embedderID: "nl-sentence-en", vector: [0.1, 0.2, 0.3, 0.4])
        let withoutVector = AIRecord(title: "Title B", summary: "Summary B", describedBy: "Apple Intelligence", describedAt: describedAt, embedderID: nil, vector: nil)
        index.set(withVector, for: urlA)
        index.set(withoutVector, for: urlB)
        index.saveNow()

        let reloaded = AIIndex(fileURL: fileURL)
        await reloaded.load()

        #expect(reloaded.record(for: urlA) == withVector)
        #expect(reloaded.record(for: urlB) == withoutVector)
    }

    @Test @MainActor func indexLoadDropsMissingFiles() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fileURL = dir.appendingPathComponent("ai-index.json")
        let existingURL = try makeScreenshotFile(in: dir, name: "exists.png")
        let missingURL = dir.appendingPathComponent("missing.png")
        let record = AIRecord(title: "T", summary: "S", describedBy: "x", describedAt: Date(), embedderID: nil, vector: nil)
        try writeIndexEnvelope(at: fileURL, records: [existingURL.path: record, missingURL.path: record])

        let index = AIIndex(fileURL: fileURL)
        await index.load()

        #expect(index.record(for: existingURL) != nil)
        #expect(index.record(for: missingURL) == nil)
        #expect(index.records.count == 1)
    }

    @Test @MainActor func indexLoadToleratesCorruptFile() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fileURL = dir.appendingPathComponent("ai-index.json")
        let index = AIIndex(fileURL: fileURL)
        let seedURL = try makeScreenshotFile(in: dir, name: "seed.png")
        index.set(AIRecord(title: "T", summary: "S", describedBy: "x", describedAt: Date(), embedderID: nil, vector: nil), for: seedURL)
        index.saveNow()

        try Data("not json at all {{{".utf8).write(to: fileURL)
        await index.load()

        #expect(index.records.isEmpty)
    }

    @Test @MainActor func indexSaveBeforeLoadLandsKeepsStoredRecords() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fileURL = dir.appendingPathComponent("ai-index.json")
        let url = try makeScreenshotFile(in: dir, name: "a.png")
        let record = AIRecord(title: "Kept", summary: "S", describedBy: "x", describedAt: Date(timeIntervalSince1970: 1_700_000_000), embedderID: nil, vector: nil)
        try writeIndexEnvelope(at: fileURL, records: [url.path: record])
        let index = AIIndex(fileURL: fileURL)

        // A quit before `load()` has even started: `records` is empty and
        // must not be written over the file.
        index.saveNow()
        #expect(try storedTitles(at: fileURL) == ["Kept"])

        let load = Task { await index.load() }
        // Let `load()` reach its detached read and suspend there.
        await Task.yield()
        index.saveNow()
        #expect(try storedTitles(at: fileURL) == ["Kept"])

        await load.value
        #expect(index.record(for: url) == record)
        index.saveNow()
        #expect(try storedTitles(at: fileURL) == ["Kept"])
    }

    @Test @MainActor func indexSavesOnFirstRunWithNoFileYet() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fileURL = dir.appendingPathComponent("ai-index.json")
        let url = try makeScreenshotFile(in: dir, name: "a.png")
        let index = AIIndex(fileURL: fileURL)

        await index.load()
        index.set(AIRecord(title: "First", summary: "S", describedBy: "x", describedAt: Date(), embedderID: nil, vector: nil), for: url)
        index.saveNow()

        #expect(try storedTitles(at: fileURL) == ["First"])
    }

    @Test @MainActor func indexStaysWritableAfterCorruptLoad() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fileURL = dir.appendingPathComponent("ai-index.json")
        let url = try makeScreenshotFile(in: dir, name: "a.png")
        try Data("not json at all {{{".utf8).write(to: fileURL)
        let index = AIIndex(fileURL: fileURL)

        await index.load()
        index.set(AIRecord(title: "Fresh", summary: "S", describedBy: "x", describedAt: Date(), embedderID: nil, vector: nil), for: url)
        index.saveNow()

        #expect(try storedTitles(at: fileURL) == ["Fresh"])
    }

    @Test @MainActor func indexUndescribedAndPrune() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let index = AIIndex(fileURL: dir.appendingPathComponent("ai-index.json"))
        let urlA = try makeScreenshotFile(in: dir, name: "a.png")
        let urlB = try makeScreenshotFile(in: dir, name: "b.png")
        let shotA = Screenshot(url: urlA, created: Date(), byteSize: 1)
        let shotB = Screenshot(url: urlB, created: Date(), byteSize: 1)
        index.set(AIRecord(title: "T", summary: "S", describedBy: "x", describedAt: Date(), embedderID: nil, vector: nil), for: urlA)

        #expect(index.undescribed(in: [shotA, shotB]).map(\.url) == [urlB])

        index.prune(keeping: [])
        #expect(index.records.isEmpty)
    }

    @Test func cosine() {
        #expect(abs(SemanticSearch.cosine([1, 0, 0], [1, 0, 0]) - 1) < 0.001)
        #expect(abs(SemanticSearch.cosine([1, 0], [0, 1])) < 0.001)
        #expect(SemanticSearch.cosine([1, 0], [1, 0, 0]) == 0)
        #expect(SemanticSearch.cosine([0, 0, 0], [1, 0, 0]) == 0)
    }

    @Test func semanticSearchRanksByScore() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let index = await AIIndex(fileURL: dir.appendingPathComponent("ai-index.json"))
        let urlA = try makeScreenshotFile(in: dir, name: "a.png")
        let urlB = try makeScreenshotFile(in: dir, name: "b.png")
        let shotA = Screenshot(url: urlA, created: Date(), byteSize: 1)
        let shotB = Screenshot(url: urlB, created: Date(), byteSize: 1)
        let embedder = StubEmbedder(id: "stub", vector: [1, 0, 0])
        await index.set(AIRecord(title: "A", summary: "a", describedBy: "x", describedAt: Date(), embedderID: "stub", vector: [0.9, 0.1, 0]), for: urlA)
        await index.set(AIRecord(title: "B", summary: "b", describedBy: "x", describedAt: Date(), embedderID: "stub", vector: [0, 1, 0]), for: urlB)

        let results = await SemanticSearch(index: index, embedder: embedder).search("query", in: [shotA, shotB])

        #expect(results.map(\.shot.url) == [urlA])
        #expect(results.first?.isSemantic == true)
        #expect((results.first?.score ?? 0) >= 90)
    }

    @Test func semanticSearchKeepsAWeakBestMatch() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let index = await AIIndex(fileURL: dir.appendingPathComponent("ai-index.json"))
        let url = try makeScreenshotFile(in: dir, name: "a.png")
        let shot = Screenshot(url: url, created: Date(), byteSize: 1)
        let embedder = StubEmbedder(id: "stub", vector: [1, 0, 0])
        // Cosine 0.31: a paraphrase query against its own screenshot scores
        // about this, which the old cutoff of 55 threw away.
        await index.set(
            AIRecord(title: "A", summary: "a", describedBy: "x", describedAt: Date(), embedderID: "stub", vector: [0.31, 0.95, 0]),
            for: url
        )

        let results = await SemanticSearch(index: index, embedder: embedder).search("query", in: [shot])

        #expect(results.map(\.shot.url) == [url])
        #expect((results.first?.score ?? 0) < 55)
    }

    @Test func semanticSearchReturnsAShortlistNotTheWholeLibrary() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let index = await AIIndex(fileURL: dir.appendingPathComponent("ai-index.json"))
        var shots: [Screenshot] = []
        for i in 0..<20 {
            let url = try makeScreenshotFile(in: dir, name: "shot-\(i).png")
            shots.append(Screenshot(url: url, created: Date(), byteSize: 1))
            // Every screenshot is a little similar to the query, which is
            // what an unrelated query looks like with a real embedder.
            let vector: [Float] = [Float(i + 1) / 100, 1, 0]
            await index.set(
                AIRecord(title: "T\(i)", summary: "s", describedBy: "x", describedAt: Date(), embedderID: "stub", vector: vector),
                for: url
            )
        }
        let embedder = StubEmbedder(id: "stub", vector: [1, 0, 0])

        // The Library's call: a display cap of 200 must not turn the filter
        // into a no-op that shows every described screenshot.
        let results = await SemanticSearch(index: index, embedder: embedder).search("query", in: shots, limit: 200)

        #expect(results.count == 8)
        #expect(results.allSatisfy { $0.isSemantic })
        #expect(results.map(\.score) == results.map(\.score).sorted(by: >))
        #expect(results.first?.shot.url == shots[19].url)

        let dropdown = await SemanticSearch(index: index, embedder: embedder).search("query", in: shots, limit: 3)
        #expect(dropdown.count == 3)
    }

    @Test func semanticSearchIgnoresOtherEmbedder() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let index = await AIIndex(fileURL: dir.appendingPathComponent("ai-index.json"))
        let url = try makeScreenshotFile(in: dir, name: "a.png")
        let shot = Screenshot(url: url, created: Date(), byteSize: 1)
        let embedder = StubEmbedder(id: "stub", vector: [1, 0, 0])
        await index.set(AIRecord(title: "A", summary: "a", describedBy: "x", describedAt: Date(), embedderID: "other", vector: [1, 0, 0]), for: url)

        let results = await SemanticSearch(index: index, embedder: embedder).search("query", in: [shot])

        #expect(results.isEmpty)
    }

    @Test func substringFallback() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let index = await AIIndex(fileURL: dir.appendingPathComponent("ai-index.json"))
        let url = try makeScreenshotFile(in: dir, name: "Screenshot 2026-09-02 at 4.20.33.png")
        let shot = Screenshot(url: url, created: Date(), byteSize: 1)
        let search = SemanticSearch(index: index, embedder: nil)

        let hit = await search.search("4.20", in: [shot])
        #expect(hit.map(\.shot.url) == [url])
        #expect(hit.first?.isSemantic == false)

        let caseInsensitive = await search.search("SCREENSHOT", in: [shot])
        #expect(caseInsensitive.map(\.shot.url) == [url])

        let miss = await search.search("nothing-here", in: [shot])
        #expect(miss.isEmpty)

        let blank = await search.search("  ", in: [shot])
        #expect(blank.isEmpty)
    }

    @Test func substringUnionAfterSemantic() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let index = await AIIndex(fileURL: dir.appendingPathComponent("ai-index.json"))
        let urlA = try makeScreenshotFile(in: dir, name: "a.png")
        let urlB = try makeScreenshotFile(in: dir, name: "budget-report.png")
        let shotA = Screenshot(url: urlA, created: Date(), byteSize: 1)
        let shotB = Screenshot(url: urlB, created: Date(), byteSize: 1)
        let embedder = StubEmbedder(id: "stub", vector: [1, 0, 0])
        await index.set(AIRecord(title: "A", summary: "a", describedBy: "x", describedAt: Date(), embedderID: "stub", vector: [1, 0, 0]), for: urlA)

        let results = await SemanticSearch(index: index, embedder: embedder).search("budget", in: [shotA, shotB])

        #expect(results.map(\.shot.url) == [urlA, urlB])
        #expect(results.last?.isSemantic == false)
    }

    @Test @MainActor func queueDescribesAndIndexes() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let index = AIIndex(fileURL: dir.appendingPathComponent("ai-index.json"))
        let urlA = try makeScreenshotFile(in: dir, name: "a.png")
        let urlB = try makeScreenshotFile(in: dir, name: "b.png")
        let shots = [Screenshot(url: urlA, created: Date(), byteSize: 1), Screenshot(url: urlB, created: Date(), byteSize: 1)]
        var described: [URL] = []
        var pendingAfterDrain = -1

        await confirmation(expectedCount: 2) { confirm in
            let embedder = StubEmbedder(id: "stub", vector: [1, 0, 0])
            let queue = AIQueue(
                index: index,
                settings: { AISettings(aiEnabled: true, provider: .ollamaLocal, model: "stub-model", sendToCloud: false, cloudKey: "", ollamaHost: "") },
                resolveProvider: { _ in StubProvider(description: AIDescription(title: "T", summary: "S"), onDescribe: { confirm() }) },
                blockedReason: { _ in nil },
                resolveEmbedder: { _ in embedder }
            )
            queue.onDescribed = { url, _ in described.append(url) }

            queue.sync(shots)
            #expect(queue.pendingCount == 2)
            await queue.drain()
            pendingAfterDrain = queue.pendingCount
        }

        #expect(pendingAfterDrain == 0)
        #expect(index.record(for: urlA)?.describedBy == "stub-model")
        #expect(index.record(for: urlB)?.describedBy == "stub-model")
        #expect(index.record(for: urlA)?.vector == [1, 0, 0])
        #expect(Set(described) == Set([urlA, urlB]))
    }

    @Test @MainActor func queueSkipsAlreadyDescribed() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let index = AIIndex(fileURL: dir.appendingPathComponent("ai-index.json"))
        let urlA = try makeScreenshotFile(in: dir, name: "a.png")
        let urlB = try makeScreenshotFile(in: dir, name: "b.png")
        index.set(AIRecord(title: "Already", summary: "Done", describedBy: "stub-model", describedAt: Date(), embedderID: nil, vector: nil), for: urlA)
        let shots = [Screenshot(url: urlA, created: Date(), byteSize: 1), Screenshot(url: urlB, created: Date(), byteSize: 1)]

        await confirmation(expectedCount: 1) { confirm in
            let queue = AIQueue(
                index: index,
                settings: { AISettings(aiEnabled: true, provider: .ollamaLocal, model: "stub-model", sendToCloud: false, cloudKey: "", ollamaHost: "") },
                resolveProvider: { _ in StubProvider(description: AIDescription(title: "T", summary: "S"), onDescribe: { confirm() }) },
                blockedReason: { _ in nil },
                resolveEmbedder: { _ in nil }
            )
            queue.sync(shots)
            await queue.drain()
        }

        #expect(index.record(for: urlA)?.title == "Already")
        #expect(index.record(for: urlB) != nil)
    }

    @Test @MainActor func queueRefusesCloudWhenSendToCloudOff() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let index = AIIndex(fileURL: dir.appendingPathComponent("ai-index.json"))
        let urlA = try makeScreenshotFile(in: dir, name: "a.png")
        let urlB = try makeScreenshotFile(in: dir, name: "b.png")
        let shots = [Screenshot(url: urlA, created: Date(), byteSize: 1), Screenshot(url: urlB, created: Date(), byteSize: 1)]
        var pendingAfterDrain = -1
        var blocked: String?

        await confirmation(expectedCount: 0) { confirm in
            let queue = AIQueue(
                index: index,
                settings: { AISettings(aiEnabled: true, provider: .ollamaCloud, model: "llava:13b", sendToCloud: false, cloudKey: "k", ollamaHost: "") },
                resolveProvider: { _ in StubProvider(kind: .ollamaCloud, description: AIDescription(title: "T", summary: "S"), onDescribe: { confirm() }) },
                blockedReason: { _ in nil },
                resolveEmbedder: { _ in nil }
            )
            queue.sync(shots)
            await queue.drain()
            pendingAfterDrain = queue.pendingCount
            blocked = queue.blockedReason
        }

        #expect(pendingAfterDrain == 2)
        #expect(blocked != nil)
    }

    @Test @MainActor func queueStopsWhenAIOff() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let index = AIIndex(fileURL: dir.appendingPathComponent("ai-index.json"))
        let urlA = try makeScreenshotFile(in: dir, name: "a.png")
        let urlB = try makeScreenshotFile(in: dir, name: "b.png")
        let shots = [Screenshot(url: urlA, created: Date(), byteSize: 1), Screenshot(url: urlB, created: Date(), byteSize: 1)]
        let box = SettingsBox(AISettings(aiEnabled: false, provider: .ollamaLocal, model: "stub-model", sendToCloud: false, cloudKey: "", ollamaHost: ""))
        let hook = CallHook()
        let queue = AIQueue(
            index: index,
            settings: { box.value },
            resolveProvider: { _ in StubProvider(description: AIDescription(title: "T", summary: "S"), onDescribe: { hook.call() }) },
            blockedReason: { _ in nil },
            resolveEmbedder: { _ in nil }
        )

        await confirmation(expectedCount: 0) { confirm in
            hook.set { confirm() }
            queue.sync(shots)
            await queue.drain()
        }
        #expect(queue.pendingCount == 2)
        #expect(queue.blockedReason != nil)

        box.value.aiEnabled = true
        await confirmation(expectedCount: 2) { confirm in
            hook.set { confirm() }
            queue.kick()
            await queue.drain()
        }
        #expect(queue.pendingCount == 0)
    }

    @Test @MainActor func queueDropsAfterThreeFailures() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let index = AIIndex(fileURL: dir.appendingPathComponent("ai-index.json"))
        let url = try makeScreenshotFile(in: dir, name: "a.png")
        let shots = [Screenshot(url: url, created: Date(), byteSize: 1)]
        var pendingAfterDrain = -1
        var lastErr: String?

        await confirmation(expectedCount: 3) { confirm in
            let queue = AIQueue(
                index: index,
                settings: { AISettings(aiEnabled: true, provider: .ollamaLocal, model: "stub-model", sendToCloud: false, cloudKey: "", ollamaHost: "") },
                resolveProvider: { _ in StubProvider(error: .badResponse("nope"), onDescribe: { confirm() }) },
                blockedReason: { _ in nil },
                resolveEmbedder: { _ in nil }
            )
            queue.sync(shots)
            await queue.drain()
            pendingAfterDrain = queue.pendingCount
            lastErr = queue.lastError
        }

        #expect(pendingAfterDrain == 0)
        #expect(lastErr != nil)
    }

    @Test @MainActor func queueHaltsOnUnreachable() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let index = AIIndex(fileURL: dir.appendingPathComponent("ai-index.json"))
        let url = try makeScreenshotFile(in: dir, name: "a.png")
        let shots = [Screenshot(url: url, created: Date(), byteSize: 1)]
        var pendingAfterDrain = -1
        var blocked: String?

        await confirmation(expectedCount: 1) { confirm in
            let queue = AIQueue(
                index: index,
                settings: { AISettings(aiEnabled: true, provider: .ollamaLocal, model: "stub-model", sendToCloud: false, cloudKey: "", ollamaHost: "") },
                resolveProvider: { _ in StubProvider(error: .unreachable(URL(string: "http://box:11434")!), onDescribe: { confirm() }) },
                blockedReason: { _ in nil },
                resolveEmbedder: { _ in nil }
            )
            queue.sync(shots)
            await queue.drain()
            pendingAfterDrain = queue.pendingCount
            blocked = queue.blockedReason
        }

        #expect(pendingAfterDrain == 1)
        #expect(blocked != nil)
    }

    @Test @MainActor func queuePrunesOnSync() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let index = AIIndex(fileURL: dir.appendingPathComponent("ai-index.json"))
        let staleURL = try makeScreenshotFile(in: dir, name: "stale.png")
        index.set(AIRecord(title: "Stale", summary: "s", describedBy: "x", describedAt: Date(), embedderID: nil, vector: nil), for: staleURL)

        let queue = AIQueue(
            index: index,
            settings: { AISettings(aiEnabled: false, provider: .ollamaLocal, model: "stub-model", sendToCloud: false, cloudKey: "", ollamaHost: "") },
            resolveProvider: { _ in nil },
            blockedReason: { _ in nil },
            resolveEmbedder: { _ in nil }
        )
        queue.sync([])

        #expect(index.record(for: staleURL) == nil)
    }

    @Test func registryChoicesAndGating() throws {
        let registry = ProviderRegistry()
        let cloudOffSettings = AISettings(aiEnabled: true, provider: .appleLocal, model: "llava:13b", sendToCloud: false, cloudKey: "", ollamaHost: "")
        let cloudOnSettings = AISettings(aiEnabled: true, provider: .ollamaCloud, model: "llava:13b", sendToCloud: true, cloudKey: "k", ollamaHost: "")

        let offChoices = registry.choices(for: cloudOffSettings)
        let cloudOffChoice = try #require(offChoices.first { $0.id == .ollamaCloud })
        #expect(cloudOffChoice.isEnabled == false)
        #expect(cloudOffChoice.disabledReason != nil)
        #expect(offChoices.count == AIProvider.allCases.count)
        #expect(offChoices.map(\.id) == AIProvider.allCases)

        let onChoices = registry.choices(for: cloudOnSettings)
        let cloudOnChoice = try #require(onChoices.first { $0.id == .ollamaCloud })
        #expect(cloudOnChoice.isEnabled == true)

        var unavailable = ProviderRegistry()
        unavailable.appleAvailable = { false }
        let appleChoice = try #require(unavailable.choices(for: cloudOffSettings).first { $0.id == .appleLocal })
        #expect(appleChoice.isEnabled == false)

        #expect(registry.provider(for: AISettings(aiEnabled: true, provider: .ollamaCloud, model: "llava:13b", sendToCloud: false, cloudKey: "k", ollamaHost: "")) == nil)
        #expect(registry.provider(for: AISettings(aiEnabled: true, provider: .ollamaCloud, model: "llava:13b", sendToCloud: true, cloudKey: "", ollamaHost: "")) == nil)
        #expect(registry.provider(for: AISettings(aiEnabled: false, provider: .ollamaLocal, model: "llava:13b", sendToCloud: false, cloudKey: "", ollamaHost: "")) == nil)

        let cloudProvider = try #require(registry.provider(for: cloudOnSettings) as? OllamaProvider)
        #expect(cloudProvider.kind == .ollamaCloud)
        #expect(cloudProvider.model == "llava:13b")

        let localSettings = AISettings(aiEnabled: true, provider: .ollamaLocal, model: "llava:13b", sendToCloud: false, cloudKey: "", ollamaHost: "")
        let localProvider = try #require(registry.provider(for: localSettings) as? OllamaProvider)
        #expect(localProvider.kind == .ollamaLocal)
        #expect(localProvider.model == "llava:13b")
    }

    @Test func registryUsesOllamaHost() throws {
        let registry = ProviderRegistry()

        // A host that isn't on this Mac only resolves with egress on; the
        // gate itself is covered by `registryGatesEgressByDestination`.
        let custom = try #require(registry.provider(for: AISettings(aiEnabled: true, provider: .ollamaLocal, model: "llava:13b", sendToCloud: true, cloudKey: "", ollamaHost: "http://box:11434")) as? OllamaProvider)
        #expect(custom.client.host == URL(string: "http://box:11434")!)

        let empty = try #require(registry.provider(for: AISettings(aiEnabled: true, provider: .ollamaLocal, model: "llava:13b", sendToCloud: false, cloudKey: "", ollamaHost: "")) as? OllamaProvider)
        #expect(empty.client.host == OllamaClient.defaultLocalHost)

        let bad = try #require(registry.provider(for: AISettings(aiEnabled: true, provider: .ollamaLocal, model: "llava:13b", sendToCloud: false, cloudKey: "", ollamaHost: "not a url")) as? OllamaProvider)
        #expect(bad.client.host == OllamaClient.defaultLocalHost)

        let cloud = try #require(registry.provider(for: AISettings(aiEnabled: true, provider: .ollamaCloud, model: "llava:13b", sendToCloud: true, cloudKey: "k", ollamaHost: "http://box:11434")) as? OllamaProvider)
        #expect(cloud.client.host == OllamaClient.cloudHost)
    }

    @Test func registryGatesEgressByDestination() throws {
        let registry = ProviderRegistry()
        func settings(host: String, sendToCloud: Bool) -> AISettings {
            AISettings(aiEnabled: true, provider: .ollamaLocal, model: "llava:13b", sendToCloud: sendToCloud, cloudKey: "", ollamaHost: host)
        }

        // The empty host falls back to the default local one, and 127.5.6.7
        // is loopback too: the whole 127/8 block stays on this Mac.
        for host in ["http://localhost:11434", "http://127.0.0.1:11434", "http://127.5.6.7:11434", "http://[::1]:11434", ""] {
            #expect(registry.provider(for: settings(host: host, sendToCloud: false)) != nil, "\(host) is on this Mac")
            #expect(registry.blockedReason(for: settings(host: host, sendToCloud: false)) == nil, "\(host) is on this Mac")
        }

        let remoteOff = settings(host: "http://box:11434", sendToCloud: false)
        #expect(registry.provider(for: remoteOff) == nil)
        #expect(registry.blockedReason(for: remoteOff) != nil)
        #expect(registry.provider(for: settings(host: "http://box:11434", sendToCloud: true)) != nil)
    }

    @Test func ollamaRequestShape() throws {
        let client = OllamaClient(host: URL(string: "http://localhost:11434")!, apiKey: "k", session: .shared)
        let chatRequest = client.makeChatRequest(model: "llava:13b", prompt: "hello", imageBase64: "abc123")
        #expect(chatRequest.url?.path == "/api/chat")
        #expect(chatRequest.httpMethod == "POST")
        #expect(chatRequest.value(forHTTPHeaderField: "Authorization") == "Bearer k")

        let body = try #require(chatRequest.httpBody)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["stream"] as? Bool == false)
        #expect(json["format"] as? String == "json")
        let messages = try #require(json["messages"] as? [[String: Any]])
        #expect(messages.count == 1)
        let images = try #require(messages.first?["images"] as? [String])
        #expect(images.count == 1)

        let noKeyClient = OllamaClient(host: URL(string: "http://localhost:11434")!, apiKey: nil, session: .shared)
        let noKeyRequest = noKeyClient.makeChatRequest(model: "llava:13b", prompt: "hi", imageBase64: "abc")
        #expect(noKeyRequest.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test func ollamaParseResponses() throws {
        #expect(try OllamaClient.parseChat(Data(#"{"message":{"role":"assistant","content":"hi"}}"#.utf8)) == "hi")
        #expect(throws: AIError.self) { try OllamaClient.parseChat(Data("{}".utf8)) }
    }

    @Test func ollamaParseDescription() throws {
        let plain = try OllamaProvider.parseDescription(#"{"title":"Xcode build error","summary":"Alert dialog."}"#)
        #expect(plain.title == "Xcode build error")
        #expect(plain.summary == "Alert dialog.")

        let fenced = try OllamaProvider.parseDescription("```json\n{\"title\":\"Xcode build error\",\"summary\":\"Alert dialog.\"}\n```")
        #expect(fenced.title == "Xcode build error")

        let withProse = try OllamaProvider.parseDescription("Sure, here you go: {\"title\":\"Xcode build error\",\"summary\":\"Alert dialog.\"} Hope that helps!")
        #expect(withProse.title == "Xcode build error")

        #expect(throws: AIError.self) { try OllamaProvider.parseDescription(#"{"summary":"x"}"#) }
    }

    @Test func ollamaProviderReportsItsModelAndWhetherItIsCloud() {
        let cloud = OllamaProvider(client: OllamaClient(host: OllamaClient.cloudHost, apiKey: "k"), model: "llava:13b", kind: .ollamaCloud)
        #expect(cloud.modelLabel == "llava:13b")
        #expect(cloud.isCloud == true)

        let local = OllamaProvider(client: OllamaClient(host: OllamaClient.defaultLocalHost, apiKey: nil), model: "llava:13b", kind: .ollamaLocal)
        #expect(local.modelLabel == "llava:13b")
        #expect(local.isCloud == false)
    }

    @Test func appleFallbackDescription() {
        let described = AppleLocalProvider.fallbackDescription(ocr: "Build failed\nNo such module 'ShotKit'", labels: ["text", "document"])
        #expect(described.title == "Build failed")
        #expect(described.summary.hasPrefix("Contains: text, document"))

        let empty = AppleLocalProvider.fallbackDescription(ocr: "", labels: [])
        #expect(empty.title == "Screenshot")
    }

    @Test @MainActor func queueSurvivesSyncEmptyingItMidDescribe() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let index = AIIndex(fileURL: dir.appendingPathComponent("ai-index.json"))
        let url = try makeScreenshotFile(in: dir, name: "a.png")
        let gate = DescribeGate()
        let queue = AIQueue(
            index: index,
            settings: { AISettings(aiEnabled: true, provider: .ollamaLocal, model: "stub-model", sendToCloud: false, cloudKey: "", ollamaHost: "") },
            resolveProvider: { _ in GateProvider(gate: gate) },
            blockedReason: { _ in nil },
            resolveEmbedder: { _ in nil }
        )
        // The capture folder changes, or cleanup trashes everything, while
        // the item at the head of the queue is being described.
        gate.duringDescribe = { [weak queue] _ in queue?.sync([]) }

        queue.sync([Screenshot(url: url, created: Date(), byteSize: 1)])
        await queue.drain()

        #expect(gate.describeCalls == [url])
        #expect(queue.pendingCount == 0)
    }

    @Test @MainActor func queueDescribesOnceWhenSyncPrependsMidDescribe() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let index = AIIndex(fileURL: dir.appendingPathComponent("ai-index.json"))
        let urlA = try makeScreenshotFile(in: dir, name: "a.png")
        let urlB = try makeScreenshotFile(in: dir, name: "b.png")
        let shotA = Screenshot(url: urlA, created: Date(), byteSize: 1)
        let shotB = Screenshot(url: urlB, created: Date(), byteSize: 1)
        let gate = DescribeGate()
        let queue = AIQueue(
            index: index,
            settings: { AISettings(aiEnabled: true, provider: .ollamaLocal, model: "stub-model", sendToCloud: false, cloudKey: "", ollamaHost: "") },
            resolveProvider: { _ in GateProvider(gate: gate) },
            blockedReason: { _ in nil },
            resolveEmbedder: { _ in nil }
        )
        // A new screenshot lands while A is in flight, so `sync` puts B at
        // the head of the queue ahead of the item being described.
        gate.duringDescribe = { [weak queue, weak gate] _ in
            guard let queue, gate?.describeCalls.count == 1 else { return }
            queue.sync([shotB, shotA])
        }

        queue.sync([shotA])
        await queue.drain()

        #expect(gate.describeCalls.count == 2)
        #expect(Set(gate.describeCalls) == Set([urlA, urlB]))
        #expect(queue.pendingCount == 0)
        #expect(index.record(for: urlB) != nil)
    }

    @Test @MainActor func queueDoesNotRetryURLSyncRemovedMidDescribe() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let index = AIIndex(fileURL: dir.appendingPathComponent("ai-index.json"))
        let url = try makeScreenshotFile(in: dir, name: "a.png")
        let gate = DescribeGate()
        let queue = AIQueue(
            index: index,
            settings: { AISettings(aiEnabled: true, provider: .ollamaLocal, model: "stub-model", sendToCloud: false, cloudKey: "", ollamaHost: "") },
            resolveProvider: { _ in GateProvider(gate: gate, error: .badResponse("nope")) },
            blockedReason: { _ in nil },
            resolveEmbedder: { _ in nil }
        )
        gate.duringDescribe = { [weak queue] _ in queue?.sync([]) }

        queue.sync([Screenshot(url: url, created: Date(), byteSize: 1)])
        await queue.drain()

        #expect(gate.describeCalls == [url])
        #expect(queue.pendingCount == 0)
    }

    @Test @MainActor func queueRecordsGiveUpAfterThreeFailures() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let index = AIIndex(fileURL: dir.appendingPathComponent("ai-index.json"))
        let url = try makeScreenshotFile(in: dir, name: "a.png")
        let shots = [Screenshot(url: url, created: Date(), byteSize: 1)]
        var describeCount = 0
        let queue = AIQueue(
            index: index,
            settings: { AISettings(aiEnabled: true, provider: .ollamaLocal, model: "stub-model", sendToCloud: false, cloudKey: "", ollamaHost: "") },
            resolveProvider: { _ in StubProvider(error: .badResponse("nope")) },
            blockedReason: { _ in nil },
            resolveEmbedder: { _ in nil }
        )
        queue.onDescribed = { _, _ in describeCount += 1 }

        queue.sync(shots)
        await queue.drain()

        let failure = try #require(index.failure(for: url))
        #expect(failure.attempts == 3)
        #expect(failure.reason == AIError.badResponse("nope").errorDescription)
        #expect(queue.state(for: url) == .gaveUp(reason: failure.reason, detail: failure.detail))
        #expect(queue.status.failedCount == 1)
        #expect(queue.failures.map(\.url) == [url])
        #expect(describeCount == 0)

        // A later rescan must not put a given-up screenshot back in line.
        queue.sync(shots)
        #expect(queue.pendingCount == 0)

        await queue.drain()
        #expect(index.failure(for: url)?.attempts == 3)
    }

    @Test @MainActor func queueGivesUpAtOnceOnUnreadableImage() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let index = AIIndex(fileURL: dir.appendingPathComponent("ai-index.json"))
        let url = try makeScreenshotFile(in: dir, name: "a.png")
        let queue = AIQueue(
            index: index,
            settings: { AISettings(aiEnabled: true, provider: .ollamaLocal, model: "stub-model", sendToCloud: false, cloudKey: "", ollamaHost: "") },
            resolveProvider: { _ in StubProvider(error: .imageUnreadable(url)) },
            blockedReason: { _ in nil },
            resolveEmbedder: { _ in nil }
        )

        queue.sync([Screenshot(url: url, created: Date(), byteSize: 1)])
        await queue.drain()

        #expect(index.failure(for: url)?.attempts == 1)
        #expect(queue.pendingCount == 0)
    }

    @Test @MainActor func failuresSurviveRelaunch() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("ai-index.json")
        let url = try makeScreenshotFile(in: dir, name: "a.png")
        let index = AIIndex(fileURL: file)
        index.setFailure(AIFailure(reason: "nope", failedAt: Date(timeIntervalSince1970: 1000), attempts: 3), for: url)
        index.saveNow()

        let reloaded = AIIndex(fileURL: file)
        await reloaded.load()

        #expect(reloaded.failure(for: url)?.reason == "nope")
        #expect(reloaded.failure(for: url)?.attempts == 3)
    }

    @Test @MainActor func retryClearsFailureAndDescribes() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let index = AIIndex(fileURL: dir.appendingPathComponent("ai-index.json"))
        let url = try makeScreenshotFile(in: dir, name: "a.png")
        let box = StubBox(error: .badResponse("nope"))
        let queue = AIQueue(
            index: index,
            settings: { AISettings(aiEnabled: true, provider: .ollamaLocal, model: "stub-model", sendToCloud: false, cloudKey: "", ollamaHost: "") },
            resolveProvider: { [box] _ in StubProvider(description: box.description, error: box.error) },
            blockedReason: { _ in nil },
            resolveEmbedder: { _ in nil }
        )

        queue.sync([Screenshot(url: url, created: Date(), byteSize: 1)])
        await queue.drain()
        #expect(index.failure(for: url) != nil)

        box.error = nil
        queue.retry(url)
        #expect(index.failure(for: url) == nil)
        #expect(queue.pendingCount == 1)
        await queue.drain()

        #expect(index.record(for: url) != nil)
        #expect(queue.state(for: url) == .described)
        #expect(queue.status.failedCount == 0)
        #expect(queue.status.describedCount == 1)
    }

    @Test @MainActor func retryAllFailedRequeuesEveryGivenUpScreenshot() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let index = AIIndex(fileURL: dir.appendingPathComponent("ai-index.json"))
        let urlA = try makeScreenshotFile(in: dir, name: "a.png")
        let urlB = try makeScreenshotFile(in: dir, name: "b.png")
        let box = StubBox(error: .badResponse("nope"))
        let queue = AIQueue(
            index: index,
            settings: { AISettings(aiEnabled: true, provider: .ollamaLocal, model: "stub-model", sendToCloud: false, cloudKey: "", ollamaHost: "") },
            resolveProvider: { [box] _ in StubProvider(description: box.description, error: box.error) },
            blockedReason: { _ in nil },
            resolveEmbedder: { _ in nil }
        )

        queue.sync([
            Screenshot(url: urlA, created: Date(), byteSize: 1),
            Screenshot(url: urlB, created: Date(), byteSize: 1)
        ])
        await queue.drain()
        #expect(queue.status.failedCount == 2)

        box.error = nil
        queue.retryAllFailed()
        #expect(queue.pendingCount == 2)
        await queue.drain()

        #expect(queue.status.failedCount == 0)
        #expect(queue.status.describedCount == 2)
        #expect(queue.state(for: urlA) == .described)
        #expect(queue.state(for: urlB) == .described)
    }

    @Test @MainActor func stateReportsDescribingAndRetrying() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let index = AIIndex(fileURL: dir.appendingPathComponent("ai-index.json"))
        let urlA = try makeScreenshotFile(in: dir, name: "a.png")
        let urlB = try makeScreenshotFile(in: dir, name: "b.png")
        let gate = DescribeGate()
        let queue = AIQueue(
            index: index,
            settings: { AISettings(aiEnabled: true, provider: .ollamaLocal, model: "stub-model", sendToCloud: false, cloudKey: "", ollamaHost: "") },
            resolveProvider: { _ in SelectiveProvider(failing: "a.png", gate: gate) },
            blockedReason: { _ in nil },
            resolveEmbedder: { _ in nil }
        )
        var stateOfBInFlight: AIState?
        var stateOfARetrying: AIState?
        gate.duringDescribe = { [weak queue] url in
            guard let queue, url == urlB else { return }
            stateOfBInFlight = queue.state(for: urlB)
            stateOfARetrying = queue.state(for: urlA)
        }

        queue.sync([
            Screenshot(url: urlA, created: Date(), byteSize: 1),
            Screenshot(url: urlB, created: Date(), byteSize: 1)
        ])
        #expect(queue.state(for: urlA) == .queued)
        await queue.drain()

        #expect(stateOfBInFlight == .describing)
        #expect(stateOfARetrying == .retrying(attempt: 1))
        #expect(queue.state(for: urlB) == .described)
        #expect(queue.state(for: urlA) == .gaveUp(reason: AIError.badResponse("nope").errorDescription ?? "", detail: nil))
    }

    @Test @MainActor func stateIsOffForEverythingWhenAIIsOff() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let index = AIIndex(fileURL: dir.appendingPathComponent("ai-index.json"))
        let url = try makeScreenshotFile(in: dir, name: "a.png")
        let described = try makeScreenshotFile(in: dir, name: "b.png")
        index.set(AIRecord(title: "T", summary: "S", describedBy: "x", describedAt: Date(), embedderID: nil, vector: nil), for: described)
        let box = SettingsBox(AISettings(aiEnabled: false, provider: .ollamaLocal, model: "stub-model", sendToCloud: false, cloudKey: "", ollamaHost: ""))
        let queue = AIQueue(
            index: index,
            settings: { box.value },
            resolveProvider: { _ in nil },
            blockedReason: { _ in nil },
            resolveEmbedder: { _ in nil }
        )
        queue.sync([
            Screenshot(url: url, created: Date(), byteSize: 1),
            Screenshot(url: described, created: Date(), byteSize: 1)
        ])

        #expect(queue.state(for: url) == .off)
        // Described in an earlier session, but AI is off now: no marker.
        #expect(queue.state(for: described) == .off)
        // The record is still there for the moment AI comes back on.
        #expect(index.record(for: described) != nil)

        box.value.aiEnabled = true

        #expect(queue.state(for: described) == .described)
        #expect(queue.state(for: url) == .queued)
    }

    @Test @MainActor func blockedProviderIsNotAFailure() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let index = AIIndex(fileURL: dir.appendingPathComponent("ai-index.json"))
        let url = try makeScreenshotFile(in: dir, name: "a.png")
        let shots = [Screenshot(url: url, created: Date(), byteSize: 1)]
        let queue = AIQueue(
            index: index,
            settings: { AISettings(aiEnabled: true, provider: .ollamaCloud, model: "stub-model", sendToCloud: false, cloudKey: "k", ollamaHost: "") },
            resolveProvider: { _ in StubProvider(kind: .ollamaCloud) },
            blockedReason: { _ in nil },
            resolveEmbedder: { _ in nil }
        )

        queue.sync(shots)
        await queue.drain()

        #expect(index.failures.isEmpty)
        #expect(queue.status.failedCount == 0)
        #expect(queue.status.blockedReason == AIError.cloudBlocked.errorDescription)
        #expect(queue.state(for: url) == .queued)
        #expect(queue.status.pendingCount == 1)
        #expect(queue.status.isRunning == false)
    }

    @Test @MainActor func queueBlocksAProviderPointingOffThisMac() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let index = AIIndex(fileURL: dir.appendingPathComponent("ai-index.json"))
        let url = try makeScreenshotFile(in: dir, name: "a.png")
        let shots = [Screenshot(url: url, created: Date(), byteSize: 1)]
        let box = StubBox()
        let settings = SettingsBox(AISettings(aiEnabled: true, provider: .ollamaLocal, model: "m", sendToCloud: false, cloudKey: "", ollamaHost: "http://box.lan:11434"))
        // The registry is told to allow it, which is the point: this is the
        // last check before the image would leave, and it stands on its own.
        let queue = AIQueue(
            index: index,
            settings: { settings.value },
            resolveProvider: { [box] _ in RemoteHostProvider(onDescribe: { box.describeCalls += 1 }) },
            blockedReason: { _ in nil },
            resolveEmbedder: { _ in nil }
        )

        queue.sync(shots)
        await queue.drain()

        #expect(box.describeCalls == 0)
        #expect(queue.status.blockedReason == AIError.offMachineBlocked(URL(string: "http://box.lan:11434")!).errorDescription)
        #expect(index.failures.isEmpty)
        #expect(queue.state(for: url) == .queued)

        settings.value.sendToCloud = true
        queue.settingsChanged(shots)
        await queue.drain()

        #expect(box.describeCalls == 1)
        #expect(index.record(for: url) != nil)
    }

    @Test @MainActor func unreachableHostLeavesNoFailureRecord() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let index = AIIndex(fileURL: dir.appendingPathComponent("ai-index.json"))
        let url = try makeScreenshotFile(in: dir, name: "a.png")
        let queue = AIQueue(
            index: index,
            settings: { AISettings(aiEnabled: true, provider: .ollamaLocal, model: "stub-model", sendToCloud: false, cloudKey: "", ollamaHost: "") },
            resolveProvider: { _ in StubProvider(error: .unreachable(URL(string: "http://127.0.0.1:11434")!)) },
            blockedReason: { _ in nil },
            resolveEmbedder: { _ in nil }
        )

        queue.sync([Screenshot(url: url, created: Date(), byteSize: 1)])
        await queue.drain()

        #expect(index.failures.isEmpty)
        #expect(queue.state(for: url) == .queued)
        #expect(queue.status.blockedReason != nil)
    }

    @Test @MainActor func reindexDropsTheRecordBeforeDescribingAgain() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let index = AIIndex(fileURL: dir.appendingPathComponent("ai-index.json"))
        let url = try makeScreenshotFile(in: dir, name: "a.png")
        let box = StubBox()
        box.description = AIDescription(title: "Old", summary: "Old summary")
        let queue = AIQueue(
            index: index,
            settings: { AISettings(aiEnabled: true, provider: .ollamaLocal, model: "stub-model", sendToCloud: false, cloudKey: "", ollamaHost: "") },
            resolveProvider: { [box] _ in StubProvider(description: box.description, error: box.error) },
            blockedReason: { _ in nil },
            resolveEmbedder: { _ in StubEmbedder(id: "stub", vector: [1, 0, 0]) }
        )

        queue.sync([Screenshot(url: url, created: Date(), byteSize: 1)])
        await queue.drain()
        #expect(index.record(for: url)?.title == "Old")
        #expect(index.entriesWithVectors(embedderID: "stub").count == 1)

        box.description = AIDescription(title: "New", summary: "New summary")
        queue.reindex(url)

        // Checked before the drain: a semantic search in this window must
        // not still find the description being replaced.
        #expect(index.record(for: url) == nil)
        #expect(index.entriesWithVectors(embedderID: "stub").isEmpty)
        #expect(queue.state(for: url) == .queued)
        #expect(queue.pendingCount == 1)

        await queue.drain()

        #expect(index.record(for: url)?.title == "New")
        #expect(queue.state(for: url) == .described)
        #expect(queue.status.describedCount == 1)
    }

    @Test @MainActor func reindexReadsAsDescribingWhileInFlight() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let index = AIIndex(fileURL: dir.appendingPathComponent("ai-index.json"))
        let url = try makeScreenshotFile(in: dir, name: "a.png")
        let gate = DescribeGate()
        let queue = AIQueue(
            index: index,
            settings: { AISettings(aiEnabled: true, provider: .ollamaLocal, model: "stub-model", sendToCloud: false, cloudKey: "", ollamaHost: "") },
            resolveProvider: { _ in GateProvider(gate: gate) },
            blockedReason: { _ in nil },
            resolveEmbedder: { _ in nil }
        )

        queue.sync([Screenshot(url: url, created: Date(), byteSize: 1)])
        await queue.drain()
        #expect(queue.state(for: url) == .described)

        var stateWhileReindexing: AIState?
        gate.duringDescribe = { [weak queue] _ in stateWhileReindexing = queue?.state(for: url) }
        queue.reindex(url)
        await queue.drain()

        #expect(stateWhileReindexing == .describing)
        #expect(gate.describeCalls == [url, url])
    }

    @Test @MainActor func reindexRevivesAGivenUpScreenshot() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let index = AIIndex(fileURL: dir.appendingPathComponent("ai-index.json"))
        let url = try makeScreenshotFile(in: dir, name: "a.png")
        let box = StubBox(error: .badResponse("nope"))
        let queue = AIQueue(
            index: index,
            settings: { AISettings(aiEnabled: true, provider: .ollamaLocal, model: "stub-model", sendToCloud: false, cloudKey: "", ollamaHost: "") },
            resolveProvider: { [box] _ in StubProvider(description: box.description, error: box.error) },
            blockedReason: { _ in nil },
            resolveEmbedder: { _ in nil }
        )

        queue.sync([Screenshot(url: url, created: Date(), byteSize: 1)])
        await queue.drain()
        #expect(index.failure(for: url) != nil)

        box.error = nil
        queue.reindex(url)
        #expect(index.failure(for: url) == nil)
        #expect(queue.state(for: url) == .queued)

        await queue.drain()

        #expect(queue.state(for: url) == .described)
        #expect(queue.status.failedCount == 0)
    }

    @Test @MainActor func reindexQueuesAScreenshotTheQueueNeverSaw() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let index = AIIndex(fileURL: dir.appendingPathComponent("ai-index.json"))
        let url = try makeScreenshotFile(in: dir, name: "a.png")
        let queue = AIQueue(
            index: index,
            settings: { AISettings(aiEnabled: true, provider: .ollamaLocal, model: "stub-model", sendToCloud: false, cloudKey: "", ollamaHost: "") },
            resolveProvider: { _ in StubProvider(description: AIDescription(title: "T", summary: "S")) },
            blockedReason: { _ in nil },
            resolveEmbedder: { _ in nil }
        )

        queue.reindex(url)
        #expect(queue.pendingCount == 1)
        await queue.drain()

        #expect(index.record(for: url)?.title == "T")
    }

    @Test @MainActor func redescribeAllDropsEveryRecord() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let index = AIIndex(fileURL: dir.appendingPathComponent("ai-index.json"))
        let urlA = try makeScreenshotFile(in: dir, name: "a.png")
        let urlB = try makeScreenshotFile(in: dir, name: "b.png")
        let box = StubBox()
        box.description = AIDescription(title: "Old", summary: "Old summary")
        let shots = [
            Screenshot(url: urlA, created: Date(), byteSize: 1),
            Screenshot(url: urlB, created: Date(), byteSize: 1)
        ]
        let queue = AIQueue(
            index: index,
            settings: { AISettings(aiEnabled: true, provider: .ollamaLocal, model: "stub-model", sendToCloud: false, cloudKey: "", ollamaHost: "") },
            resolveProvider: { [box] _ in StubProvider(description: box.description, error: box.error) },
            blockedReason: { _ in nil },
            resolveEmbedder: { _ in nil }
        )

        queue.sync(shots)
        await queue.drain()

        box.description = AIDescription(title: "New", summary: "New summary")
        queue.redescribeAll(shots)
        #expect(queue.pendingCount == 2)
        #expect(queue.status.describedCount == 0)

        await queue.drain()

        #expect(index.record(for: urlA)?.title == "New")
        #expect(index.record(for: urlB)?.title == "New")
    }

    /// A queue whose provider fails until `box.error` is cleared, driven by
    /// settings a test can edit between drains.
    @MainActor
    private func makeFailingQueue(index: AIIndex, box: StubBox, settings: SettingsBox) -> AIQueue {
        AIQueue(
            index: index,
            settings: { settings.value },
            resolveProvider: { [box] _ in
                StubProvider(description: box.description, error: box.error, onDescribe: { box.describeCalls += 1 })
            },
            blockedReason: { _ in nil },
            resolveEmbedder: { _ in nil }
        )
    }

    @Test @MainActor func aiConfigurationChangeClearsGiveUps() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let index = AIIndex(fileURL: dir.appendingPathComponent("ai-index.json"))
        let url = try makeScreenshotFile(in: dir, name: "a.png")
        let shots = [Screenshot(url: url, created: Date(), byteSize: 1)]
        let box = StubBox(error: .badResponse("model llava:13b is not installed"))
        let settings = SettingsBox(AISettings(aiEnabled: true, provider: .ollamaLocal, model: "llava:13b", sendToCloud: false, cloudKey: "", ollamaHost: ""))
        let queue = makeFailingQueue(index: index, box: box, settings: settings)

        queue.sync(shots)
        await queue.drain()
        #expect(index.failure(for: url)?.attempts == 3)
        #expect(box.describeCalls == 3)

        box.error = nil
        settings.value.model = "llava:7b"
        queue.settingsChanged(shots)

        #expect(queue.status.failedCount == 0)
        #expect(queue.pendingCount == 1)
        await queue.drain()

        #expect(index.record(for: url) != nil)
        #expect(box.describeCalls == 4)
    }

    @Test @MainActor func clearedGiveUpGetsAFullAttemptBudget() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let index = AIIndex(fileURL: dir.appendingPathComponent("ai-index.json"))
        let url = try makeScreenshotFile(in: dir, name: "a.png")
        let shots = [Screenshot(url: url, created: Date(), byteSize: 1)]
        let box = StubBox(error: .badResponse("nope"))
        let settings = SettingsBox(AISettings(aiEnabled: true, provider: .ollamaLocal, model: "llava:13b", sendToCloud: false, cloudKey: "", ollamaHost: ""))
        let queue = makeFailingQueue(index: index, box: box, settings: settings)

        queue.sync(shots)
        await queue.drain()
        #expect(box.describeCalls == 3)

        settings.value.model = "llava:7b"
        queue.settingsChanged(shots)
        await queue.drain()

        // Three more, not one: the cleared screenshot starts over rather
        // than giving up again on its next single failure.
        #expect(box.describeCalls == 6)
        #expect(index.failure(for: url)?.attempts == 3)
    }

    @Test @MainActor func settingsWriteWithNoRealChangeKeepsGiveUps() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let index = AIIndex(fileURL: dir.appendingPathComponent("ai-index.json"))
        let url = try makeScreenshotFile(in: dir, name: "a.png")
        let shots = [Screenshot(url: url, created: Date(), byteSize: 1)]
        let box = StubBox(error: .badResponse("nope"))
        let settings = SettingsBox(AISettings(aiEnabled: true, provider: .ollamaLocal, model: "llava:13b", sendToCloud: false, cloudKey: "", ollamaHost: ""))
        let queue = makeFailingQueue(index: index, box: box, settings: settings)

        queue.sync(shots)
        await queue.drain()
        #expect(index.failure(for: url) != nil)

        box.error = nil
        // The store persists on every write, so the same values landing
        // again must not spend another describe.
        settings.value.model = "llava:13b"
        queue.settingsChanged(shots)
        await queue.drain()

        #expect(index.failure(for: url) != nil)
        #expect(queue.pendingCount == 0)
        #expect(box.describeCalls == 3)
    }

    @Test @MainActor func egressToggleIsAChangeWithNothingToClear() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let index = AIIndex(fileURL: dir.appendingPathComponent("ai-index.json"))
        let url = try makeScreenshotFile(in: dir, name: "a.png")
        let shots = [Screenshot(url: url, created: Date(), byteSize: 1)]
        let box = StubBox()
        let settings = SettingsBox(AISettings(aiEnabled: true, provider: .ollamaCloud, model: "m", sendToCloud: false, cloudKey: "k", ollamaHost: ""))
        let queue = AIQueue(
            index: index,
            settings: { settings.value },
            resolveProvider: { [box] _ in
                StubProvider(kind: .ollamaCloud, description: box.description, error: box.error, onDescribe: { box.describeCalls += 1 })
            },
            blockedReason: { _ in nil },
            resolveEmbedder: { _ in nil }
        )

        queue.sync(shots)
        await queue.drain()
        #expect(index.failures.isEmpty)
        #expect(box.describeCalls == 0)
        #expect(queue.status.blockedReason == AIError.cloudBlocked.errorDescription)

        settings.value.sendToCloud = true
        queue.settingsChanged(shots)
        await queue.drain()

        #expect(index.record(for: url) != nil)
        #expect(index.failures.isEmpty)
        #expect(queue.pendingCount == 0)
    }

    @Test @MainActor func coordinatorClearsGiveUpsOnAModelChange() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let settings = testSettings(folder: dir)
        // AI stays off so no provider is ever resolved and the test never
        // reaches the network; clearing doesn't depend on it.
        settings.aiEnabled = false
        settings.aiProvider = .ollamaLocal
        settings.aiModel = "llava:13b"
        let url = try makeScreenshotFile(in: dir, name: "a.png")
        let file = dir.appendingPathComponent("ai-index.json")
        try writeIndexEnvelope(
            at: file,
            records: [:],
            failures: [url.path: AIFailure(reason: "model llava:13b is not installed", failedAt: Date(), attempts: 3)]
        )
        let store = ScreenshotStore(settings: settings, pinsFile: dir.appendingPathComponent("pins.json"))
        store.rescan()
        let ai = AICoordinator(settings: settings, store: store, index: AIIndex(fileURL: file))
        ai.start()
        defer {
            ai.stop()
            store.stop()
        }

        #expect(await poll { ai.status.failedCount == 1 })

        settings.aiModel = "llava:13b"
        // Bounded on purpose. The claim is that a sweep never runs, so the
        // window has to be long enough for one to show up (the change below
        // lands its own well inside 400 ms) and no longer, since every run
        // pays it in full.
        let sweptOnAWriteOfTheSameValue = await poll(timeout: .milliseconds(400)) { ai.status.failedCount == 0 }
        #expect(sweptOnAWriteOfTheSameValue == false)

        settings.aiModel = "llava:7b"
        #expect(await poll { ai.status.failedCount == 0 })
    }

    @Test func httpErrorNamesTheMissingModel() {
        let error = AIError.http(404, #"{"error":"model 'llava:13b' not found, try pulling it first"}"#)

        #expect(error.errorDescription == "Model llava:13b isn't installed. Run ollama pull llava:13b")
        #expect(!(error.errorDescription ?? "").contains("{"))
        #expect(error.debugDescription.contains(#"{"error""#))
        #expect(error.debugDescription.hasPrefix("Model llava:13b isn't installed"))
    }

    @Test func httpErrorReadsAsASentence() throws {
        #expect(AIError.http(401, #"{"error":"unauthorized"}"#).errorDescription == "Ollama rejected the API key")
        #expect(AIError.http(429, "").errorDescription == "Ollama is rate limiting. Try again in a few minutes")
        #expect(AIError.http(503, "").errorDescription == "Ollama answered 503")
        // No status code in front: the row has no width to spare for it.
        #expect(AIError.http(502, "upstream timeout").errorDescription == "upstream timeout")
        #expect(AIError.http(500, #"{"error":"model requires more system memory"}"#).errorDescription == "model requires more system memory")
        #expect(AIError.http(500, #"{"error":{"message":"out of memory","type":"server"}}"#).errorDescription == "out of memory")
        // A body cut off mid-JSON keeps its text rather than disappearing
        // into a generic message.
        #expect(AIError.http(404, #"{"error":"broken json"#).errorDescription == #"{"error":"broken json"#)
        #expect(AIError.http(500, "boom").debugDescription.contains("HTTP 500"))

        // A row is one line: whatever the server sent, this is not.
        let sprawling = AIError.http(500, "{\"error\":\"panic:\n  goroutine 1\n  runtime error\"}")
        #expect(!(sprawling.errorDescription ?? "").contains("\n"))

        let long = AIError.http(500, String(repeating: "a", count: 300))
        let text = try #require(long.errorDescription)
        #expect(text.count < 130)
        #expect(text.hasSuffix("…"))
    }

    @Test func unreachableTextDependsOnTheHost() {
        let local = AIError.unreachable(URL(string: "http://127.0.0.1:11434")!)
        let remote = AIError.unreachable(URL(string: "http://box:11434")!)

        #expect(local.errorDescription == "Ollama isn't running at 127.0.0.1:11434")
        #expect(remote.errorDescription == "Can't reach Ollama at box:11434")
    }

    @Test @MainActor func giveUpKeepsTheRawBodyForATooltip() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let index = AIIndex(fileURL: dir.appendingPathComponent("ai-index.json"))
        let url = try makeScreenshotFile(in: dir, name: "a.png")
        let plain = try makeScreenshotFile(in: dir, name: "b.png")
        let box = StubBox(error: .http(404, #"{"error":"model 'llava:13b' not found"}"#))
        let settings = SettingsBox(AISettings(aiEnabled: true, provider: .ollamaLocal, model: "llava:13b", sendToCloud: false, cloudKey: "", ollamaHost: ""))
        let queue = makeFailingQueue(index: index, box: box, settings: settings)

        queue.sync([Screenshot(url: url, created: Date(), byteSize: 1)])
        await queue.drain()

        let failure = try #require(index.failure(for: url))
        #expect(failure.reason == "Model llava:13b isn't installed. Run ollama pull llava:13b")
        #expect(try #require(failure.detail).contains(#"{"error""#))
        #expect(queue.failures.first?.detail == failure.detail)

        // Nothing more to say than the reason already says, so no tooltip.
        box.error = .badResponse("Could not decode Ollama chat response")
        queue.sync([Screenshot(url: plain, created: Date(), byteSize: 1)])
        await queue.drain()

        #expect(index.failure(for: plain)?.reason == "Could not decode Ollama chat response")
        #expect(index.failure(for: plain)?.detail == nil)
    }

    @Test @MainActor func gaveUpStateCarriesTheTooltipDetail() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let index = AIIndex(fileURL: dir.appendingPathComponent("ai-index.json"))
        let url = try makeScreenshotFile(in: dir, name: "a.png")
        let box = StubBox(error: .http(404, #"{"error":"model 'llava:13b' not found"}"#))
        let settings = SettingsBox(AISettings(aiEnabled: true, provider: .ollamaLocal, model: "llava:13b", sendToCloud: false, cloudKey: "", ollamaHost: ""))
        let queue = makeFailingQueue(index: index, box: box, settings: settings)

        queue.sync([Screenshot(url: url, created: Date(), byteSize: 1)])
        await queue.drain()

        guard case .gaveUp(let reason, let detail) = queue.state(for: url) else {
            Issue.record("expected a give-up, got \(queue.state(for: url))")
            return
        }
        #expect(reason == "Model llava:13b isn't installed. Run ollama pull llava:13b")
        #expect(try #require(detail).contains(#"{"error""#))
    }

    @Test @MainActor func storedReasonsTooLongForARowAreCutWithTheWholeTextOnTheTooltip() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let index = AIIndex(fileURL: dir.appendingPathComponent("ai-index.json"))
        let url = try makeScreenshotFile(in: dir, name: "a.png")
        // What a record written before the reasons were shortened holds.
        let raw = "Server returned 404: {\"error\":\"model 'llava:13b' not found\",\n\"detail\":\"" + String(repeating: "x", count: 200) + "\"}"
        index.setFailure(AIFailure(reason: raw, failedAt: Date(), attempts: 3), for: url)
        let queue = AIQueue(
            index: index,
            settings: { AISettings(aiEnabled: true, provider: .ollamaLocal, model: "m", sendToCloud: false, cloudKey: "", ollamaHost: "") },
            resolveProvider: { _ in nil },
            blockedReason: { _ in nil },
            resolveEmbedder: { _ in nil }
        )

        guard case .gaveUp(let reason, let detail) = queue.state(for: url) else {
            Issue.record("expected a give-up, got \(queue.state(for: url))")
            return
        }
        #expect(reason.count < 130)
        #expect(reason.hasSuffix("…"))
        #expect(!reason.contains("\n"))
        #expect(detail == raw)
        #expect(queue.failures.first?.reason == reason)
        #expect(queue.failures.first?.detail == raw)
    }

    @Test func everyProviderEmbedsWithApple() throws {
        let registry = ProviderRegistry()
        let apple = try #require(AppleEmbedder.make(), "NLEmbedding's English sentence model is missing on this machine")

        for provider in AIProvider.allCases {
            // A remote host with egress on, which is the case that used to
            // route somewhere else. Nothing reaches a network now.
            let settings = AISettings(aiEnabled: true, provider: provider, model: "m", sendToCloud: true, cloudKey: "k", ollamaHost: "http://box.lan:11434")
            #expect(registry.embedder(for: settings)?.id == apple.id)
        }
    }

    @Test @MainActor func recordsWithNoVectorGetOneOnALaterKick() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let index = AIIndex(fileURL: dir.appendingPathComponent("ai-index.json"))
        let url = try makeScreenshotFile(in: dir, name: "a.png")
        // Described while no embedder was available: without a backfill this
        // screenshot never appears in a semantic result again.
        index.set(AIRecord(title: "A", summary: "a", describedBy: "x", describedAt: Date(), embedderID: nil, vector: nil), for: url)
        let queue = AIQueue(
            index: index,
            settings: { AISettings(aiEnabled: true, provider: .appleLocal, model: "m", sendToCloud: false, cloudKey: "", ollamaHost: "") },
            resolveProvider: { _ in StubProvider() },
            blockedReason: { _ in nil },
            resolveEmbedder: { _ in StubEmbedder(id: "stub", vector: [1, 0, 0]) }
        )

        queue.kick()
        await queue.drain()

        #expect(index.record(for: url)?.vector == [1, 0, 0])
        #expect(index.record(for: url)?.embedderID == "stub")
        // A text embed, not a second describe: the description is untouched.
        #expect(index.record(for: url)?.title == "A")
        #expect(index.record(for: url)?.describedBy == "x")

        let results = await SemanticSearch(index: index, embedder: StubEmbedder(id: "stub", vector: [1, 0, 0]))
            .search("anything", in: [Screenshot(url: url, created: Date(), byteSize: 1)])
        #expect(results.map(\.shot.url) == [url])
    }

    @Test @MainActor func aDeadEmbedderLeavesTheRecordAlone() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let index = AIIndex(fileURL: dir.appendingPathComponent("ai-index.json"))
        let url = try makeScreenshotFile(in: dir, name: "a.png")
        index.set(AIRecord(title: "A", summary: "a", describedBy: "x", describedAt: Date(), embedderID: nil, vector: nil), for: url)
        let queue = AIQueue(
            index: index,
            settings: { AISettings(aiEnabled: true, provider: .appleLocal, model: "m", sendToCloud: false, cloudKey: "", ollamaHost: "") },
            resolveProvider: { _ in StubProvider() },
            blockedReason: { _ in nil },
            resolveEmbedder: { _ in DeadEmbedder() }
        )

        queue.kick()
        await queue.drain()

        #expect(index.record(for: url)?.vector == nil)
        #expect(index.record(for: url)?.embedderID == nil)
        #expect(index.record(for: url)?.title == "A")
        #expect(queue.lastError != nil)
    }

    @Test @MainActor func noBackfillWhileAIIsOff() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let index = AIIndex(fileURL: dir.appendingPathComponent("ai-index.json"))
        let url = try makeScreenshotFile(in: dir, name: "a.png")
        index.set(AIRecord(title: "A", summary: "a", describedBy: "x", describedAt: Date(), embedderID: nil, vector: nil), for: url)
        let queue = AIQueue(
            index: index,
            settings: { AISettings(aiEnabled: false, provider: .appleLocal, model: "m", sendToCloud: false, cloudKey: "", ollamaHost: "") },
            resolveProvider: { _ in nil },
            blockedReason: { _ in nil },
            resolveEmbedder: { _ in StubEmbedder(id: "stub", vector: [1, 0, 0]) }
        )

        queue.kick()
        await queue.drain()

        #expect(index.record(for: url)?.vector == nil)
    }

    @Test @MainActor func settingsToAISettings() throws {
        let suiteName = "ShotputTests." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = SettingsStore(defaults: defaults, secrets: InMemorySecretStore())
        store.aiEnabled = true
        store.aiModel = "x"
        store.sendToCloud = true
        store.aiProvider = .ollamaCloud
        store.ollamaCloudKey = "k"
        store.ollamaHost = "http://box:11434"

        #expect(store.ai == AISettings(aiEnabled: true, provider: .ollamaCloud, model: "x", sendToCloud: true, cloudKey: "k", ollamaHost: "http://box:11434"))
    }
}
