import AppKit
import SeanboyCore

extension NSAttributedString.Key {
    /// Marker characters not drawn at all (zero width) — Live Preview on
    /// lines without the cursor. Consumed by `LivePreviewLayout`.
    static let livePreviewHidden = NSAttributedString.Key("SeanboyLivePreviewHidden")
    /// A list marker character drawn as `•`.
    static let livePreviewBullet = NSAttributedString.Key("SeanboyLivePreviewBullet")
    /// Line decorations drawn by `MarkdownTextView.drawBackground(in:)`.
    static let livePreviewQuote = NSAttributedString.Key("SeanboyLivePreviewQuote")
    static let livePreviewCodeBlock = NSAttributedString.Key("SeanboyLivePreviewCodeBlock")
    static let livePreviewRule = NSAttributedString.Key("SeanboyLivePreviewRule")
    /// The `[ ]`/`[x]` box character of a rendered task (value: checked).
    /// Drawn as a space widened by kern, with a checkbox painted over it.
    static let livePreviewCheckbox = NSAttributedString.Key("SeanboyLivePreviewCheckbox")
}

/// Turns `MarkdownSpans` into text attributes, Obsidian Live Preview style:
/// syntax markers are hidden except on the revealed (cursor) lines, where
/// they show faded. Only ever sets attributes — the characters in the
/// storage are the note's Markdown, untouched.
enum MarkdownStyler {
    static let baseSize: CGFloat = 15
    static let baseFont = NSFont.systemFont(ofSize: baseSize)
    static let codeFont = NSFont.monospacedSystemFont(ofSize: 13.5, weight: .regular)
    static let quoteIndent: CGFloat = 16
    static let codeBlockIndent: CGFloat = 10
    private static let headingSizes: [CGFloat] = [24, 20, 17, 15, 15, 15]

    private static var baseAttributes: [NSAttributedString.Key: Any] {
        [.font: baseFont, .foregroundColor: NSColor.labelColor]
    }

    /// Restyles the lines touching `edited` (widened to whole code blocks)
    /// and returns the range it restyled. `revealed` is the range of lines
    /// whose markers stay visible (the cursor lines), or nil to render
    /// everything. Callers outside an editing pass wrap this in
    /// `beginEditing`/`endEditing`; from `textStorage(_:didProcessEditing:…)`
    /// the storage is already editing.
    @discardableResult
    static func restyle(_ storage: NSTextStorage, around edited: NSRange,
                        revealing revealed: NSRange?) -> NSRange {
        let (spans, covered) = MarkdownSpans.parse(storage.string, linesTouching: edited)
        guard covered.length > 0 else { return covered }
        storage.setAttributes(baseAttributes, range: covered)
        for span in spans {
            apply(span, to: storage, revealed: isRevealed(span, revealed))
        }
        return covered
    }

    /// A span's markers show when the cursor lines touch it. Line spans and
    /// inline spans never cross lines, so touching the span is touching its
    /// line; a code block reveals its fences when the cursor is anywhere in it.
    private static func isRevealed(_ span: MarkdownSpan, _ revealed: NSRange?) -> Bool {
        guard let revealed else { return false }
        let start = revealed.location, end = NSMaxRange(revealed)
        return span.range.location <= end && NSMaxRange(span.range) >= start
            && !(revealed.length > 0 && span.range.location == end)
    }

