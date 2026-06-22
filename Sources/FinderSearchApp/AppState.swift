import Foundation
import Observation
import AppKit

/// Single observable container the SwiftUI layer talks to. Owns the Store and Indexer
/// actors and mirrors the bits of their state the UI cares about (folder list, counts,
/// indexing progress).
@MainActor
@Observable
final class AppState {
    let store: Store
    let indexer: Indexer
    let progress: IndexingProgress
    let vectorStore: VectorStore
    let queryEngine: QueryEngine

    var folders: [Store.TrackedFolderInfo] = []
    var folderStats: [Store.FolderStats] = []
    var fileCount: Int = 0
    var chunkCount: Int = 0
    var searchQuery: String = ""
    var results: [SearchResult] = []
    var isSearching: Bool = false

    enum AnswerState: Sendable {
        case idle
        case thinking
        case complete(QAResult)
        case error(String)
        case unavailable(String)
    }

    var answerState: AnswerState = .idle
    var llmChecked: Bool = false
    var llmAvailable: Bool = false
    var llmUnavailableReason: String = ""

    @ObservationIgnored
    private var debounceTask: Task<Void, Never>?

    @ObservationIgnored
    private var watcher: FileSystemWatcher?

    init(store: Store) {
        self.store = store
        let progress = IndexingProgress()
        self.progress = progress
        self.indexer = Indexer(store: store, progress: progress)
        let vectorStore = VectorStore(store: store)
        self.vectorStore = vectorStore
        self.queryEngine = QueryEngine(store: store, vectorStore: vectorStore)
    }

    func refresh() async {
        folders = (try? await store.trackedFolders()) ?? []
        folderStats = (try? await store.folderStats()) ?? []
        let c = (try? await store.counts()) ?? (files: 0, chunks: 0)
        fileCount = c.files
        chunkCount = c.chunks
    }

    /// Initial load on app startup: refresh counts and warm the in-memory vector index.
    func bootstrap() async {
        await refresh()
        await vectorStore.reload()
        await checkLLM()
        restartWatcher()
    }

    /// Re-create the FSEvents stream with the current set of tracked folders. Cheap to
    /// call after add/remove folder operations.
    private func restartWatcher() {
        let urls = folders.compactMap { BookmarkStore.resolve($0.bookmarkData) }
        if urls.isEmpty {
            watcher?.stop()
            watcher = nil
            return
        }
        if watcher == nil {
            watcher = FileSystemWatcher { [weak self] in
                guard let self else { return }
                Task { await self.handleFilesystemChange() }
            }
        }
        watcher?.start(roots: urls)
    }

    private func handleFilesystemChange() async {
        // Don't kick off a second index pass while one is already running.
        if progress.isIndexing { return }
        await indexer.indexAll()
        await vectorStore.reload()
        await refresh()
        if !searchQuery.isEmpty {
            await runSearch()
        }
    }

    func checkLLM() async {
        let status = await queryEngine.llmStatus()
        switch status {
        case .available:
            llmAvailable = true
            llmUnavailableReason = ""
        case .unavailable(let reason):
            llmAvailable = false
            llmUnavailableReason = reason
        }
        llmChecked = true
    }

    func addFolder() async {
        guard let url = pickFolderViaOpenPanel() else { return }
        do {
            let bookmark = try BookmarkStore.makeBookmark(for: url)
            _ = try await store.addTrackedFolder(
                bookmarkData: bookmark,
                displayName: url.lastPathComponent
            )
            await refresh()
            restartWatcher()
            await indexer.indexAll()
            await vectorStore.reload()
            await refresh()
        } catch {
            print("[AppState] addFolder failed: \(error)")
        }
    }

    func removeFolder(id: UUID) async {
        try? await store.deleteTrackedFolder(id: id)
        await refresh()
        restartWatcher()
    }

    func reindex() async {
        await indexer.indexAll()
        await vectorStore.reload()
        await refresh()
        // Re-run the current search against the fresh index.
        if !searchQuery.isEmpty {
            await runSearch()
        }
    }

    /// Debounced search — call from `.onChange(of: searchQuery)`. Cancels any in-flight
    /// search so typing fast doesn't queue up work.
    func scheduleSearch() {
        debounceTask?.cancel()
        // Query changed — any prior answer is now stale.
        if case .complete = answerState { answerState = .idle }
        if case .error = answerState { answerState = .idle }
        if searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            results = []
            isSearching = false
            return
        }
        debounceTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(200))
            guard let self, !Task.isCancelled else { return }
            await self.runSearch()
        }
    }

    func runSearch() async {
        let q = searchQuery
        guard !q.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            results = []
            isSearching = false
            return
        }
        isSearching = true
        let r = await queryEngine.search(q)
        if !Task.isCancelled {
            results = r
        }
        isSearching = false
    }

    /// Trigger the LLM Q&A pipeline. Called when the user submits the query (Enter) or
    /// clicks "Ask". Resets on query change.
    func ask() async {
        let q = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else {
            answerState = .idle
            return
        }
        if !llmAvailable {
            answerState = .unavailable(llmUnavailableReason)
            return
        }
        answerState = .thinking
        do {
            let result = try await queryEngine.ask(q)
            answerState = .complete(result)
        } catch {
            answerState = .error(error.localizedDescription)
        }
    }

    private func pickFolderViaOpenPanel() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Index"
        panel.message = "Choose a folder to index for FinderSearch"
        return panel.runModal() == .OK ? panel.url : nil
    }
}

