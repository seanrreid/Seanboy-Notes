import Foundation

/// One piece of Markdown syntax found in a note body, for Live Preview
/// rendering. Ranges are UTF-16 offsets into the body (`NSString` indexing —
/// the same units Kotlin/Java strings use, so both ports agree).
///
/// - `range`: everything the syntax covers, markers included.
/// - `content`: the part that stays visible when the line is rendered.
/// - `markers`: the parts that are hidden when rendered and shown faded on
///   the cursor line (`**`, `# `, `[[`, `- `, fence lines, …).
public struct MarkdownSpan: Equatable, Sendable {
    public enum Kind: String, Sendable, CaseIterable {
        // Line-level
        case heading, quote, rule, bullet, orderedItem, task, codeBlock
        // Inline
        case bold, italic, strikethrough, highlight, code, wikiLink, link, url
    }

    public let kind: Kind
    public let range: NSRange
    public let content: NSRange
    public let markers: [NSRange]
    /// Heading level (1–6), or leading indent in columns for list items
    /// (a tab counts as 4).
    public var level: Int = 0
    /// `- [x]` tasks.
    public var checked: Bool = false
    /// Wiki-link title, link URL, or bare URL.
    public var target: String?

    public init(kind: Kind, range: NSRange, content: NSRange, markers: [NSRange],
                level: Int = 0, checked: Bool = false, target: String? = nil) {
        self.kind = kind
        self.range = range
        self.content = content
        self.markers = markers
        self.level = level
        self.checked = checked
        self.target = target
    }
}

/// Line-oriented Markdown scanner for Live Preview. It never changes text —
/// it only reports where syntax is. Supports the subset in
/// `docs/PRD-editor-v4.md`; everything else is plain text. Mirrored by the
/// Kotlin `MarkdownSpans` in `:core`; both run `shared/fixtures/markdown-spans.json`.
public enum MarkdownSpans {

    public static func parse(_ text: String) -> [MarkdownSpan] {
        parse(text, linesTouching: NSRange(location: 0, length: (text as NSString).length)).spans
    }

    /// Incremental parse for the editor: the spans of every line touching
    /// `range`, widened so a code block is always parsed whole. `covered` is
    /// the exact range those spans describe — restyle that, nothing more.
    ///
    /// Only a cheap fence scan runs before `range`, so the cost is
    /// proportional to the edited lines, not the note.
    public static func parse(_ text: String, linesTouching range: NSRange)
        -> (spans: [MarkdownSpan], covered: NSRange)
    {
        let ns = text as NSString
        let clamped = NSRange(location: min(range.location, ns.length),
                              length: min(range.length, ns.length - min(range.location, ns.length)))
        let lines = ns.lineRange(for: clamped)

        // If the edit is inside a code block, start at its opening fence.
        var start = lines.location
        if let fenceStart = openFenceStart(in: ns, before: lines.location) {
            start = fenceStart
        }

        var spans: [MarkdownSpan] = []
        var openFence: (line: NSRange, marker: String, bodyStart: Int)?
        var previousLineEnd = start
        var coveredEnd = ns.length

        ns.enumerateSubstrings(
            in: NSRange(location: start, length: ns.length - start),
            options: [.byLines, .substringNotRequired]
        ) { _, line, enclosing, stop in
            if line.location >= NSMaxRange(lines), line.location > clamped.location, openFence == nil {
                coveredEnd = enclosing.location
                stop.pointee = true
                return
            }
            defer { previousLineEnd = NSMaxRange(line) }
            let lineText = ns.substring(with: line)

            // Code fences: everything between is one opaque block.
            if let fence = openFence {
                if isFence(lineText, closing: fence.marker) {
                    spans.append(MarkdownSpan(
                        kind: .codeBlock,
                        range: NSRange(location: fence.line.location,
                                       length: NSMaxRange(line) - fence.line.location),
                        content: NSRange(location: fence.bodyStart,
                                         length: max(0, previousLineEnd - fence.bodyStart)),
                        markers: [fence.line, line]))
                    openFence = nil
                }
                return
            }
            if let marker = openingFence(lineText) {
                openFence = (line, marker, NSMaxRange(enclosing))
                return
            }

            let inlineRange = lineSpans(lineText, at: line, into: &spans)
            inlineSpans(in: ns, range: inlineRange, into: &spans)
        }

        // An unclosed fence runs to the end of the note.
        if let fence = openFence {
            let bodyStart = min(fence.bodyStart, ns.length)
            spans.append(MarkdownSpan(
                kind: .codeBlock,
                range: NSRange(location: fence.line.location, length: ns.length - fence.line.location),
                content: NSRange(location: bodyStart, length: ns.length - bodyStart),
                markers: [fence.line]))
        }

        spans.sort {
            $0.range.location != $1.range.location
                ? $0.range.location < $1.range.location
                : $0.range.length > $1.range.length
        }
        return (spans, NSRange(location: start, length: coveredEnd - start))
    }

