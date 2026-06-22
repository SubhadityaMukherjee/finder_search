import Foundation
import NaturalLanguage

/// Thin wrapper around the system-provided `NLEmbedding` sentence model. The model is loaded
/// once per process; subsequent calls are essentially free.
actor EmbeddingService {
    static let shared = EmbeddingService()

    private let embedding: NLEmbedding
    let dimensionality: Int

    init() {
        guard let emb = NLEmbedding.sentenceEmbedding(for: .english) else {
            fatalError("NLEmbedding.sentenceEmbedding(for: .english) is unavailable on this system")
        }
        self.embedding = emb
        self.dimensionality = emb.dimension
    }

    func embed(_ text: String) -> [Float]? {
        guard !text.isEmpty else { return nil }
        guard let v = embedding.vector(for: text) else { return nil }
        return v.map { Float($0) }
    }

    func embedBatch(_ texts: [String]) -> [[Float]?] {
        texts.map { text in
            guard !text.isEmpty, let v = embedding.vector(for: text) else { return nil }
            return v.map { Float($0) }
        }
    }
}
