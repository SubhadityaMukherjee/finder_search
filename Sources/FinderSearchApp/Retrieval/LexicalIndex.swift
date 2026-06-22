import Foundation

/// In-memory BM25 lexical index over chunk text. Rebuilt from the same `VectorStore.entries`
/// the semantic path uses, so a single `reload()` keeps both indexes in sync.
///
/// BM25 with k1=1.5, b=0.75 — standard defaults. IDF uses the +1 smoothing variant so a term
/// present in every document still gets a non-negative weight (the original Robertson IDF can
/// go negative and produces surprising rankings on small corpora).
struct LexicalIndex {
    struct Doc {
        let chunkID: UUID
        let fileID: UUID
        let length: Int
        let termFreqs: [String: Int]
    }

    private let docs: [Doc]
    private let df: [String: Int]        // document frequency per term
    private let avgdl: Double            // average doc length in tokens
    private let k1: Double
    private let b: Double

    static let empty = LexicalIndex(docs: [], df: [:], avgdl: 0, k1: 1.5, b: 0.75)

    init(entries: [(chunkID: UUID, fileID: UUID, text: String)], k1: Double = 1.5, b: Double = 0.75) {
        var built: [Doc] = []
        built.reserveCapacity(entries.count)
        var df: [String: Int] = [:]
        var totalLen = 0

        for entry in entries {
            let tokens = LexicalIndex.tokenize(entry.text)
            var tf: [String: Int] = [:]
            tf.reserveCapacity(tokens.count)
            for t in tokens { tf[t, default: 0] += 1 }
            built.append(Doc(
                chunkID: entry.chunkID,
                fileID: entry.fileID,
                length: tokens.count,
                termFreqs: tf
            ))
            totalLen += tokens.count
            for term in tf.keys { df[term, default: 0] += 1 }
        }

        self.docs = built
        self.df = df
        self.avgdl = built.isEmpty ? 0 : Double(totalLen) / Double(built.count)
        self.k1 = k1
        self.b = b
    }

    private init(docs: [Doc], df: [String: Int], avgdl: Double, k1: Double, b: Double) {
        self.docs = docs
        self.df = df
        self.avgdl = avgdl
        self.k1 = k1
        self.b = b
    }

    var count: Int { docs.count }

    /// Top-K chunks ranked by BM25 against the query tokens. `maxPerFile` enforces the same
    /// per-file diversity cap as the semantic path so one giant file can't flood results.
    func search(
        queryTokens: [String],
        k: Int,
        maxPerFile: Int
    ) -> [(chunkID: UUID, fileID: UUID, score: Double)] {
        guard !docs.isEmpty, !queryTokens.isEmpty else { return [] }

        // Filter the query to terms actually present in the corpus; rare terms carry the
        // signal here, common terms get near-zero IDF anyway.
        let uniqueQueryTerms = Set(queryTokens)
        let n = Double(docs.count)

        var scored: [(Doc, Double)] = []
        scored.reserveCapacity(docs.count)
        for doc in docs {
            var s = 0.0
            for term in uniqueQueryTerms {
                guard let tf = doc.termFreqs[term], tf > 0 else { continue }
                guard let docFreq = df[term], docFreq > 0 else { continue }
                let idf = log(1.0 + (n - Double(docFreq) + 0.5) / (Double(docFreq) + 0.5))
                let denom = Double(tf) + k1 * (1.0 - b + b * Double(doc.length) / avgdl)
                s += idf * (Double(tf) * (k1 + 1.0)) / denom
            }
            if s > 0 { scored.append((doc, s)) }
        }
        scored.sort { $0.1 > $1.1 }

        var perFile: [UUID: Int] = [:]
        var picked: [(chunkID: UUID, fileID: UUID, score: Double)] = []
        picked.reserveCapacity(min(k, scored.count))
        for (doc, s) in scored {
            let n = perFile[doc.fileID, default: 0]
            if n >= maxPerFile { continue }
            perFile[doc.fileID] = n + 1
            picked.append((doc.chunkID, doc.fileID, s))
            if picked.count >= k { break }
        }
        return picked
    }

    /// Tokenize for BM25: lowercase, split on anything that isn't a letter or digit, drop
    /// stopwords and 1-char tokens. Acronyms survive because their lowercased form is still
    /// a unique token ("alfie" stays "alfie").
    static func tokenize(_ s: String) -> [String] {
        var out: [String] = []
        out.reserveCapacity(s.count / 5)
        var current = ""
        for ch in s.lowercased() {
            if ch.isLetter || ch.isNumber {
                current.append(ch)
            } else {
                if current.count > 1, !Self.stopwords.contains(current) {
                    out.append(current)
                }
                current = ""
            }
        }
        if current.count > 1, !Self.stopwords.contains(current) {
            out.append(current)
        }
        return out
    }

    /// Common English function words. Removing these from BOTH query and document tokens
    /// stops BM25 from overweighting "the", "and", etc. Single letters and digits are also
    /// dropped by the `count > 1` check in `tokenize`.
    private static let stopwords: Set<String> = {
        let raw = """
        the a an and or but is are was were be been being have has had do does did will would
        could should may might must can shall to of in on at by for with about against between
        into through during before after above below from up down out off over under again
        further then once here there when where why how all both each few more most other some
        such no nor not only own same so than too very just i me my myself we our ours ourselves
        you your yours yourself yourselves he him his himself she her hers herself it its itself
        they them their theirs themselves what which who whom this that these those am if because
        as until while about
        """
        return Set(raw.split(separator: " ").map(String.init))
    }()
}
