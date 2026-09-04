import Foundation
import NaturalLanguage

protocol Embedder: Sendable {
    /// Stored alongside every vector, so vectors from a different embedder
    /// (or a different model) are never compared against each other.
    var id: String { get }
    func embed(_ text: String) async throws -> [Float]
}

/// Wraps NLEmbedding's sentence model. NLEmbedding is a plain NSObject with
/// no Sendable annotation, but its reads are documented as thread-safe, so
/// the unchecked conformance here just tells the compiler what's already true.
struct AppleEmbedder: Embedder, @unchecked Sendable {
    let id = "nl-sentence-en"

    private let embedding: NLEmbedding

    static func make() -> AppleEmbedder? {
        guard let embedding = NLEmbedding.sentenceEmbedding(for: .english) else { return nil }
        return AppleEmbedder(embedding: embedding)
    }

    private init(embedding: NLEmbedding) {
        self.embedding = embedding
    }

    func embed(_ text: String) async throws -> [Float] {
        guard let vector = embedding.vector(for: text) else {
            throw AIError.badResponse("NLEmbedding returned no vector")
        }
        return vector.map { Float($0) }
    }
}
