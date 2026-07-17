import AppKit
import SwiftUI
import TomboyCore

/// Plain-Markdown editor with live styling: headings, bold, italic,
/// ==highlight==, bullets, inline code, and clickable [[wiki links]].
/// Shortcuts: ⌘B bold, ⌘I italic, ⇧⌘H highlight, ⇧⌘K wiki link.
struct MarkdownEditor: NSViewRepresentable {
    @Binding var text: String
    var onOpenWikiLink: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = MarkdownTextView.make()
        let scrollView = NSScrollView()
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false

        textView.delegate = context.coordinator
        context.coordinator.textView = textView
        textView.string = text
        context.coordinator.applyStyling()
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = scrollView.documentView as? NSTextView else { return }
        if textView.string != text {
            let selection = textView.selectedRange()
            textView.string = text
            let limit = (text as NSString).length
            textView.setSelectedRange(NSRange(location: min(selection.location, limit), length: 0))
            context.coordinator.applyStyling()
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: MarkdownEditor
        weak var textView: MarkdownTextView?

        init(_ parent: MarkdownEditor) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView else { return }
            parent.text = textView.string
            applyStyling()
        }

        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            guard let url = link as? URL, url.scheme == "tomboymac" else { return false }
            if let title = url.host(percentEncoded: false) {
                parent.onOpenWikiLink(title)
            }
            return true
        }

        func applyStyling() {
            guard let storage = textView?.textStorage else { return }
            MarkdownStyler.style(storage)
        }
    }
}

/// NSTextView subclass that adds Markdown formatting key equivalents.
final class MarkdownTextView: NSTextView {

    static func make() -> MarkdownTextView {
        let textView = MarkdownTextView(frame: .zero)
        textView.isRichText = false
        textView.allowsUndo = true
        textView.font = MarkdownStyler.baseFont
        textView.textContainerInset = NSSize(width: 12, height: 12)
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.usesFindBar = true
        textView.drawsBackground = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(
            width: 0, height: CGFloat.greatestFiniteMagnitude)
        return textView
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let key = event.charactersIgnoringModifiers?.lowercased()
        switch (mods, key) {
        case ([.command], "b"):
            wrapSelection(with: "**", placeholder: "bold")
            return true
        case ([.command], "i"):
            wrapSelection(with: "*", placeholder: "italic")
            return true
        case ([.command, .shift], "h"):
            wrapSelection(with: "==", placeholder: "highlight")
            return true
        case ([.command, .shift], "k"):
            insertWikiLink()
            return true
        default:
            return super.performKeyEquivalent(with: event)
        }
    }

    private func insert(_ replacement: String, in range: NSRange, selectFrom offset: Int, length: Int) {
        guard shouldChangeText(in: range, replacementString: replacement) else { return }
        replaceCharacters(in: range, with: replacement)
        didChangeText()
        setSelectedRange(NSRange(location: range.location + offset, length: length))
    }

    func wrapSelection(with marker: String, placeholder: String) {
        let range = selectedRange()
        let selected = range.length > 0 ? (string as NSString).substring(with: range) : placeholder
        insert("\(marker)\(selected)\(marker)", in: range,
               selectFrom: (marker as NSString).length,
               length: (selected as NSString).length)
    }

    func insertWikiLink() {
        let range = selectedRange()
        let selected = range.length > 0 ? (string as NSString).substring(with: range) : "Note Title"
        insert("[[\(selected)]]", in: range,
               selectFrom: 2, length: (selected as NSString).length)
    }
}

/// Applies Markdown-ish attributes across the whole text storage.
/// Notes are small, so restyling everything per keystroke is fine.
enum MarkdownStyler {
    static let baseFont = NSFont.systemFont(ofSize: 15)

    private struct Rule {
        let regex: NSRegularExpression
        let apply: (NSTextStorage, NSTextCheckingResult) -> Void
    }

    private static func rx(_ pattern: String) -> NSRegularExpression {
        try! NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines])
    }

    nonisolated(unsafe) private static let rules: [Rule] = [
        // # Headings — bigger and bolder by level
        Rule(regex: rx(#"^(#{1,3})[ \t].*$"#)) { storage, match in
            let hashes = storage.mutableString.substring(with: match.range(at: 1)).count
            let size: CGFloat = [24, 20, 17][min(hashes, 3) - 1]
            storage.addAttribute(.font, value: NSFont.systemFont(ofSize: size, weight: .bold),
                                 range: match.range)
        },
        // **bold**
        Rule(regex: rx(#"\*\*([^*\n]+)\*\*"#)) { storage, match in
            storage.addAttribute(.font, value: NSFont.boldSystemFont(ofSize: 15), range: match.range)
            fade(storage, match.range, markerLength: 2)
        },
        // *italic* (not part of **)
        Rule(regex: rx(#"(?<![*\w])\*([^*\n]+)\*(?![*\w])"#)) { storage, match in
            let italic = NSFontManager.shared.convert(baseFont, toHaveTrait: .italicFontMask)
            storage.addAttribute(.font, value: italic, range: match.range)
            fade(storage, match.range, markerLength: 1)
        },
        // ==highlight== — Tomboy's yellow marker
        Rule(regex: rx(#"==([^=\n]+)=="#)) { storage, match in
            storage.addAttribute(.backgroundColor,
                                 value: NSColor.systemYellow.withAlphaComponent(0.35),
                                 range: match.range)
            fade(storage, match.range, markerLength: 2)
        },
        // `inline code`
        Rule(regex: rx(#"`([^`\n]+)`"#)) { storage, match in
            storage.addAttribute(.font,
                                 value: NSFont.monospacedSystemFont(ofSize: 13.5, weight: .regular),
                                 range: match.range)
            storage.addAttribute(.foregroundColor, value: NSColor.systemPink, range: match.range)
        },
        // - bullets / * bullets: tint the marker
        Rule(regex: rx(#"^[ \t]*([-*+])[ \t]"#)) { storage, match in
            storage.addAttribute(.foregroundColor, value: NSColor.controlAccentColor,
                                 range: match.range(at: 1))
        },
        // [[Wiki Link]] — clickable, opens/creates the note
        Rule(regex: rx(#"\[\[([^\[\]\n]+)\]\]"#)) { storage, match in
            let title = storage.mutableString.substring(with: match.range(at: 1))
                .trimmingCharacters(in: .whitespaces)
            guard !title.isEmpty,
                  let encoded = title.addingPercentEncoding(withAllowedCharacters: .alphanumerics),
                  let url = URL(string: "tomboymac://\(encoded)") else { return }
            storage.addAttribute(.link, value: url, range: match.range)
            storage.addAttribute(.foregroundColor, value: NSColor.controlAccentColor,
                                 range: match.range)
            storage.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue,
                                 range: match.range)
        },
    ]

    private static func fade(_ storage: NSTextStorage, _ range: NSRange, markerLength: Int) {
        let color = NSColor.tertiaryLabelColor
        storage.addAttribute(.foregroundColor, value: color,
                             range: NSRange(location: range.location, length: markerLength))
        storage.addAttribute(.foregroundColor, value: color,
                             range: NSRange(location: range.location + range.length - markerLength,
                                            length: markerLength))
    }

    static func style(_ storage: NSTextStorage) {
        let full = NSRange(location: 0, length: storage.length)
        storage.beginEditing()
        storage.setAttributes([
            .font: baseFont,
            .foregroundColor: NSColor.labelColor,
        ], range: full)
        for rule in rules {
            for match in rule.regex.matches(in: storage.string, range: full) {
                rule.apply(storage, match)
            }
        }
        storage.endEditing()
    }
}
