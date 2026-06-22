import Foundation
import FoundationModels

/// Structured output schema for the Q&A model. The LLM is constrained to produce JSON
/// matching this shape, so we get citations as first-class data instead of having to parse
/// them out of free-form text.
@Generable
struct AnswerWithCitations {
    /// Plain-language answer to the user's question. Must be derived only from the
    /// provided context passages — never from the model's parametric knowledge.
    var answer: String

    /// Each citation points to a chunk ID we supplied in the prompt, plus a short verbatim
    /// quote from that chunk that supports the claim.
    var citations: [Citation]

    @Generable
    struct Citation {
        /// The chunk UUID string we passed in the prompt. Used to look up the source
        /// file/line in the UI.
        var chunkID: String
        /// Short verbatim quote (≤ 200 chars) from the cited chunk.
        var quote: String
    }
}

/// Output schema for the broad-query planner. The LLM emits 3–5 alternative search strings
/// that we run through hybrid retrieval; results are RRF-merged across the set.
@Generable
struct QueryPlan {
    var searchQueries: [String]
}