    private static func apply(_ span: MarkdownSpan, to storage: NSTextStorage, revealed: Bool) {
        func markers() { revealed ? fade(span.markers, in: storage) : hide(span.markers, in: storage) }

        switch span.kind {
        case .heading:
            let size = headingSizes[min(span.level, headingSizes.count) - 1]
            storage.addAttributes([
                .font: NSFont.systemFont(ofSize: size, weight: .bold),
                .foregroundColor: NSColor.controlAccentColor,
            ], range: span.range)
            markers()
        case .bold:
            addTraits(.boldFontMask, to: span.range, in: storage)
            markers()
        case .italic:
            addTraits(.italicFontMask, to: span.range, in: storage)
            markers()
        case .strikethrough:
            storage.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue,
                                 range: span.content)
            markers()
        case .highlight:
            storage.addAttribute(.backgroundColor,
                                 value: NSColor.systemYellow.withAlphaComponent(0.35),
                                 range: span.content)
            markers()
        case .code:
            storage.addAttribute(.font, value: codeFont, range: span.range)
            storage.addAttributes([
                .foregroundColor: NSColor.systemPink,
                .backgroundColor: NSColor.quaternaryLabelColor.withAlphaComponent(0.12),
            ], range: span.content)
            markers()
        case .codeBlock:
            let paragraph = NSMutableParagraphStyle()
            paragraph.firstLineHeadIndent = codeBlockIndent
            paragraph.headIndent = codeBlockIndent
            storage.addAttributes([
                .font: codeFont,
                .paragraphStyle: paragraph,
                .livePreviewCodeBlock: true,
            ], range: span.range)
            markers()
        case .wikiLink:
            // The whole `[[…]]` is clickable; it opens or creates the note.
            if let target = span.target,
               let encoded = target.addingPercentEncoding(withAllowedCharacters: .alphanumerics),
               let url = URL(string: "seanboy://\(encoded)") {
                storage.addAttribute(.link, value: url, range: span.range)
            }
            markers()
        case .link:
            if let target = span.target, let url = URL(string: target) {
                storage.addAttribute(.link, value: url, range: span.content)
            }
            markers()
        case .url:
            if let target = span.target, let url = URL(string: target) {
                storage.addAttribute(.link, value: url, range: span.range)
            }
        case .quote:
            let paragraph = NSMutableParagraphStyle()
            paragraph.firstLineHeadIndent = revealed ? 0 : quoteIndent
            paragraph.headIndent = quoteIndent
            storage.addAttributes([
                .paragraphStyle: paragraph,
                .livePreviewQuote: true,
            ], range: span.range)
            storage.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor,
                                 range: span.content)
            revealed ? tint(span.markers, in: storage) : hide(span.markers, in: storage)
        case .rule:
            if revealed {
                fade(span.markers, in: storage)
            } else {
                hide(span.markers, in: storage)
                storage.addAttribute(.livePreviewRule, value: true, range: span.range)
            }
        case .bullet:
            // Bullets always render as •; the file keeps its `-`, `*`, or `+`.
            tint(span.markers, in: storage)
            if let marker = span.markers.first {
                storage.addAttribute(.livePreviewBullet, value: true,
                                     range: NSRange(location: marker.location, length: 1))
            }
        case .orderedItem:
            tint(span.markers, in: storage)
        case .task:
            // Rendered: the whole `- [ ] ` marker collapses to one checkbox.
            if revealed {
                tint(span.markers, in: storage)
            } else if let marker = span.markers.first {
                let text = storage.mutableString.substring(with: marker) as NSString
                let bracket = text.range(of: "[")
                if bracket.location != NSNotFound {
                    let box = NSRange(location: marker.location + bracket.location + 1, length: 1)
                    // Hide `- [` and `]`; the trailing space stays as the gap.
                    hide([NSRange(location: marker.location, length: box.location - marker.location),
                          NSRange(location: NSMaxRange(box), length: 1)], in: storage)
                    storage.addAttributes([
                        .livePreviewCheckbox: span.checked,
                        .kern: MarkdownTextView.checkboxSize + 2,
                    ], range: box)
                }
            }
            if span.checked {
                storage.addAttributes([
                    .strikethroughStyle: NSUnderlineStyle.single.rawValue,
                    .foregroundColor: NSColor.secondaryLabelColor,
                ], range: span.content)
            }
        }
    }

    /// Adds bold/italic on top of whatever font is already there, so bold
    /// inside a heading stays heading-sized.
    private static func addTraits(_ traits: NSFontTraitMask, to range: NSRange,
                                  in storage: NSTextStorage) {
        storage.enumerateAttribute(.font, in: range) { value, subrange, _ in
            let font = (value as? NSFont) ?? baseFont
            storage.addAttribute(.font, value: NSFontManager.shared.convert(font, toHaveTrait: traits),
                                 range: subrange)
        }
    }

    private static func fade(_ markers: [NSRange], in storage: NSTextStorage) {
        for marker in markers {
            storage.addAttribute(.foregroundColor, value: NSColor.tertiaryLabelColor, range: marker)
        }
    }

    private static func hide(_ markers: [NSRange], in storage: NSTextStorage) {
        for marker in markers where marker.length > 0 {
            storage.addAttribute(.livePreviewHidden, value: true, range: marker)
        }
    }

    private static func tint(_ markers: [NSRange], in storage: NSTextStorage) {
        for marker in markers {
            storage.addAttribute(.foregroundColor, value: NSColor.controlAccentColor, range: marker)
        }
    }
}