    /// Number of lines that open or close a code fence. When it changes, an
    /// edit may have restyled everything below it.
    public static func fenceLineCount(_ text: String) -> Int {
        var count = 0
        (text as NSString).enumerateSubstrings(
            in: NSRange(location: 0, length: (text as NSString).length),
            options: [.byLines]
        ) { line, _, _, _ in
            if let line, looksLikeFence(line), openingFence(line) != nil { count += 1 }
        }
        return count
    }

    /// Start of the code block that's still open at `location`, if any.
    private static func openFenceStart(in ns: NSString, before location: Int) -> Int? {
        var open: (start: Int, marker: String)?
        ns.enumerateSubstrings(
            in: NSRange(location: 0, length: location), options: [.byLines]
        ) { line, range, _, _ in
            guard let line, looksLikeFence(line) else { return }
            if let fence = open {
                if isFence(line, closing: fence.marker) { open = nil }
            } else if let marker = openingFence(line) {
                open = (range.location, marker)
            }
        }
        return open?.start
    }

    /// Cheap pre-check before any regex: fences start with ``` or ~~~ after
    /// at most three spaces.
    private static func looksLikeFence(_ line: String) -> Bool {
        for (i, c) in line.utf16.enumerated() {
            if c == 0x20, i < 3 { continue }
            return c == 0x60 || c == 0x7E  // ` or ~
        }
        return false
    }

    // MARK: - Code fences

