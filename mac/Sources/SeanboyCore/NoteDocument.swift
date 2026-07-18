import Foundation

/// Serializes notes to/from Markdown files with a YAML-style frontmatter
/// block. Seanboy manages only its own keys and preserves everything else
/// (Obsidian tags, aliases, custom fields) verbatim:
///
///     ---
///     id: 8F6B...            ← managed (or `seanboy-id` if `id` is foreign)
///     created: 2026-07-17T12:00:00Z
///     modified: 2026-07-17T12:34:56Z
///     tags:                  ← unmanaged, preserved byte-for-byte
///       - journal
///     ---
///
///     Markdown body...
///
/// The title is NOT stored — the filename owns it.
public enum NoteDocument {
    static let delimiter = "---"

    /// Managed keys, recognized only at zero indentation.
    private static let managedKeys: Set<String> = ["id", "seanboy-id", "created", "modified", "deleted"]

    private static let dateFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    static func parseDate(_ string: String) -> Date? {
        if let date = dateFormatter.date(from: string) { return date }
        // Tolerate timestamps written without fractional seconds.
        let plain = ISO8601DateFormatter()
        return plain.date(from: string)
    }

    static func formatDate(_ date: Date) -> String {
        dateFormatter.string(from: date)
    }

    // MARK: - Parsing

    /// Everything a file can tell us. Total — any text parses; a file with
    /// no frontmatter is all body with a nil `id` (needs adoption).
    public struct Parsed: Equatable, Sendable {
        public var id: UUID?
        public var created: Date?
        public var modified: Date?
        public var deleted: Bool = false
        /// Legacy `title:` value from the pre-v3 format (used by migration);
        /// never written back.
        public var legacyTitle: String?
        /// Unmanaged frontmatter lines, verbatim and in order.
        public var extraFrontmatter: [String] = []
        public var body: String = ""

        public init() {}
    }

    public static func parse(_ text: String) -> Parsed {
        var parsed = Parsed()
        let lines = text.components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespaces) == delimiter,
              let closing = lines.dropFirst().firstIndex(where: {
                  $0.trimmingCharacters(in: .whitespaces) == delimiter
              }) else {
            parsed.body = text
            return parsed
        }

        for line in lines[1..<closing] {
            // Managed keys sit at zero indentation; anything else (indented
            // YAML continuations, lists, unknown keys) is preserved verbatim.
            guard !line.hasPrefix(" "), !line.hasPrefix("\t"),
                  let colon = line.firstIndex(of: ":") else {
                parsed.extraFrontmatter.append(line)
                continue
            }
            let key = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)

            switch key {
            case "seanboy-id":
                parsed.id = UUID(uuidString: value) ?? parsed.id
            case "id":
                if parsed.id == nil, let uuid = UUID(uuidString: value) {
                    parsed.id = uuid
                } else {
                    // Foreign id (non-UUID, or ours already found) — theirs, keep it.
                    parsed.extraFrontmatter.append(line)
                }
            case "created":
                parsed.created = parseDate(value)
                if parsed.created == nil { parsed.extraFrontmatter.append(line) }
            case "modified":
                parsed.modified = parseDate(value)
                if parsed.modified == nil { parsed.extraFrontmatter.append(line) }
            case "deleted":
                parsed.deleted = value == "true"
            case "title":
                parsed.legacyTitle = value
            default:
                parsed.extraFrontmatter.append(line)
            }
        }

        var bodyLines = Array(lines[(closing + 1)...])
        if bodyLines.first?.isEmpty == true { bodyLines.removeFirst() }
        parsed.body = bodyLines.joined(separator: "\n")
        return parsed
    }

    /// Builds a `Note` from file text. `nil` when the file has no adoptable
    /// identity AND `fallbackID` is nil — callers adopting foreign files pass
    /// a fresh UUID. Timestamps fall back to the file's fs dates.
    public static func note(from text: String, relativePath: String,
                            fallbackID: UUID? = nil,
                            fsCreated: Date? = nil, fsModified: Date? = nil) -> Note? {
        let parsed = parse(text)
        guard let id = parsed.id ?? fallbackID else { return nil }
        let modified = parsed.modified ?? fsModified ?? Date()
        return Note(
            id: id,
            relativePath: relativePath,
            body: parsed.body,
            createdAt: parsed.created ?? fsCreated ?? modified,
            modifiedAt: modified,
            isDeleted: parsed.deleted,
            extraFrontmatter: parsed.extraFrontmatter)
    }

    // MARK: - Serialization

    public static func serialize(_ note: Note) -> String {
        var lines = [delimiter]
        // If the note carries a foreign `id:` line among its extras, write
        // ours as `seanboy-id` so the file never has a duplicate key.
        let hasForeignID = note.extraFrontmatter.contains {
            !$0.hasPrefix(" ") && !$0.hasPrefix("\t")
                && $0.split(separator: ":").first?.trimmingCharacters(in: .whitespaces) == "id"
        }
        lines.append("\(hasForeignID ? "seanboy-id" : "id"): \(note.id.uuidString)")
        lines.append("created: \(formatDate(note.createdAt))")
        lines.append("modified: \(formatDate(note.modifiedAt))")
        if note.isDeleted {
            lines.append("deleted: true")
        }
        lines.append(contentsOf: note.extraFrontmatter)
        lines.append(delimiter)
        lines.append("")
        lines.append(note.body)
        return lines.joined(separator: "\n")
    }
}

private extension Substring {
    func trimmingCharacters(in set: CharacterSet) -> String {
        String(self).trimmingCharacters(in: set)
    }
}
