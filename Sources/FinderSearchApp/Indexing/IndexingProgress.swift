import Foundation
import Observation

/// Observable view-model that reflects the Indexer's state into SwiftUI. The Indexer (actor)
/// writes to this; the UI reads it. Lives outside the actor so SwiftUI can `@Observation` it.
///
/// Marked `@unchecked Sendable` so the AppState (MainActor) can pass it to the Indexer
/// (actor). This is safe: `@Observable`'s property notifications are atomic, and the only
/// mutations come from the Indexer (single-writer) while reads happen on MainActor.
@Observable
final class IndexingProgress: @unchecked Sendable {
    var isIndexing: Bool = false
    var currentFolder: String = ""
    var processedFiles: Int = 0
    var totalFilesKnown: Int = 0  // 0 = unknown (we discover files as we crawl)
    var totalChunksIndexed: Int = 0
    var skippedUnchanged: Int = 0
    var failed: Int = 0
    var lastError: String?
    var lastFinishedAt: Date?

    func reset() {
        isIndexing = false
        currentFolder = ""
        processedFiles = 0
        totalFilesKnown = 0
        totalChunksIndexed = 0
        skippedUnchanged = 0
        failed = 0
        lastError = nil
    }
}
