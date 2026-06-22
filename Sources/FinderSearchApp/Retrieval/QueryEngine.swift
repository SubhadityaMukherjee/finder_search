import Foundation
import FoundationModels

/// High-level search API: takes a natural-language query, embeds it, finds the top-K chunks
/// via hybrid (BM25 + semantic) retrieval. `ask()` layers RAG-style Q&A on top of the same
/// retrieval using the on-device FoundationModels LLM, with a broader synthesis path for
/// open-ended questions like "tell me everything you find about ALFIE".
struct SearchResult: Identifiable, Sendable {
    let id: UUID           // chunk ID
    let fileID: UUID
    let text: String
    let pathString: String
    let kindRaw: String
    let pageNumber: Int?
    let charStart: Int
    let charEnd: Int
    let score: Double

    var url: URL { URL(fileURLWithPath: pathString) }
    var displayName: String { url.lastPathComponent }
    var parentDirectoryName: String { url.deletingLastPathComponent().lastPathComponent }
    var kind: FileKind { FileKind(rawValue: kindRaw) ?? .txt }
}

/// What the FoundationModels LLM is allowed to do in this app.
enum LLMStatus: Sendable {
    case available
    case unavailable(String)  // reason for the UI to show
}

actor QueryEngine {
    let store: Store
    let vectorStore: VectorStore
    let embedder: EmbeddingService

    init(store: Store, vectorStore: VectorStore, embedder: EmbeddingService = .shared) {
        self.store = store
        self.vectorStore = vectorStore
        self.embedder = embedder
    }

    /// Hybrid search-as-you-type. BM25 + semantic RRF-fused, returns up to `k` chunks
    /// with the per-file diversity cap enforced. The default `k=12, maxPerFile=3` is tuned
    /// for the dropdown result list.
    func search(_ query: String, k: Int = 12, maxPerFile: Int = 3) async -> [SearchResult] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let tokens = LexicalIndex.tokenize(trimmed)

        let hits: [(entry: VectorStore.Entry, score: Double)]
        if let q = await embedder.embed(trimmed) {
            hits = await vectorStore.hybridSearch(
                queryVector: q, queryTokens: tokens, k: k, maxPerFile: maxPerFile
            )
        } else {
            // Embedding failed (very rare). Fall back to lexical-only.
            hits = await vectorStore.lexicalSearch(queryTokens: tokens, k: k, maxPerFile: maxPerFile)
        }
        return hits.map { SearchResult(
            id: $0.entry.id,
            fileID: $0.entry.fileID,
            text: $0.entry.text,
            pathString: $0.entry.pathString,
            kindRaw: $0.entry.kindRaw,
            pageNumber: $0.entry.pageNumber,
            charStart: $0.entry.charStart,
            charEnd: $0.entry.charEnd,
            score: $0.score
        ) }
    }

    func llmStatus() -> LLMStatus {
        let availability = SystemLanguageModel.default.availability
        switch availability {
        case .available:
            return .available
        case .unavailable(let reason):
            return .unavailable(reasonText(for: reason))
        @unknown default:
            return .unavailable("Unknown availability")
        }
    }

    private func reasonText(for reason: SystemLanguageModel.Availability.UnavailableReason) -> String {
        switch reason {
        case .deviceNotEligible:
            return "This Mac doesn't support Apple Intelligence."
        case .appleIntelligenceNotEnabled:
            return "Turn on Apple Intelligence in System Settings to enable Q&A."
        case .modelNotReady:
            return "Apple Intelligence is still preparing. Try again in a moment."
        @unknown default:
            return "Apple Intelligence is unavailable."
        }
    }

    /// Retrieve + LLM answer. Routes to either a narrow factual path or a broad synthesis
    /// path based on the query shape. Broad queries trigger an LLM query-understanding call
    /// that expands the user's phrasing into multiple sub-queries, each run through hybrid
    /// retrieval and merged via reciprocal rank fusion — so "tell me everything about ALFIE"
    /// surfaces every chunk that literally contains ALFIE plus semantically related ones.
    func ask(_ question: String) async throws -> QAResult {
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return QAResult(answer: "", citations: [], sources: [], broad: false)
        }

        let broad = QueryEngine.isBroadQuery(trimmed)

        let sources: [SearchResult]
        if broad {
            sources = await retrieveBroad(question: trimmed)
        } else {
            sources = await search(trimmed, k: 6, maxPerFile: 3)
        }

        guard !sources.isEmpty else {
            return QAResult(
                answer: "I couldn't find any files matching that. Try adding more folders or rephrasing.",
                citations: [],
                sources: [],
                broad: broad
            )
        }

        // Cap total context size so we don't blow the on-device model's context window.
        // Truncate the lowest-ranked sources first; keep their text intact.
        let maxContextChars = 12_000
        let truncated = truncateContext(sources, maxChars: maxContextChars)

        let contextBlock = truncated.enumerated().map { idx, r in
            var lines: [String] = []
            lines.append("[\(idx)] chunk_id: \(r.id.uuidString)")
            lines.append("source: \(r.displayName)  \(locationLabel(for: r))")
            lines.append(r.text)
            return lines.joined(separator: "\n")
        }.joined(separator: "\n\n---\n\n")

        let instructions = broad ? QueryEngine.synthesisInstructions : QueryEngine.factualInstructions

        let prompt = """
        Context passages:
        \(contextBlock)

        Question: \(trimmed)
        """

        let session = LanguageModelSession(
            model: .default,
            instructions: instructions
        )

        let response = try await session.respond(
            to: prompt,
            generating: AnswerWithCitations.self
        )
        let content = response.content

        let sourcesByID = Dictionary(uniqueKeysWithValues: truncated.map { ($0.id.uuidString, $0) })
        let validated = content.citations.compactMap { citation -> QACitation? in
            guard let src = sourcesByID[citation.chunkID] else { return nil }
            return QACitation(
                chunkID: src.id,
                fileID: src.fileID,
                pathString: src.pathString,
                displayName: src.displayName,
                pageNumber: src.pageNumber,
                charStart: src.charStart,
                charEnd: src.charEnd,
                kindRaw: src.kindRaw,
                quote: citation.quote
            )
        }

        return QAResult(
            answer: content.answer,
            citations: validated,
            sources: truncated,
            broad: broad
        )
    }

    /// Broad retrieval: ask the LLM to expand the user's question into 3–5 sub-queries,
    /// run hybrid retrieval for each, RRF-merge across all sub-query rankings. Returns up
    /// to 30 sources with a looser per-file cap so a multi-document synthesis is possible.
    private func retrieveBroad(question: String) async -> [SearchResult] {
        var subQueries: [String] = [question]
        if let plan = await generateQueryPlan(question: question) {
            // De-dup case-insensitively while preserving order; cap at 5 sub-queries total.
            var seen: Set<String> = [question.lowercased()]
            for sq in plan.searchQueries {
                let key = sq.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
                guard !key.isEmpty, !seen.contains(key) else { continue }
                seen.insert(key)
                subQueries.append(sq)
                if subQueries.count >= 5 { break }
            }
        }

        // Run hybrid retrieval per sub-query, accumulate (chunkID, rank) pairs.
        var ranksByChunk: [UUID: [Int]] = [:]
        var resultByID: [UUID: SearchResult] = [:]
        for subQ in subQueries {
            let hits = await search(subQ, k: 30, maxPerFile: 8)
            for (rank, hit) in hits.enumerated() {
                ranksByChunk[hit.id, default: []].append(rank)
                resultByID[hit.id] = hit
            }
        }

        // RRF across all sub-query rankings.
        let kConstant = 60
        let scored: [(SearchResult, Double)] = ranksByChunk.compactMap { id, ranks in
            guard let result = resultByID[id] else { return nil }
            let score = ranks.reduce(0.0) { acc, rank in
                acc + 1.0 / Double(kConstant + rank + 1)
            }
            return (result, score)
        }.sorted { $0.1 > $1.1 }

        return Array(scored.prefix(30).map { $0.0 })
    }

    /// One LLM call to expand a broad question into 3–5 alternative search strings. Failure
    /// is non-fatal — we just fall back to running only the original query.
    private func generateQueryPlan(question: String) async -> QueryPlan? {
        let session = LanguageModelSession(
            model: .default,
            instructions: QueryEngine.queryPlannerInstructions
        )
        do {
            let response = try await session.respond(
                to: "User query: \(question)",
                generating: QueryPlan.self
            )
            return response.content
        } catch {
            print("[QueryEngine] query plan failed: \(error)")
            return nil
        }
    }

    /// Drop trailing sources until the total text size fits the budget. Source ordering is
    /// preserved (the highest-ranked source stays first). Individual source text is left
    /// intact — partial chunks are useless for citation.
    private func truncateContext(_ sources: [SearchResult], maxChars: Int) -> [SearchResult] {
        var total = 0
        var out: [SearchResult] = []
        out.reserveCapacity(sources.count)
        for source in sources {
            total += source.text.count + 80  // +80 for the header lines per source
            if total > maxChars { break }
            out.append(source)
        }
        return out.isEmpty ? Array(sources.prefix(1)) : out
    }

    private func locationLabel(for r: SearchResult) -> String {
        if let page = r.pageNumber { return "page \(page)" }
        return "char \(r.charStart)"
    }

    /// Heuristic broad-query detector. Triggers the synthesis path for queries where the
    /// user wants aggregation across many chunks rather than a narrow factual lookup.
    static func isBroadQuery(_ s: String) -> Bool {
        let lower = s.lowercased()
        let trimmed = lower.trimmingCharacters(in: .whitespacesAndNewlines)
        let tokens = trimmed.split { $0.isWhitespace }.map(String.init)
        let words = tokens.count
        if words >= 7 { return true }

        // Question-starter at the beginning of the query: "who is hrishita", "what is ALFIE",
        // "where is the runbook", etc. These are open-ended entity questions that benefit
        // from broad retrieval + synthesis — without this, the narrow path's strict prompt
        // can cause the model to echo just the entity name back as the answer.
        if let first = tokens.first {
            let starter = first.trimmingCharacters(in: CharacterSet(charactersIn: "'’?"))
            if Self.questionStarters.contains(starter) { return true }
        }

        let broadPhrases = [
            "tell me about", "tell me everything", "tell me whatever", "tell me all",
            "everything about", "everything on", "everything you", "anything about",
            "anything on", "anything you", "what do you know", "what do you have",
            "what can you tell", "what is there", "what's there",
            "summarize", "summarise", "summary of", "sum up",
            "find about", "find out about", "look up",
            "all the", "all mentions", "mentions of", "any mention",
            "find me", "show me", "list all", "list every",
            "give me", "research", "investigate",
        ]
        return broadPhrases.contains { lower.contains($0) }
    }

    private static let questionStarters: Set<String> = [
        "who", "what", "where", "when", "why", "how", "whose", "whom", "which",
        "who's", "what's", "where's", "when's", "why's", "how's",
    ]

    private static let factualInstructions = """
    You are FinderSearch, an on-device assistant that answers questions about the user's
    own files. Answer ONLY using the provided context passages. Never use outside
    knowledge. If the context does not contain the answer, say so plainly. Every
    factual claim in your answer must include a citation with the chunk_id it came
    from and a short verbatim quote.
    """

    private static let synthesisInstructions = """
    You are FinderSearch, an on-device assistant that answers questions about the user's
    own files. The user is asking an open-ended question and wants you to SYNTHESIZE
    across all provided context passages — combine information from multiple sources
    into a coherent answer, grouped by theme. Quote key phrases, dates, names, and
    numbers verbatim. Be specific; do not pad with filler. Every factual claim must
    cite the chunk_id it came from. If the context contains nothing relevant, say so
    plainly.
    """

    private static let queryPlannerInstructions = """
    You are a query planner for a personal document search engine. The user typed an
    open-ended question and you will generate alternative search queries to surface
    every relevant chunk. Output 3 to 5 short search strings. Include the literal
    entity name exactly as it would appear in a document (preserve capitalization,
    acronyms, punctuation), plus alternative phrasings and related concepts. No
    commentary, just the search strings.
    """
}

struct QAResult: Sendable {
    let answer: String
    let citations: [QACitation]
    let sources: [SearchResult]
    /// True when this answer came from the broad synthesis path. The UI uses this to
    /// show every retrieved source (not just the LLM-cited ones).
    let broad: Bool
}

struct QACitation: Identifiable, Sendable {
    let id = UUID()
    let chunkID: UUID
    let fileID: UUID
    let pathString: String
    let displayName: String
    let pageNumber: Int?
    let charStart: Int
    let charEnd: Int
    let kindRaw: String
    let quote: String

    var url: URL { URL(fileURLWithPath: pathString) }
    var kind: FileKind { FileKind(rawValue: kindRaw) ?? .txt }
}
