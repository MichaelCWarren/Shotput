import Foundation

struct SearchMatch: Identifiable {
    var shot: Screenshot
    var score: Int
    var isSemantic: Bool
    var id: URL { shot.url }
}

struct SemanticSearch {
    let index: AIIndex
    let embedder: Embedder?

    init(index: AIIndex, embedder: Embedder?) {
        self.index = index
        self.embedder = embedder
    }

    /// A score means nothing on its own. Measured against real
    /// `AppleEmbedder` vectors, an unrelated query ("tax return deadline",
    /// top score 51) outscores a related one ("a walk in the hills", 33),
    /// so no constant separates them. Only the order within one query
    /// carries anything, which is why this returns a ranked shortlist and
    /// compares no score to a cutoff.
    func search(_ query: String, in shots: [Screenshot], limit: Int = 5, semanticLimit: Int = 8) async -> [SearchMatch] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        var semanticMatches: [SearchMatch] = []
        var matchedURLs = Set<URL>()

        if let embedder, let queryVector = try? await embedder.embed(trimmed) {
            let shotsByPath = Dictionary(uniqueKeysWithValues: shots.map { ($0.url.path, $0) })
            let entries = await index.entriesWithVectors(embedderID: embedder.id)
            let queryNorm = Self.norm(queryVector)
            let semantic = entries
                .compactMap { entry -> SearchMatch? in
                    guard let shot = shotsByPath[entry.path] else { return nil }
                    let score = Int(max(0, Self.cosine(queryVector, norm: queryNorm, entry.vector)) * 100)
                    // Zero is the one score that says something absolute:
                    // no overlap at all with the query.
                    guard score > 0 else { return nil }
                    return SearchMatch(shot: shot, score: score, isSemantic: true)
                }
                .sorted { $0.score > $1.score }
                .prefix(semanticLimit)
            semanticMatches = Array(semantic)
            matchedURLs.formUnion(semantic.map { $0.shot.url })
        }

        let lowered = trimmed.lowercased()
        let records = await index.records
        var substringMatches: [SearchMatch] = []
        for shot in shots where !matchedURLs.contains(shot.url) {
            let record = records[shot.url.path]
            let hit = shot.name.lowercased().contains(lowered)
                || (record?.title.lowercased().contains(lowered) ?? false)
                || (record?.summary.lowercased().contains(lowered) ?? false)
            if hit {
                substringMatches.append(SearchMatch(shot: shot, score: 100, isSemantic: false))
            }
        }
        substringMatches.sort { $0.shot.created > $1.shot.created }

        // A substring hit is the one certain match here, and a screenshot
        // with no vector has no other way in, so the semantic shortlist
        // gives up slots for them rather than filling `limit` on its own.
        let reserved = min(substringMatches.count, limit / 2)
        let matches = semanticMatches.prefix(max(0, limit - reserved)) + substringMatches
        return Array(matches.prefix(limit))
    }

    static func cosine(_ a: [Float], _ b: [Float]) -> Float {
        cosine(a, norm: norm(a), b)
    }

    /// The query vector's norm is the same for every entry in a search, so
    /// the caller computes it once and passes it in.
    static func cosine(_ a: [Float], norm normA: Float, _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty, normA > 0 else { return 0 }
        var dot: Float = 0
        var sumB: Float = 0
        for i in 0..<a.count {
            dot += a[i] * b[i]
            sumB += b[i] * b[i]
        }
        guard sumB > 0 else { return 0 }
        return dot / (normA * sqrt(sumB))
    }

    static func norm(_ vector: [Float]) -> Float {
        var sum: Float = 0
        for value in vector {
            sum += value * value
        }
        return sqrt(sum)
    }
}
