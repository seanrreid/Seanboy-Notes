import AppKit
import SeanboyCore

/// Turns `MarkdownSpans` into text attributes. Only ever sets attributes —
/// the characters in the storage are the note's Markdown, untouched.
enum MarkdownStyler {
    static let baseSize: CGFloat = 15
    static let baseFont = NSFont.systemFont(ofSize: baseSize)
    static let codeFont = NSFont.monospacedSystemFont(ofSize: 13.5, weight: .regular)
    private static let headingSizes: [CGFloat] = [24, 20, 17, 15, 15, 15]

    private static var baseAttributes: [NSAttributedString.Key: Any] {
        [.font: baseFont, .foregroundColor: NSColor.labelColor]
    }

    /// Restyles the lines touching `edited` (widened to whole code blocks)
    /// and returns the range it restyled. Callers outside an editing pass
    /// wrap this in `beginEditing`/`endEditing`; from
    /// `textStorage(_:didProcessEditing:…)` the storage is already editing.
    @discardableResult
    static func restyle(_ storage: NSTextStorage, around edited: NSRange) -> NSRange {
        let (spans, covered) = MarkdownSpans.parse(storage.string, linesTouching: edited)
        guard covered.length > 0 else { return covered }
        storage.setAttributes(baseAttributes, range: covered)
        for span in spans { apply(span, to: storage) }
        return covered
    }

    private static func apply(_ span: MarkdownSpan, to storage: NSTextStorage) {
        switch span.kind {
        case .heading:
            let size = headingSizes[min(span.level, headingSizes.count) - 1]
            storage.addAttribute(.font, value: NSFont.systemFont(ofSize: size, weight: .bold),
                                 range: span.range)
            fade(span.markers, in: storage)
        case .bold:
            addTraits(.boldFontMask, to: span.range, in: storage)
            fade(span.markers, in: storage)
        case .italic:
            addTraits(.italicFontMask, to: span.range, in: storage)
            fade(span.markers, in: storage)
        case .strikethrough:
            storage.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue,
                                 range: span.content)
            fade(span.markers, in: storage)
        case .highlight:
            storage.addAttribute(.backgroundColor,
                                 value: NSColor.systemYellow.withAlphaComponent(0.35),
                                 range: span.range)
            fade(span.markers, in: storage)
        case .code:
            storage.addAttribute(.font, value: codeFont, range: span.range)
            storage.addAttribute(.foregroundColor, value: NSColor.systemPink, range: span.content)
            fade(span.markers, in: storage)
        case .codeBlock:
            storage.addAttribute(.font, value: codeFont, range: span.range)
            fade(span.markers, in: storage)
        case .wikiLink:
            // The whole `[[…]]` is clickable; it opens or creates the note.
            if let target = span.target,
               let encoded = target.addingPercentEncoding(withAllowedCharacters: .alphanumerics),
               let url = URL(string: "seanboy://\(encoded)") {
                storage.addAttribute(.link, value: url, range: span.range)
            }
        case .link:
            if let target = span.target, let url = URL(string: target) {
                storage.addAttribute(.link, value: url, range: span.content)
            }
            fade(span.markers, in: storage)
        case .url:
            if let target = span.target, let url = URL(string: target) {
                storage.addAttribute(.link, value: url, range: span.range)
            }
        case .quote:
            storage.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor,
                                 range: span.content)
            tint(span.markers, in: storage)
        case .rule:
            fade(span.markers, in: storage)
        case .bullet, .orderedItem:
            tint(span.markers, in: storage)
        case .task:
            tint(span.markers, in: storage)
            if span.checked {
                storage.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue,
                                     range: span.content)
                storage.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor,
                                     range: span.content)
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

    private static func tint(_ markers: [NSRange], in storage: NSTextStorage) {
        for marker in markers {
            storage.addAttribute(.foregroundColor, value: NSColor.controlAccentColor, range: marker)
        }
    }
}
