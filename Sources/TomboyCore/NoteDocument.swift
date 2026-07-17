import Foundation

/// Serializes a `Note` to/from its on-disk Markdown representation:
///
///     ---
///     id: 8F6B...-....
///     title: Shopping List
///     created: 2026-07-17T12:00:00Z
///     modified: 2026-07-17T12:34:56Z
///     deleted: false
///     ---
///
///     Markdown body...
public enum NoteDocument {
    static let delimiter = "---"

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

    public static func serialize(_ note: Note) -> String {
        var lines = [delimiter]
        lines.append("id: \(note.id.uuidString)")
        lines.append("title: \(note.title.replacingOccurrences(of: "\n", with: " "))")
        lines.append("created: \(formatDate(note.createdAt))")
        lines.append("modified: \(formatDate(note.modifiedAt))")
        lines.append("deleted: \(note.isDeleted)")
        lines.append(delimiter)
        lines.append("")
        lines.append(note.body)
        return lines.joined(separator: "\n")
    }

    public static func deserialize(_ text: String) -> Note? {
        let lines = text.components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespaces) == delimiter else { return nil }
        guard let closing = lines.dropFirst().firstIndex(where: {
            $0.trimmingCharacters(in: .whitespaces) == delimiter
        }) else { return nil }

        var fields: [String: String] = [:]
        for line in lines[1..<closing] {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            fields[key] = value
        }

        guard let idString = fields["id"], let id = UUID(uuidString: idString) else { return nil }
        let title = fields["title"] ?? "Untitled"
        let created = fields["created"].flatMap(parseDate) ?? Date()
        let modified = fields["modified"].flatMap(parseDate) ?? created
        let deleted = fields["deleted"] == "true"

        // Body starts after the closing delimiter, skipping one blank spacer line.
        var bodyLines = Array(lines[(closing + 1)...])
        if bodyLines.first?.isEmpty == true { bodyLines.removeFirst() }
        let body = bodyLines.joined(separator: "\n")

        return Note(id: id, title: title, body: body,
                    createdAt: created, modifiedAt: modified, isDeleted: deleted)
    }
}
