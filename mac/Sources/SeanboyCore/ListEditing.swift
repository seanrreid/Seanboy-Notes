import Foundation

/// List-editing rules for the editor (GNote `NoteBuffer` behavior over plain
/// Markdown): Enter continues a list, Enter on an empty item ends it, Tab and
/// Shift-Tab change depth, Backspace after the marker removes it, and Home
/// stops at the start of the item's text. Each rule returns the single edit
/// to make — the editor applies it as one undoable change — or nil to fall
/// back to normal text editing. Mirrored by the Kotlin port; both run
/// `shared/fixtures/list-editing.json`.
public enum ListEditing {
    public struct Edit: Equatable, Sendable {
        public let range: NSRange
        public let replacement: String
        public let selection: NSRange
    }

    /// The list item on one line, from `MarkdownSpans`.
    struct Item {
        let line: NSRange        // line content, no terminator
        let indent: NSRange      // leading whitespace
        let marker: NSRange      // "- ", "3. ", "- [x] "
        let content: NSRange     // text after the marker
        let span: MarkdownSpan
    }

    // MARK: - Enter

    public static func enter(_ text: String, selection: NSRange) -> Edit? {
        let ns = text as NSString
        guard let item = item(in: ns, at: selection.location),
              selection.location >= item.content.location,
              NSMaxRange(selection) <= NSMaxRange(item.line) else { return nil }

        if item.content.length == 0 || isBlank(ns.substring(with: item.content)) {
            // Empty item: outdent if nested, else end the list.
            if item.indent.length > 0 { return outdent(ns, item) }
            let whole = NSRange(location: item.line.location, length: item.line.length)
            return Edit(range: whole, replacement: "",
                        selection: NSRange(location: item.line.location, length: 0))
        }

        let insertion = "\n" + ns.substring(with: item.indent) + nextMarker(ns, item)
        return Edit(range: selection, replacement: insertion,
                    selection: NSRange(location: selection.location + utf16(insertion), length: 0))
    }

    private static func nextMarker(_ ns: NSString, _ item: Item) -> String {
        let marker = ns.substring(with: item.marker)
        switch item.span.kind {
        case .orderedItem:
            let digits = marker.prefix { $0.isNumber }
            let delimiter = marker.dropFirst(digits.count).first ?? "."
            return "\((Int(digits) ?? 0) + 1)\(delimiter) "
        case .task:
            // New tasks start unchecked, with the same bullet character.
            return "\(marker.first ?? "-") [ ] "
        default:
            return "\(marker.first ?? "-") "
        }
    }

    // MARK: - Tab / Shift-Tab

    /// Indents (or outdents) every list item the selection touches. Returns
    /// nil when the selection touches no list items, so Tab inserts a tab.
    public static func indent(_ text: String, selection: NSRange, outdent: Bool) -> Edit? {
        let ns = text as NSString
        let lines = ns.lineRange(for: selection)
        let unit = indentUnit(in: ns)
        var result = ""
        var delta = 0, startDelta = 0
        var touchedItem = false
        ns.enumerateSubstrings(in: lines, options: [.byLines, .substringNotRequired]) { _, line, enclosing, _ in
            var lineText = ns.substring(with: enclosing)
            if item(in: ns, at: line.location) != nil {
                touchedItem = true
                let before = utf16(lineText)
                if outdent {
                    lineText = removingOneLevel(from: lineText, unit: unit)
                } else {
                    lineText = unit + lineText
                }
                let change = utf16(lineText) - before
                if line.location <= selection.location { startDelta = change }
                delta += change
            }
            result += lineText
        }
        guard touchedItem, result != ns.substring(with: lines) else { return touchedItem ? noOp(selection) : nil }
        let start = max(lines.location, selection.location + startDelta)
        let newSelection = selection.length == 0
            ? NSRange(location: start, length: 0)
            : NSRange(location: start, length: max(0, selection.length + delta - startDelta))
        return Edit(range: lines, replacement: result, selection: newSelection)
    }

    /// Shift-Tab on an item that can't outdent further: swallow the key.
    private static func noOp(_ selection: NSRange) -> Edit {
        Edit(range: NSRange(location: selection.location, length: 0), replacement: "", selection: selection)
    }

    /// Outdents an item one level, caret at the end of its line.
    private static func outdent(_ ns: NSString, _ item: Item) -> Edit {
        let unit = indentUnit(in: ns)
        let indent = ns.substring(with: item.indent)
        let newIndent = removingOneLevel(from: indent, unit: unit)
        let removed = utf16(indent) - utf16(newIndent)
        return Edit(range: item.indent, replacement: newIndent,
                    selection: NSRange(location: NSMaxRange(item.line) - removed, length: 0))
    }

