import Foundation

/// Simple in-memory full-text search: every whitespace-separated query term
/// must appear in the title or body (case-insensitive). Title hits and
/// prefix matches rank higher; ties fall back to recency.
public enum SearchService {
    public static func search(_ query: String, in notes: [Note]) -> [Note] {
        let terms = query.lowercased()
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
        guard !terms.isEmpty else {
            return notes.sorted { $0.modifiedAt > $1.modifiedAt }
        }

        return notes
            .compactMap { note -> (Note, Int)? in
                guard let score = score(note, terms: terms) else { return nil }
                return (note, score)
            }
            .sorted {
                $0.1 != $1.1 ? $0.1 > $1.1 : $0.0.modifiedAt > $1.0.modifiedAt
            }
            .map(\.0)
    }

    private static func score(_ note: Note, terms: [String]) -> Int? {
        let title = note.title.lowercased()
        let body = note.body.lowercased()
        var total = 0
        for term in terms {
            if title.hasPrefix(term) {
                total += 100
            } else if title.contains(term) {
                total += 50
            } else if body.contains(term) {
                total += 10
            } else {
                return nil  // every term must match somewhere
            }
        }
        return total
    }
}
