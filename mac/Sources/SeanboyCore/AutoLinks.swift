import Foundation

/// Text in a note that matches another note's title: `range` opens `title`.
public struct AutoLink: Equatable, Sendable {
    public let range: NSRange
    public let title: String

    public init(range: NSRange, title: String) {
        self.range = range
        self.title = title
    }
}

/// Auto-links to existing notes (PRD editor v4, core feature 5; GNote's
/// `NoteLinkWatcher`): text that matches another note's title, as a whole
/// word and ignoring case, is shown as a link. Display-only: nothing is
/// written to the file.
///
/// The longest title wins where titles overlap, matches never overlap,
/// titles shorter than `minTitleLength` are ignored, the open note
/// (`current`) never links to itself, and nothing inside code, code blocks,
/// wiki links, links, or URLs is matched.
///
/// Build one per set of titles (compiling the pattern is the costly part)
/// and call `find` per restyle. Mirrored by the Kotlin `AutoLinks` in
/// `:core`; both run `shared/fixtures/auto-links.json`.
public final class AutoLinks: @unchecked Sendable {  // immutable after init; NSRegularExpression is thread-safe
    public static let minTitleLength = 3

    private let titleByKey: [String: String]
    private let regex: NSRegularExpression?

    public init(titles: some Sequence<String>, current: String? = nil) {
        var seen = Set<String>()
        var usable: [String] = []
        for title in titles {
            guard title.trimmingCharacters(in: .whitespaces).utf16.count >= Self.minTitleLength else { continue }
            if let current, title.caseInsensitiveCompare(current) == .orderedSame { continue }
            if seen.insert(title.lowercased()).inserted { usable.append(title) }
        }
        // Longest first: the alternation takes the first title that matches.
        usable.sort { $0.utf16.count > $1.utf16.count }
        titleByKey = Dictionary(usable.map { ($0.lowercased(), $0) }, uniquingKeysWith: { first, _ in first })
        if usable.isEmpty {
            regex = nil
        } else {
            let word = #"\p{L}\p{M}\p{Nd}\p{Pc}"#
            let alternatives = usable.map(NSRegularExpression.escapedPattern(for:)).joined(separator: "|")
            regex = try? NSRegularExpression(
                pattern: "(?<![\(word)])(?:\(alternatives))(?![\(word)])", options: [.caseInsensitive])
        }
    }

    /// Auto-links in the lines of `text` covered by `range` (the whole text
    /// when nil), given that text's `spans` (from `MarkdownSpans.parse`, at
    /// least over `range`).
    public func find(in text: String, spans: [MarkdownSpan], range: NSRange? = nil) -> [AutoLink] {
        guard let regex else { return [] }
        let ns = text as NSString
        let range = range ?? NSRange(location: 0, length: ns.length)
        guard range.length > 0 else { return [] }

        // Mask what can't hold an auto-link, so matches can't start, end, or run through it.
        var chars = Array(repeating: unichar(0), count: range.length)
        ns.getCharacters(&chars, range: range)
        for span in spans where Self.excludedKinds.contains(span.kind) {
            let from = max(span.range.location, range.location) - range.location
            let to = min(NSMaxRange(span.range), NSMaxRange(range)) - range.location
            if from < to { for i in from..<to { chars[i] = Self.mask } }
        }
        let masked = String(utf16CodeUnits: chars, count: chars.count)

        return regex.matches(in: masked, range: NSRange(location: 0, length: chars.count)).map { match in
            let location = NSRange(location: range.location + match.range.location, length: match.range.length)
            let matched = ns.substring(with: location)
            return AutoLink(range: location, title: titleByKey[matched.lowercased()] ?? canonical(matched))
        }
    }

    /// The title a match stands for, when lowercasing isn't enough to find it (rare Unicode cases).
    private func canonical(_ matched: String) -> String {
        titleByKey.values.first { $0.caseInsensitiveCompare(matched) == .orderedSame } ?? matched
    }

    private static let mask: unichar = 0x01

    private static let excludedKinds: Set<MarkdownSpan.Kind> = [.code, .codeBlock, .wikiLink, .link, .url]
}
