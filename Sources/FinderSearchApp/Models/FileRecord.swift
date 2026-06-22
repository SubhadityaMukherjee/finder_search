import Foundation
import SwiftData

@Model
final class FileRecord {
    @Attribute(.unique) var id: UUID
    /// Canonical, human-readable path. Used for display and grouping; not relied on for access
    /// because files can move. `bookmarkData` is the source of truth for re-opening.
    var pathString: String
    var bookmarkData: Data
    var kindRaw: String
    var sizeBytes: Int
    var modificationDate: Date
    var indexedAt: Date
    var failedReason: String?
    @Relationship(deleteRule: .cascade, inverse: \Chunk.file)
    var chunks: [Chunk]?

    init(
        id: UUID = UUID(),
        pathString: String,
        bookmarkData: Data,
        kind: FileKind,
        sizeBytes: Int,
        modificationDate: Date,
        indexedAt: Date = .now,
        failedReason: String? = nil
    ) {
        self.id = id
        self.pathString = pathString
        self.bookmarkData = bookmarkData
        self.kindRaw = kind.rawValue
        self.sizeBytes = sizeBytes
        self.modificationDate = modificationDate
        self.indexedAt = indexedAt
        self.failedReason = failedReason
        self.chunks = []
    }

    var kind: FileKind {
        get { FileKind(rawValue: kindRaw) ?? .txt }
        set { kindRaw = newValue.rawValue }
    }

    var url: URL? { URL(fileURLWithPath: pathString) }

    /// Short display name suitable for the menu bar / source list.
    var displayName: String {
        (url as NSURL?)?.lastPathComponent ?? pathString
    }

    /// The last path component's parent dir, useful for disambiguation.
    var parentDirectoryName: String {
        (url?.deletingLastPathComponent().lastPathComponent) ?? ""
    }
}
