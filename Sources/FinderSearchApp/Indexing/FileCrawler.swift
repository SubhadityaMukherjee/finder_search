import Foundation

/// Walks a directory tree and yields URLs of files whose extension is in our supported set.
/// Skips common noise directories (build artifacts, VCS metadata, caches) and hidden files.
struct FileCrawler {
    /// Directory names we never descend into. Matched case-insensitively against the last
    /// path component.
    static let excludedDirectoryNames: Set<String> = [
        ".git", ".svn", ".hg",
        "node_modules", "bower_components", "__pycache__", ".venv", "venv",
        ".build", "build", "DerivedData", ".swiftpm",
        "Library/Caches", ".Trash",
        ".cache", ".npm", ".cargo", ".rustup", ".gradle",
    ]

    /// Crawl results for a single file, in the order encountered. `AsyncStream` lets the
    /// caller process files as they're found instead of waiting for the full walk.
    struct Result: Sendable {
        let url: URL
        let kind: FileKind
        let modificationDate: Date
        let sizeBytes: Int
    }

    func crawl(root: URL) -> AsyncStream<Result> {
        AsyncStream { continuation in
            Task.detached(priority: .utility) {
                let manager = FileManager.default
                let excluded = Self.excludedDirectoryNames

                let enumerator = manager.enumerator(
                    at: root,
                    includingPropertiesForKeys: [
                        .isRegularFileKey,
                        .contentModificationDateKey,
                        .fileSizeKey,
                    ],
                    options: [.skipsHiddenFiles, .skipsPackageDescendants]
                ) { url, _ in
                    // Reject noisy directories before descending.
                    let name = url.lastPathComponent
                    if excluded.contains(name) { return false }
                    return true
                }

                guard let enumerator else {
                    continuation.finish()
                    return
                }

                while let url = enumerator.nextObject() as? URL {
                    guard let kind = FileKind.from(pathExtension: url.pathExtension) else {
                        continue
                    }
                    let values = try? url.resourceValues(forKeys: [
                        .isRegularFileKey,
                        .contentModificationDateKey,
                        .fileSizeKey,
                    ])
                    guard values?.isRegularFile == true else { continue }

                    let mtime = values?.contentModificationDate ?? Date()
                    let size = values?.fileSize ?? 0

                    // Skip 0-byte files; they have nothing to index.
                    if size == 0 { continue }

                    continuation.yield(Result(
                        url: url,
                        kind: kind,
                        modificationDate: mtime,
                        sizeBytes: size
                    ))
                }
                continuation.finish()
            }
        }
    }
}
