import Foundation

/// A `[[Note Title]]` occurrence inside a note body.
public struct WikiLink: Equatable, Sendable {
    /// The linked note's title, trimmed.
    public let title: String
    /// Range of the whole `[[...]]` token in the source string.
    public let range: Range<String.Index>

    public init(title: String, range: Range<String.Index>) {
        self.title = title
        self.range = range
    }
}

public enum WikiLinkParser {
    // [[ anything that isn't ]] or a newline ]]
    nonisolated(unsafe) private static let regex =
        try! NSRegularExpression(pattern: #"\[\[([^\[\]\n]+)\]\]"#)

    /// All wiki links in `text`, in document order.
    public static func links(in text: String) -> [WikiLink] {
        let ns = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        return matches.compactMap { match in
            guard let whole = Range(match.range, in: text),
                  let inner = Range(match.range(at: 1), in: text) else { return nil }
            let title = String(text[inner]).trimmingCharacters(in: .whitespaces)
            guard !title.isEmpty else { return nil }
            return WikiLink(title: title, range: whole)
        }
    }

    /// Distinct linked titles (case-insensitively deduped, original casing kept).
    public static func linkedTitles(in text: String) -> [String] {
        var seen = Set<String>()
        var titles: [String] = []
        for link in links(in: text) where seen.insert(link.title.lowercased()).inserted {
            titles.append(link.title)
        }
        return titles
    }

    /// Notes among `notes` whose bodies link to `title` (the backlinks pane).
    public static func backlinks(to title: String, in notes: [Note]) -> [Note] {
        let needle = title.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return [] }
        return notes.filter { note in
            !note.isDeleted &&
            linkedTitles(in: note.body).contains { $0.lowercased() == needle }
        }
    }
}