    private static let fenceRx = rx(#"^ {0,3}(`{3,}|~{3,})"#)

    private static func openingFence(_ line: String) -> String? {
        let ns = line as NSString
        guard let match = fenceRx.firstMatch(in: line, range: NSRange(location: 0, length: ns.length))
        else { return nil }
        let marker = ns.substring(with: match.range(at: 1))
        // Backtick fences can't have backticks in the info string.
        if marker.hasPrefix("`"),
           ns.substring(from: NSMaxRange(match.range)).contains("`") { return nil }
        return marker
    }

    private static func isFence(_ line: String, closing marker: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard let first = marker.first, trimmed.count >= marker.count else { return false }
        return trimmed.allSatisfy { $0 == first }
    }

    // MARK: - Line-level syntax

    private static let headingRx = rx(#"^(#{1,6})[ \t]+"#)
    private static let ruleRx = rx(#"^ {0,3}([-*_])(?:[ \t]*\1){2,}[ \t]*$"#)
    private static let quoteRx = rx(#"^ {0,3}>[ \t]?"#)
    private static let taskRx = rx(#"^([ \t]*)[-*+][ \t]+\[([ xX])\](?:[ \t]+|$)"#)
    private static let bulletRx = rx(#"^([ \t]*)[-*+][ \t]+"#)
    private static let orderedRx = rx(#"^([ \t]*)\d{1,9}[.)][ \t]+"#)

    /// Records the line's block syntax and returns the range left for inline
    /// parsing (absolute offsets).
    private static func lineSpans(_ line: String, at lineRange: NSRange,
                                  into spans: inout [MarkdownSpan]) -> NSRange {
        let full = NSRange(location: 0, length: (line as NSString).length)
        let base = lineRange.location
        func abs(_ r: NSRange) -> NSRange { NSRange(location: r.location + base, length: r.length) }
        func rest(after marker: NSRange) -> NSRange {
            NSRange(location: NSMaxRange(marker), length: full.length - NSMaxRange(marker))
        }

        if ruleRx.firstMatch(in: line, range: full) != nil {
            spans.append(MarkdownSpan(kind: .rule, range: lineRange,
                                      content: NSRange(location: NSMaxRange(lineRange), length: 0),
                                      markers: [lineRange]))
            return NSRange(location: NSMaxRange(lineRange), length: 0)
        }
        if let m = headingRx.firstMatch(in: line, range: full) {
            let content = rest(after: m.range)
            spans.append(MarkdownSpan(kind: .heading, range: lineRange, content: abs(content),
                                      markers: [abs(m.range)], level: m.range(at: 1).length))
            return abs(content)
        }
        if let m = quoteRx.firstMatch(in: line, range: full) {
            let content = rest(after: m.range)
            spans.append(MarkdownSpan(kind: .quote, range: lineRange, content: abs(content),
                                      markers: [abs(m.range)]))
            return abs(content)
        }
        for (regex, kind) in [(taskRx, MarkdownSpan.Kind.task),
                              (bulletRx, .bullet), (orderedRx, .orderedItem)] {
            guard let m = regex.firstMatch(in: line, range: full) else { continue }
            let indent = m.range(at: 1)
            let marker = NSRange(location: NSMaxRange(indent), length: NSMaxRange(m.range) - NSMaxRange(indent))
            let content = rest(after: m.range)
            let columns = (line as NSString).substring(with: indent)
                .reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
            var checked = false
            if kind == .task {
                checked = (line as NSString).substring(with: m.range(at: 2)) != " "
            }
            spans.append(MarkdownSpan(
                kind: kind,
                range: NSRange(location: base + marker.location, length: full.length - marker.location),
                content: abs(content), markers: [abs(marker)],
                level: columns, checked: checked))
            return abs(content)
        }
        return lineRange
    }

    // MARK: - Inline syntax

    private static let codeRx = rx(#"`([^`\n]+)`"#)
    private static let wikiRx = rx(#"\[\[([^\[\]\n|]+)(?:\|([^\[\]\n]+))?\]\]"#)
    private static let linkRx = rx(#"\[([^\[\]\n]+)\]\(([^()\s]+)\)"#)
    private static let urlRx = rx(#"(?<![\w/(\[])https?://[^\s<>()\[\]]+"#)
    private static let boldRx = rx(#"\*\*(?=\S)(.+?)(?<=\S)\*\*"#)
    private static let strikeRx = rx(#"~~(?=\S)(.+?)(?<=\S)~~"#)
    private static let highlightRx = rx(#"==(?=\S)(.+?)(?<=\S)=="#)
    private static let italicStarRx = rx(#"(?<![*\w\\])\*(?=[^*\s])([^*\n]+?)(?<=[^*\s])\*(?![*\w])"#)
    private static let italicUnderscoreRx = rx(#"(?<![\w_])_(?=[^_\s])([^_\n]+?)(?<=[^_\s])_(?![\w_])"#)
    private static let escapeRx = rx(#"\\[\\`*_=~\[\]()#>|-]"#)

    /// Character that masks consumed or escaped text so later passes can't
    /// match inside it. Same UTF-16 length as what it replaces.
    private static let mask: unichar = 0x01

    private static func inlineSpans(in ns: NSString, range: NSRange,
                                    into spans: inout [MarkdownSpan]) {
        guard range.length > 0 else { return }
        let base = range.location
        var chars = Array(repeating: unichar(0), count: range.length)
        ns.getCharacters(&chars, range: range)
        func masked() -> String { String(utf16CodeUnits: chars, count: chars.count) }
        func maskOut(_ r: NSRange) {
            for i in r.location..<NSMaxRange(r) { chars[i] = mask }
        }
        func abs(_ r: NSRange) -> NSRange { NSRange(location: r.location + base, length: r.length) }
        func text(_ r: NSRange) -> String { ns.substring(with: abs(r)) }
        func matches(_ regex: NSRegularExpression) -> [NSTextCheckingResult] {
            regex.matches(in: masked(), range: NSRange(location: 0, length: chars.count))
        }

        // Escapes (`\*`) are literal: hide nothing, match nothing.
        for m in matches(escapeRx) { maskOut(m.range) }

        // Atomic spans first — nothing else matches inside them.
        for m in matches(codeRx) {
            spans.append(delimited(.code, m, open: 1, close: 1, abs: abs))
            maskOut(m.range)
        }
        for m in matches(wikiRx) {
            let titleRange = m.range(at: 1)
            let aliasRange = m.range(at: 2)
            let title = text(titleRange).trimmingCharacters(in: .whitespaces)
            let open: NSRange, content: NSRange
            if aliasRange.location != NSNotFound {
                open = NSRange(location: m.range.location, length: aliasRange.location - m.range.location)
                content = aliasRange
            } else {
                open = NSRange(location: m.range.location, length: 2)
                content = titleRange
            }
            let close = NSRange(location: NSMaxRange(m.range) - 2, length: 2)
            spans.append(MarkdownSpan(kind: .wikiLink, range: abs(m.range), content: abs(content),
                                      markers: [abs(open), abs(close)], target: title))
            maskOut(m.range)
        }
        for m in matches(linkRx) {
            let label = m.range(at: 1)
            let open = NSRange(location: m.range.location, length: 1)
            let close = NSRange(location: NSMaxRange(label), length: NSMaxRange(m.range) - NSMaxRange(label))
            spans.append(MarkdownSpan(kind: .link, range: abs(m.range), content: abs(label),
                                      markers: [abs(open), abs(close)], target: text(m.range(at: 2))))
            maskOut(m.range)
        }
        for m in matches(urlRx) {
            var r = m.range
            // Sentence punctuation after a URL isn't part of it.
            while r.length > 0, let last = text(r).unicodeScalars.last,
                  ".,;:!?'\"".unicodeScalars.contains(last) {
                r.length -= 1
            }
            guard r.length > 0 else { continue }
            spans.append(MarkdownSpan(kind: .url, range: abs(r), content: abs(r), markers: [],
                                      target: text(r)))
            maskOut(r)
        }

        // Emphasis may wrap atomic spans (`**see [[Note]]**`) and each other.
        for (regex, kind, width) in [(boldRx, MarkdownSpan.Kind.bold, 2),
                                     (strikeRx, .strikethrough, 2),
                                     (highlightRx, .highlight, 2)] {
            for m in matches(regex) {
                let span = delimited(kind, m, open: width, close: width, abs: abs)
                spans.append(span)
                for marker in span.markers {
                    maskOut(NSRange(location: marker.location - base, length: marker.length))
                }
            }
        }
        for regex in [italicStarRx, italicUnderscoreRx] {
            for m in matches(regex) {
                spans.append(delimited(.italic, m, open: 1, close: 1, abs: abs))
            }
        }
    }

    private static func delimited(_ kind: MarkdownSpan.Kind, _ m: NSTextCheckingResult,
                                  open: Int, close: Int,
                                  abs: (NSRange) -> NSRange) -> MarkdownSpan {
        let r = m.range
        return MarkdownSpan(
            kind: kind, range: abs(r),
            content: abs(NSRange(location: r.location + open, length: r.length - open - close)),
            markers: [abs(NSRange(location: r.location, length: open)),
                      abs(NSRange(location: NSMaxRange(r) - close, length: close))])
    }

    private static func rx(_ pattern: String) -> NSRegularExpression {
        try! NSRegularExpression(pattern: pattern)
    }
}
