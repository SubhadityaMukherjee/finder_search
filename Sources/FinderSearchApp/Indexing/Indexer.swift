import Foundation

/// Orchestrates the indexing pipeline: for each tracked folder, resolve the bookmark,
/// crawl, dedupe against the snapshot, extract → chunk → embed → store, and finally prune
/// records for files that have vanished.
actor Indexer {
    let store: Store
    let progress: IndexingProgress
    private let crawler = FileCrawler()
    private let chunker = Chunker()
    private let embedder: EmbeddingService

    init(store: Store, progress: IndexingProgress, embedder: EmbeddingService = .shared) {
        self.store = store
        self.progress = progress
        self.embedder = embedder
    }

    func indexAll() async {
        guard !progress.isIndexing else { return }
        progress.isIndexing = true
        progress.processedFiles = 0
        progress.skippedUnchanged = 0
        progress.totalChunksIndexed = 0
        progress.failed = 0
        progress.lastError = nil

        defer {
            progress.isIndexing = false
            progress.currentFolder = ""
            progress.lastFinishedAt = .now
        }

        let folders: [Store.TrackedFolderInfo]
        do {
            folders = try await store.trackedFolders()
        } catch {
            progress.lastError = "Failed to load tracked folders: \(error.localizedDescription)"
            return
        }

        if folders.isEmpty {
            progress.lastError = "No folders tracked yet. Add one in Settings."
            return
        }

        var allSeenPaths = Set<String>()
        for folder in folders {
            let seen = await index(folder: folder)
            allSeenPaths.formUnion(seen)
        }

        if let pruned = try? await store.pruneMissingFiles(existingPaths: allSeenPaths), pruned > 0 {
            print("[Indexer] pruned \(pruned) missing files")
        }
    }

    private func index(folder: Store.TrackedFolderInfo) async -> Set<String> {
        guard let url = resolveBookmark(folder.bookmarkData) else {
            progress.lastError = "Failed to resolve bookmark for \(folder.displayName)"
            return []
        }
        let didStartAccess = url.startAccessingSecurityScopedResource()
        defer {
            if didStartAccess { url.stopAccessingSecurityScopedResource() }
        }
        progress.currentFolder = folder.displayName

        let snapshot: [String: (mtime: Date, size: Int, id: UUID)]
        do {
            snapshot = try await store.indexedFileSnapshot()
        } catch {
            progress.lastError = "Snapshot load failed: \(error.localizedDescription)"
            return []
        }

        var seenPaths = Set<String>()

        for await result in crawler.crawl(root: url) {
            seenPaths.insert(result.url.path)

            if let existing = snapshot[result.url.path],
               existing.mtime == result.modificationDate,
               existing.size == result.sizeBytes
            {
                progress.skippedUnchanged += 1
                continue
            }

            await processFile(
                url: result.url,
                kind: result.kind,
                mtime: result.modificationDate,
                size: result.sizeBytes
            )
            progress.processedFiles += 1
        }

        do {
            try await store.markFolderIndexed(id: folder.id)
        } catch {
            progress.lastError = "Folder mark failed: \(error.localizedDescription)"
        }
        return seenPaths
    }

    private func processFile(url: URL, kind: FileKind, mtime: Date, size: Int) async {
        // Hard cap: skip files larger than 50MB. They're usually PDFs of scanned books,
        // mail archives, or other content that's both slow to extract and likely to OOM
        // PDFKit or the embedding pipeline. Mark as failed so the user can see why.
        if size > Self.maxFileBytes {
            try? await store.markFileFailed(
                pathString: url.path, kind: kind, size: size, mtime: mtime,
                reason: "Skipped: file too large (\(size / 1_000_000)MB > \(Self.maxFileBytes / 1_000_000)MB limit)"
            )
            progress.failed += 1
            return
        }

        // Per-file log line so crash logs (and Console.app) tell us exactly which file
        // was being processed when something went wrong.
        print("[Indexer] processing \(kind.rawValue): \(url.path)")

        let extraction: TextExtractors.Extraction
        do {
            extraction = try TextExtractors.extract(from: url, kind: kind)
        } catch {
            try? await store.markFileFailed(
                pathString: url.path, kind: kind, size: size, mtime: mtime,
                reason: "Extraction error: \(error.localizedDescription)"
            )
            progress.failed += 1
            return
        }

        guard !extraction.text.isEmpty else {
            try? await store.markFileFailed(
                pathString: url.path, kind: kind, size: size, mtime: mtime,
                reason: "No extractable text"
            )
            progress.failed += 1
            return
        }

        // Sanity-cap extracted text before chunking/embedding. A pathological HTML or
        // PDF that decodes to 10MB of text would otherwise exhaust memory.
        let truncatedText: String
        if extraction.text.count > Self.maxExtractedChars {
            truncatedText = String(extraction.text.prefix(Self.maxExtractedChars))
            print("[Indexer] truncated text for \(url.lastPathComponent) (\(extraction.text.count) → \(Self.maxExtractedChars) chars)")
        } else {
            truncatedText = extraction.text
        }

        let slices = chunker.chunk(truncatedText, pageBoundaries: extraction.pageBoundaries)
        guard !slices.isEmpty else {
            try? await store.markFileFailed(
                pathString: url.path, kind: kind, size: size, mtime: mtime,
                reason: "Chunker produced no slices"
            )
            progress.failed += 1
            return
        }
        guard slices.count <= Self.maxChunksPerFile else {
            try? await store.markFileFailed(
                pathString: url.path, kind: kind, size: size, mtime: mtime,
                reason: "Too many chunks (\(slices.count) > \(Self.maxChunksPerFile) limit)"
            )
            progress.failed += 1
            return
        }

        let texts = slices.map(\.text)
        let embeddings = await embedder.embedBatch(texts)

        let specs: [Store.ChunkSpec] = slices.enumerated().map { idx, slice in
            Store.ChunkSpec(
                ordinal: idx,
                text: slice.text,
                charStart: slice.charStart,
                charEnd: slice.charEnd,
                pageNumber: slice.pageNumber,
                embedding: embeddings[idx] ?? []
            )
        }

        do {
            _ = try await store.upsertFileAndChunks(
                pathString: url.path,
                kind: kind,
                size: size,
                mtime: mtime,
                chunks: specs
            )
            progress.totalChunksIndexed += specs.count
        } catch {
            progress.lastError = "Store error: \(error.localizedDescription)"
            progress.failed += 1
        }
    }

    private static let maxFileBytes: Int = 50 * 1_024 * 1_024           // 50 MB
    private static let maxExtractedChars: Int = 1_000_000               // 1M chars ≈ 250-page book
    private static let maxChunksPerFile: Int = 5_000

    private func resolveBookmark(_ data: Data) -> URL? {
        var stale = false
        return try? URL(
            resolvingBookmarkData: data,
            options: [.withSecurityScope],
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        )
    }
}