    private static func removingOneLevel(from line: String, unit: String) -> String {
        if line.hasPrefix("\t") { return String(line.dropFirst()) }
        let spaces = line.prefix { $0 == " " }.count
        let width = unit == "\t" ? 4 : utf16(unit)
        return String(line.dropFirst(min(spaces, width)))
    }

    /// The note's own nesting style: tabs if any list item is tab-indented,
    /// else the smallest space indent used (2–4), else a tab (Obsidian's
    /// default).
    static func indentUnit(in ns: NSString) -> String {
        var smallest = Int.max
        var usesTabs = false
        ns.enumerateSubstrings(in: NSRange(location: 0, length: ns.length), options: .byLines) { line, _, _, stop in
            guard let line, let first = line.first, first == " " || first == "\t" else { return }
            let trimmed = line.drop { $0 == " " || $0 == "\t" }
            guard let marker = trimmed.first, "-*+".contains(marker) || marker.isNumber else { return }
            if first == "\t" {
                usesTabs = true
                stop.pointee = true
            } else {
                smallest = min(smallest, line.prefix { $0 == " " }.count)
            }
        }
        if usesTabs || smallest == Int.max { return "\t" }
        return String(repeating: " ", count: min(max(smallest, 2), 4))
    }

    // MARK: - Backspace

    /// Backspace right after an item's marker removes the marker (outdenting
    /// first when nested), keeping the text.
    public static func backspace(_ text: String, selection: NSRange) -> Edit? {
        let ns = text as NSString
        guard selection.length == 0,
              let item = item(in: ns, at: selection.location),
              selection.location == item.content.location else { return nil }
        if item.indent.length > 0 {
            let unit = indentUnit(in: ns)
            let indent = ns.substring(with: item.indent)
            let newIndent = removingOneLevel(from: indent, unit: unit)
            let removed = utf16(indent) - utf16(newIndent)
            return Edit(range: item.indent, replacement: newIndent,
                        selection: NSRange(location: selection.location - removed, length: 0))
        }
        return Edit(range: item.marker, replacement: "",
                    selection: NSRange(location: item.marker.location, length: 0))
    }

    // MARK: - Home

    /// Home/⌘← inside a list item goes to the start of its text; from there
    /// (or from inside the marker) it goes to the start of the line.
    public static func lineStart(_ text: String, caret: Int) -> Int? {
        let ns = text as NSString
        guard let item = item(in: ns, at: caret) else { return nil }
        return caret > item.content.location ? item.content.location : item.line.location
    }

    // MARK: - Checkboxes

    /// Toggles the `[ ]`/`[x]` of the task on the line containing `location`.
    public static func toggleTask(_ text: String, at location: Int) -> Edit? {
        let ns = text as NSString
        guard let item = item(in: ns, at: location), item.span.kind == .task else { return nil }
        let marker = ns.substring(with: item.marker) as NSString
        let bracket = marker.range(of: "[")
        guard bracket.location != NSNotFound else { return nil }
        let box = NSRange(location: item.marker.location + bracket.location + 1, length: 1)
        return Edit(range: box, replacement: item.span.checked ? " " : "x",
                    selection: NSRange(location: location, length: 0))
    }

    // MARK: - Helpers

    static func item(in ns: NSString, at location: Int) -> Item? {
        let clamped = min(max(location, 0), ns.length)
        let enclosing = ns.lineRange(for: NSRange(location: clamped, length: 0))
        var contentEnd = NSMaxRange(enclosing)
        while contentEnd > enclosing.location,
              let scalar = UnicodeScalar(ns.character(at: contentEnd - 1)),
              CharacterSet.newlines.contains(scalar) { contentEnd -= 1 }
        let line = NSRange(location: enclosing.location, length: contentEnd - enclosing.location)
        let (spans, _) = MarkdownSpans.parse(ns as String, linesTouching: line)
        // List spans start at the marker, after any indent, on this line.
        guard let span = spans.first(where: {
            [.bullet, .orderedItem, .task].contains($0.kind)
                && $0.range.location >= line.location && $0.range.location <= NSMaxRange(line)
        }), let marker = span.markers.first else { return nil }
        return Item(line: line,
                    indent: NSRange(location: line.location, length: marker.location - line.location),
                    marker: marker, content: span.content, span: span)
    }

    private static func isBlank(_ s: String) -> Bool {
        s.allSatisfy { $0 == " " || $0 == "\t" }
    }

    private static func utf16(_ s: String) -> Int { (s as NSString).length }
}
