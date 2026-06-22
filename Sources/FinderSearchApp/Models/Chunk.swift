import Foundation
import SwiftData

@Model
final class Chunk {
    @Attribute(.unique) var id: UUID
    var ordinal: Int
    var text: String
    /// Character offset into the **extracted** text of the source file (post-strip for HTML,
    /// post-`PDFDocument.string` for PDFs). 0-based, end-exclusive.
    var charStart: Int
    var charEnd: Int
    /// 1-based page number for PDFs; nil for non-PDF sources.
    var pageNumber: Int?
    var file: FileRecord?

    /// Raw storage for the embedding (Float32 array packed into Data). Persisted; do not access
    /// directly from UI code — use the `embedding` computed property instead.
    private var embeddingData: Data?

    init(
        id: UUID = UUID(),
        ordinal: Int,
        text: String,
        charStart: Int,
        charEnd: Int,
        pageNumber: Int? = nil
    ) {
        self.id = id
        self.ordinal = ordinal
        self.text = text
        self.charStart = charStart
        self.charEnd = charEnd
        self.pageNumber = pageNumber
        self.embeddingData = nil
    }

    var embedding: [Float]? {
        get {
            guard let data = embeddingData else { return nil }
            return data.withUnsafeBytes { rawBuffer -> [Float] in
                let pointer = rawBuffer.baseAddress!.assumingMemoryBound(to: Float.self)
                let count = data.count / MemoryLayout<Float>.size
                return UnsafeBufferPointer(start: pointer, count: count).map { $0 }
            }
        }
        set {
            guard let newValue, !newValue.isEmpty else {
                embeddingData = nil
                return
            }
            embeddingData = newValue.withUnsafeBufferPointer { buffer in
                Data(buffer: buffer)
            }
        }
    }

    var hasEmbedding: Bool { embeddingData != nil }
}
