import Foundation

/// Helpers for creating and resolving security-scoped bookmarks. On macOS, an app without
/// Full Disk Access can still read arbitrary user-selected directories if it stores a
/// security-scoped bookmark for each one. Bookmarks persist across launches.
enum BookmarkStore {
    /// Create a security-scoped bookmark for a directory URL.
    static func makeBookmark(for url: URL) throws -> Data {
        try url.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
    }

    /// Resolve a bookmark back to a URL. Returns nil if the bookmark is stale and cannot be
    /// refreshed, or if the underlying file no longer exists.
    static func resolve(_ data: Data) -> URL? {
        var stale = false
        guard let url = try? URL(
            resolvingBookmarkData: data,
            options: [.withSecurityScope],
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        ) else {
            return nil
        }
        // We don't auto-refresh stale bookmarks here — the caller can detect staleness via
        // FileManager.fileExists and re-prompt the user if needed.
        if stale { return nil }
        return url
    }
}
