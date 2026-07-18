import Foundation

/// A single note. Notes are plain Markdown files in the user's notes folder;
/// the filename (minus `.md`) IS the title, and the path relative to the
/// folder root IS the note's location — locally and in the sync bucket.
public struct Note: Identifiable, Equatable, Hashable, Sendable {
    public var id: UUID
    /// Path relative to the notes folder, e.g. `Journal/2026/July.md`.
    public var relativePath: String
    public var body: String
    public var createdAt: Date
    public var modifiedAt: Date
    /// Deleted notes exist only in memory (from tombstone records or remote
    /// tombstone objects) — never as files in the user's folder.
    public var isDeleted: Bool
    /// Frontmatter lines Seanboy doesn't manage (Obsidian tags, aliases, …),
    /// preserved verbatim through every save and through sync.
    public var extraFrontmatter: [String]

    public init(
        id: UUID = UUID(),
        relativePath: String,
        body: String = "",
        createdAt: Date = Date(),
        modifiedAt: Date = Date(),
        isDeleted: Bool = false,
        extraFrontmatter: [String] = []
    ) {
        self.id = id
        self.relativePath = relativePath
        self.body = body
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
        self.isDeleted = isDeleted
        self.extraFrontmatter = extraFrontmatter
    }

    /// Convenience for creating a note from a title, at the folder root or
    /// inside `folder`.
    public init(
        id: UUID = UUID(),
        title: String,
        folder: String = "",
        body: String = "",
        createdAt: Date = Date(),
        modifiedAt: Date = Date(),
        isDeleted: Bool = false
    ) {
        let filename = NoteNaming.filename(forTitle: title)
        let path = folder.isEmpty ? filename : folder + "/" + filename
        self.init(id: id, relativePath: path, body: body,
                  createdAt: createdAt, modifiedAt: modifiedAt, isDeleted: isDeleted)
    }

    /// The filename minus `.md` — renaming the title moves the file.
    public var title: String {
        get {
            let name = (relativePath as NSString).lastPathComponent
            return name.hasSuffix(".md") ? String(name.dropLast(3)) : name
        }
        set {
            let filename = NoteNaming.filename(forTitle: newValue)
            relativePath = folder.isEmpty ? filename : folder + "/" + filename
        }
    }

    /// Containing folder relative to the notes root; "" at the root.
    public var folder: String {
        let dir = (relativePath as NSString).deletingLastPathComponent
        return dir == "." ? "" : dir
    }
}

/// Title ↔ filename rules shared by the store, sync, and UI.
public enum NoteNaming {
    /// A title turned into a safe filename component (no extension).
    public static func sanitize(_ title: String) -> String {
        var name = title
            .components(separatedBy: .controlCharacters).joined(separator: " ")
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespaces)
        while name.hasPrefix(".") { name.removeFirst() }
        if name.count > 120 { name = String(name.prefix(120)) }
        return name.isEmpty ? "Untitled" : name
    }

    public static func filename(forTitle title: String) -> String {
        sanitize(title) + ".md"
    }
}
