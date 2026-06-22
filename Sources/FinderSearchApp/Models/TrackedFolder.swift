import Foundation
import SwiftData

/// A folder the user has explicitly added to the index. Stored as a security-scoped bookmark
/// so the path can be re-resolved across launches even if the folder is moved.
@Model
final class TrackedFolder {
    @Attribute(.unique) var id: UUID
    var bookmarkData: Data
    /// Last path component used at the time the bookmark was created — purely for display.
    var displayName: String
    var dateAdded: Date
    var lastIndexedAt: Date?

    init(
        id: UUID = UUID(),
        bookmarkData: Data,
        displayName: String,
        dateAdded: Date = .now,
        lastIndexedAt: Date? = nil
    ) {
        self.id = id
        self.bookmarkData = bookmarkData
        self.displayName = displayName
        self.dateAdded = dateAdded
        self.lastIndexedAt = lastIndexedAt
    }
}
