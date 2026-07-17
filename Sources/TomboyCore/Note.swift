import Foundation

/// A single note. Notes live on disk as Markdown files with a small
/// frontmatter header; `body` is the Markdown content below the header.
public struct Note: Identifiable, Equatable, Hashable, Sendable {
    public var id: UUID
    public var title: String
    public var body: String
    public var createdAt: Date
    public var modifiedAt: Date
    /// Tombstone flag: deleted notes keep their file so deletion can sync
    /// to other machines; the UI never shows them.
    public var isDeleted: Bool

    public init(
        id: UUID = UUID(),
        title: String,
        body: String = "",
        createdAt: Date = Date(),
        modifiedAt: Date = Date(),
        isDeleted: Bool = false
    ) {
        self.id = id
        self.title = title
        self.body = body
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
        self.isDeleted = isDeleted
    }
}
