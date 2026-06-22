import Foundation
import SwiftData

/// Single point of access to SwiftData from background actors (Indexer, QueryEngine).
/// SwiftUI views use `@Query` / `@Environment(\.modelContext)` directly; this actor handles
/// the writes and bulk reads that background work needs.
@ModelActor
actor Store {
    /// Sendable snapshot of a TrackedFolder for cross-actor use. SwiftData `@Model` instances
    /// are bound to their ModelContext and can't cross actor boundaries directly in Swift 6.
    struct TrackedFolderInfo: Sendable {
        let id: UUID
        let bookmarkData: Data
        let displayName: String
        let lastIndexedAt: Date?
    }

    func trackedFolders() throws -> [TrackedFolderInfo] {
        let folders = try modelContext.fetch(FetchDescriptor<TrackedFolder>())
        return folders.map {
            TrackedFolderInfo(
                id: $0.id,
                bookmarkData: $0.bookmarkData,
                displayName: $0.displayName,
                lastIndexedAt: $0.lastIndexedAt
            )
        }
    }

    @discardableResult
    func addTrackedFolder(bookmarkData: Data, displayName: String) throws -> UUID {
        let folder = TrackedFolder(bookmarkData: bookmarkData, displayName: displayName)
        modelContext.insert(folder)
        try modelContext.save()
        return folder.id
    }

    func deleteTrackedFolder(id: UUID) throws {
        let descriptor = FetchDescriptor<TrackedFolder>(
            predicate: #Predicate { $0.id == id }
        )
        if let folder = try modelContext.fetch(descriptor).first {
            modelContext.delete(folder)
            try modelContext.save()
        }
    }

    func fileRecord(forPath path: String) throws -> FileRecord? {
        let descriptor = FetchDescriptor<FileRecord>(
            predicate: #Predicate { $0.pathString == path }
        )
        return try modelContext.fetch(descriptor).first
    }

    /// Snapshot of every indexed file's path → (mtime, size, id) so the crawler can skip
    /// unchanged files in O(1) without fetching the full record graph.
    func indexedFileSnapshot() throws -> [String: (mtime: Date, size: Int, id: UUID)] {
        let descriptor = FetchDescriptor<FileRecord>()
        let records = try modelContext.fetch(descriptor)
        var out: [String: (mtime: Date, size: Int, id: UUID)] = [:]
        out.reserveCapacity(records.count)
        for r in records {
            out[r.pathString] = (r.modificationDate, r.sizeBytes, r.id)
        }
        return out
    }

    func deleteFileRecord(id: UUID) throws {
        let descriptor = FetchDescriptor<FileRecord>(
            predicate: #Predicate { $0.id == id }
        )
        if let record = try modelContext.fetch(descriptor).first {
            modelContext.delete(record)
            try modelContext.save()
        }
    }

    func counts() throws -> (files: Int, chunks: Int) {
        let files = try modelContext.fetchCount(FetchDescriptor<FileRecord>())
        let chunks = try modelContext.fetchCount(FetchDescriptor<Chunk>())
        return (files, chunks)
    }

    /// Per-folder rollup used by the Folders tab. Resolves each bookmark to a URL, then
    /// counts FileRecords whose path is the folder or a descendant. Path-component-aware
    /// ("/Users/x/Documents" matches "/Users/x/Documents/foo.txt" but NOT
    /// "/Users/x/Documents-backup/foo.txt").
    ///
    /// `resolvedURL` is nil when the bookmark is stale or unresolvable — the UI shows the
    /// folder as offline rather than hiding it.
    struct FolderStats: Sendable, Identifiable {
        let id: UUID
        let displayName: String
        let dateAdded: Date
        let lastIndexedAt: Date?
        let resolvedPath: String?
        let fileCount: Int
        let chunkCount: Int
        let failedCount: Int
    }

    func folderStats() throws -> [FolderStats] {
        let folders = try modelContext.fetch(FetchDescriptor<TrackedFolder>())
        guard !folders.isEmpty else { return [] }

        let files = try modelContext.fetch(FetchDescriptor<FileRecord>())
        // Pre-bucket files by path prefix for O(folders + files) instead of O(folders × files).
        // Each folder's prefix is its absolute path with a trailing slash so descendant
        // matching respects path-component boundaries.
        struct FolderMatch {
            let folder: TrackedFolder
            let resolvedPath: String?   // nil if bookmark is stale
            let prefix: String          // always ends in "/" — synthetic if unresolvable
            let exactPath: String       // folder's own path, no trailing slash
            var fileCount: Int = 0
            var chunkCount: Int = 0
            var failedCount: Int = 0
        }
        var matches: [FolderMatch] = []
        matches.reserveCapacity(folders.count)
        for folder in folders {
            let resolvedPath = BookmarkStore.resolve(folder.bookmarkData)?.path
            // If unresolvable, fall back to a synthetic prefix that matches nothing so the
            // folder still appears in the list with zero counts.
            let path = resolvedPath ?? "\0/unresolvable/\(folder.id.uuidString)"
            let prefix = path.hasSuffix("/") ? path : path + "/"
            matches.append(FolderMatch(
                folder: folder, resolvedPath: resolvedPath,
                prefix: prefix, exactPath: path
            ))
        }

        for file in files {
            for i in 0..<matches.count {
                let m = matches[i]
                if file.pathString == m.exactPath || file.pathString.hasPrefix(m.prefix) {
                    matches[i].fileCount += 1
                    matches[i].chunkCount += file.chunks?.count ?? 0
                    if file.failedReason != nil { matches[i].failedCount += 1 }
                    break  // a file lives under exactly one tracked folder
                }
            }
        }

        return matches.map { m in
            FolderStats(
                id: m.folder.id,
                displayName: m.folder.displayName,
                dateAdded: m.folder.dateAdded,
                lastIndexedAt: m.folder.lastIndexedAt,
                resolvedPath: m.resolvedPath,
                fileCount: m.fileCount,
                chunkCount: m.chunkCount,
                failedCount: m.failedCount
            )
        }
    }

    // MARK: - Indexer write-side helpers

    struct ChunkSpec: Sendable {
        let ordinal: Int
        let text: String
        let charStart: Int
        let charEnd: Int
        let pageNumber: Int?
        let embedding: [Float]
    }

    /// Atomically replace a file's record and all its chunks. If a record exists at this path,
    /// its chunks are deleted and fields updated; otherwise a new record is inserted.
    func upsertFileAndChunks(
        pathString: String,
        kind: FileKind,
        size: Int,
        mtime: Date,
        chunks: [ChunkSpec]
    ) throws -> UUID {
        let descriptor = FetchDescriptor<FileRecord>(
            predicate: #Predicate { $0.pathString == pathString }
        )
        let existing = try modelContext.fetch(descriptor).first

        let record: FileRecord
        if let existing {
            if let oldChunks = existing.chunks {
                for c in oldChunks { modelContext.delete(c) }
            }
            existing.chunks = []
            existing.kindRaw = kind.rawValue
            existing.sizeBytes = size
            existing.modificationDate = mtime
            existing.indexedAt = .now
            existing.failedReason = nil
            record = existing
        } else {
            record = FileRecord(
                pathString: pathString,
                bookmarkData: Data(),  // empty: we resolve via parent TrackedFolder's bookmark
                kind: kind,
                sizeBytes: size,
                modificationDate: mtime
            )
            modelContext.insert(record)
        }

        var chunkModels: [Chunk] = []
        chunkModels.reserveCapacity(chunks.count)
        for spec in chunks {
            let c = Chunk(
                ordinal: spec.ordinal,
                text: spec.text,
                charStart: spec.charStart,
                charEnd: spec.charEnd,
                pageNumber: spec.pageNumber
            )
            c.embedding = spec.embedding
            c.file = record
            modelContext.insert(c)
            chunkModels.append(c)
        }
        record.chunks = chunkModels

        try modelContext.save()
        return record.id
    }

    func markFileFailed(
        pathString: String,
        kind: FileKind,
        size: Int,
        mtime: Date,
        reason: String
    ) throws {
        let descriptor = FetchDescriptor<FileRecord>(
            predicate: #Predicate { $0.pathString == pathString }
        )
        let existing = try modelContext.fetch(descriptor).first

        if let existing {
            if let oldChunks = existing.chunks {
                for c in oldChunks { modelContext.delete(c) }
            }
            existing.chunks = []
            existing.kindRaw = kind.rawValue
            existing.sizeBytes = size
            existing.modificationDate = mtime
            existing.indexedAt = .now
            existing.failedReason = reason
        } else {
            let record = FileRecord(
                pathString: pathString,
                bookmarkData: Data(),
                kind: kind,
                sizeBytes: size,
                modificationDate: mtime,
                failedReason: reason
            )
            modelContext.insert(record)
        }
        try modelContext.save()
    }

    /// Delete FileRecords whose paths were not seen in the latest crawl. Used to garbage-collect
    /// files that were deleted or moved out of a tracked folder.
    @discardableResult
    func pruneMissingFiles(existingPaths: Set<String>) throws -> Int {
        let descriptor = FetchDescriptor<FileRecord>()
        let all = try modelContext.fetch(descriptor)
        var deleted = 0
        for record in all where !existingPaths.contains(record.pathString) {
            modelContext.delete(record)
            deleted += 1
        }
        if deleted > 0 {
            try modelContext.save()
        }
        return deleted
    }

    func markFolderIndexed(id: UUID) throws {
        let descriptor = FetchDescriptor<TrackedFolder>(
            predicate: #Predicate { $0.id == id }
        )
        if let folder = try modelContext.fetch(descriptor).first {
            folder.lastIndexedAt = .now
            try modelContext.save()
        }
    }

    /// Sendable row for the in-memory VectorStore. Tuples don't auto-conform to Sendable in
    /// Swift 6, so we use a struct.
    struct ChunkEmbeddingRow: Sendable {
        let id: UUID
        let embedding: [Float]
        let fileID: UUID
        let text: String
        let pageNumber: Int?
        let charStart: Int
        let charEnd: Int
        let pathString: String
        let kindRaw: String
    }

    /// Returns every chunk's id + embedding for the in-memory VectorStore. Called once at
    /// startup and after each indexing batch.
    func allChunkEmbeddings() throws -> [ChunkEmbeddingRow] {
        let descriptor = FetchDescriptor<Chunk>()
        let chunks = try modelContext.fetch(descriptor)
        return chunks.compactMap { chunk in
            guard
                let emb = chunk.embedding,
                let file = chunk.file
            else { return nil }
            return ChunkEmbeddingRow(
                id: chunk.id,
                embedding: emb,
                fileID: file.id,
                text: chunk.text,
                pageNumber: chunk.pageNumber,
                charStart: chunk.charStart,
                charEnd: chunk.charEnd,
                pathString: file.pathString,
                kindRaw: file.kindRaw
            )
        }
    }
}
