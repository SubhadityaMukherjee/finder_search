import Foundation

/// In-memory index of all chunk embeddings plus a BM25 lexical index over the same text.
/// Reloads from the Store on demand (at startup and after each indexing batch).
///
/// Semantic path: cosine similarity, dot-product on pre-normalized vectors.
/// Lexical path: BM25 over lowercased, stopword-filtered tokens.
/// Hybrid path: reciprocal-rank-fusion of the two — gives the semantic ranking credit for
/// conceptually related chunks the lexical ranking misses, and vice versa. Critical for
/// short name-y queries ("ALFIE") where pure sentence-embedding cosine similarity ranks
/// exact-token matches poorly.
actor VectorStore {
    struct Entry: Sendable {
        let id: UUID
        let fileID: UUID
        let text: String
        let pageNumber: Int?
        let charStart: Int
        let charEnd: Int
        let pathString: String
        let kindRaw: String
        let embedding: [Float]  // L2-normalized at load
    }

    private(set) var entries: [Entry] = []
    private(set) var dimensionality: Int = 0
    private(set) var lexical: LexicalIndex = .empty
    private let store: Store

    init(store: Store) {
        self.store = store
    }

    var count: Int { entries.count }

    func reload() async {
        do {
            let rows = try await store.allChunkEmbeddings()
            entries = rows.map {
                Entry(
                    id: $0.id,
                    fileID: $0.fileID,
                    text: $0.text,
                    pageNumber: $0.pageNumber,
                    charStart: $0.charStart,
                    charEnd: $0.charEnd,
                    pathString: $0.pathString,
                    kindRaw: $0.kindRaw,
                    embedding: normalize($0.embedding)
                )
            }
            dimensionality = entries.first?.embedding.count ?? 0
            lexical = LexicalIndex(entries: entries.map {
                (chunkID: $0.id, fileID: $0.fileID, text: $0.text)
            })
            print("[VectorStore] loaded \(entries.count) entries, dim=\(dimensionality), lexical=\(lexical.count)")
        } catch {
            print("[VectorStore] reload failed: \(error)")
            entries = []
            lexical = .empty
        }
    }

    /// Top-K nearest chunks to the query. `maxPerFile` caps how many chunks from a single
    /// file may appear, so one giant file can't dominate results.
    func search(
        query: [Float],
        k: Int = 12,
        maxPerFile: Int = 3
    ) -> [(entry: Entry, score: Double)] {
        guard !entries.isEmpty else { return [] }
        let q = normalize(query)
        guard !q.isEmpty else { return [] }

        var scored: [(Entry, Double)] = []
        scored.reserveCapacity(entries.count)
        for entry in entries {
            let score = dot(q, entry.embedding)
            scored.append((entry, Double(score)))
        }
        scored.sort { $0.1 > $1.1 }
        return pickDiverse(scored, k: k, maxPerFile: maxPerFile)
    }

    /// Top-K chunks by BM25 against the pre-tokenized query.
    func lexicalSearch(
        queryTokens: [String],
        k: Int = 12,
        maxPerFile: Int = 3
    ) -> [(entry: Entry, score: Double)] {
        guard !entries.isEmpty else { return [] }
        let hits = lexical.search(queryTokens: queryTokens, k: k * 3, maxPerFile: maxPerFile)
        let byID = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0) })
        return hits.compactMap { hit -> (Entry, Double)? in
            guard let entry = byID[hit.chunkID] else { return nil }
            return (entry, hit.score)
        }
    }

    /// Reciprocal-rank-fusion of semantic and lexical rankings. RRF is parameter-light
    /// (just `kConstant`, 60 is the canonical default from the original paper) and gracefully
    /// handles the case where one ranking is much shorter than the other.
    func hybridSearch(
        queryVector: [Float],
        queryTokens: [String],
        k: Int = 12,
        maxPerFile: Int = 3,
        kConstant: Int = 60
    ) -> [(entry: Entry, score: Double)] {
        guard !entries.isEmpty else { return [] }

        // Pull wider candidate lists from each path so fusion has something to merge, then
        // enforce the per-file cap only at the final pick.
        let semantic = search(query: queryVector, k: max(k * 2, 30), maxPerFile: .max)
        let lexical = lexicalSearch(queryTokens: queryTokens, k: max(k * 2, 30), maxPerFile: .max)

        var rrfScores: [UUID: Double] = [:]
        var entriesByID: [UUID: Entry] = [:]
        rrfScores.reserveCapacity(semantic.count + lexical.count)

        for (rank, pair) in semantic.enumerated() {
            rrfScores[pair.entry.id, default: 0] += 1.0 / Double(kConstant + rank + 1)
            entriesByID[pair.entry.id] = pair.entry
        }
        for (rank, pair) in lexical.enumerated() {
            rrfScores[pair.entry.id, default: 0] += 1.0 / Double(kConstant + rank + 1)
            entriesByID[pair.entry.id] = pair.entry
        }

        let fused: [(Entry, Double)] = rrfScores.compactMap { id, score in
            guard let entry = entriesByID[id] else { return nil }
            return (entry, score)
        }.sorted { $0.1 > $1.1 }

        return pickDiverse(fused, k: k, maxPerFile: maxPerFile)
    }

    /// Apply the per-file diversity cap to a pre-sorted candidate list.
    private func pickDiverse(
        _ scored: [(Entry, Double)],
        k: Int,
        maxPerFile: Int
    ) -> [(entry: Entry, score: Double)] {
        guard maxPerFile < Int.max else {
            return scored.prefix(k).map { (entry: $0.0, score: $0.1) }
        }
        var perFile: [UUID: Int] = [:]
        var picked: [(Entry, Double)] = []
        picked.reserveCapacity(min(k, scored.count))
        for (entry, score) in scored {
            let n = perFile[entry.fileID, default: 0]
            if n >= maxPerFile { continue }
            perFile[entry.fileID] = n + 1
            picked.append((entry, score))
            if picked.count >= k { break }
        }
        return picked.map { (entry: $0.0, score: $0.1) }
    }
}

private func normalize(_ v: [Float]) -> [Float] {
    var sumSq: Float = 0
    for x in v { sumSq += x * x }
    let mag = sqrt(sumSq)
    guard mag > 0 else { return v }
    return v.map { $0 / mag }
}

private func dot(_ a: [Float], _ b: [Float]) -> Float {
    precondition(a.count == b.count, "embedding dimension mismatch")
    var sum: Float = 0
    for i in 0..<a.count {
        sum += a[i] * b[i]
    }
    return sum
}