/// Layout-manager delegate that renders Live Preview without touching the
/// text: hidden markers become null glyphs (no width, no drawing), bullet
/// markers become `•`, and task boxes become a space the checkbox is drawn on.
final class LivePreviewLayout: NSObject, NSLayoutManagerDelegate {
    func layoutManager(_ layoutManager: NSLayoutManager,
                       shouldGenerateGlyphs glyphs: UnsafePointer<CGGlyph>,
                       properties: UnsafePointer<NSLayoutManager.GlyphProperty>,
                       characterIndexes: UnsafePointer<Int>,
                       font: NSFont,
                       forGlyphRange glyphRange: NSRange) -> Int {
        guard let storage = layoutManager.textStorage, glyphRange.length > 0 else { return 0 }
        let count = glyphRange.length
        let first = characterIndexes[0]
        let span = NSRange(location: first, length: characterIndexes[count - 1] - first + 1)

        var hidden = IndexSet()
        storage.enumerateAttribute(.livePreviewHidden, in: span) { value, range, _ in
            if value != nil { hidden.insert(integersIn: range.location..<NSMaxRange(range)) }
        }
        var bullets = IndexSet()
        storage.enumerateAttribute(.livePreviewBullet, in: span) { value, range, _ in
            if value != nil { bullets.insert(integersIn: range.location..<NSMaxRange(range)) }
        }
        var boxes = IndexSet()
        storage.enumerateAttribute(.livePreviewCheckbox, in: span) { value, range, _ in
            if value != nil { boxes.insert(integersIn: range.location..<NSMaxRange(range)) }
        }
        guard !hidden.isEmpty || !bullets.isEmpty || !boxes.isEmpty else { return 0 }

        // Glyphs arrive one font run at a time, so `font` is the bullet's font.
        var newGlyphs = Array(UnsafeBufferPointer(start: glyphs, count: count))
        var newProperties = Array(UnsafeBufferPointer(start: properties, count: count))
        for i in 0..<count {
            let index = characterIndexes[i]
            if hidden.contains(index) {
                newProperties[i] = .null
            } else if bullets.contains(index) {
                newGlyphs[i] = Self.glyph(0x2022, in: font)  // •
            } else if boxes.contains(index) {
                newGlyphs[i] = Self.glyph(0x20, in: font)  // space; the box is drawn over it
            }
        }
        layoutManager.setGlyphs(newGlyphs, properties: newProperties,
                                characterIndexes: characterIndexes, font: font,
                                forGlyphRange: glyphRange)
        return count
    }

    private static func glyph(_ character: UniChar, in font: NSFont) -> CGGlyph {
        var character = character
        var glyph: CGGlyph = 0
        CTFontGetGlyphsForCharacters(font as CTFont, &character, &glyph, 1)
        return glyph
    }
}
