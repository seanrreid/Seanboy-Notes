import AppKit
import SwiftUI
import SeanboyCore

/// Plain-Markdown editor with live styling: headings, bold, italic,
/// ==highlight==, bullets, inline code, and clickable [[wiki links]].
/// Shortcuts: ⌘B bold, ⌘I italic, ⇧⌘H highlight, ⇧⌘K wiki link.
///
/// The note's title sits at the top of the same scroll view as an
/// Obsidian-style inline title (`InlineTitleHeader`). It edits the filename,
/// never the body text.
struct MarkdownEditor: NSViewRepresentable {
    @Binding var text: String
    var title: String
    var titleWarning: String?
    /// Put the cursor in the title when the note opens (fresh ⌘N notes).
    var focusTitle: Bool
    var onTitleEdit: (String) -> Void
    var onTitleCommit: () -> Void
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

        let header = InlineTitleHeader()
        header.field.stringValue = title
        header.setWarning(titleWarning)
        header.wantsInitialFocus = focusTitle
        header.onEdit = { [weak coordinator = context.coordinator] in coordinator?.parent.onTitleEdit($0) }
        header.onCommit = { [weak coordinator = context.coordinator] in coordinator?.parent.onTitleCommit() }
        header.onExit = { [weak textView] in
            guard let textView else { return }
            textView.window?.makeFirstResponder(textView)
            textView.setSelectedRange(NSRange(location: 0, length: 0))
        }
        textView.header = header
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = scrollView.documentView as? MarkdownTextView else { return }
        if let header = textView.header {
            // Never clobber the title while the user is typing in it.
            if header.field.currentEditor() == nil, header.field.stringValue != title {
                header.field.stringValue = title
            }
            header.setWarning(titleWarning)
            textView.layoutHeader()
        }
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
            guard let url = link as? URL, url.scheme == "seanboy" else { return false }
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

/// NSTextView subclass that adds Markdown formatting key equivalents and
/// hosts the inline title above the first line of text.
final class MarkdownTextView: NSTextView {
    static let bodyInset = NSSize(width: 12, height: 12)

    /// Drawn as a subview in the top inset; the text container starts below it.
    var header: InlineTitleHeader? {
        didSet {
            oldValue?.removeFromSuperview()
            if let header { addSubview(header) }
            layoutHeader()
        }
    }
    private var headerHeight: CGFloat = 0

    /// Sizes the header to the view's width and reserves room for it. NSTextView
    /// pads top and bottom by the same `textContainerInset.height`, so the
    /// inset grows by half the header and `textContainerOrigin` shifts the
    /// text down by the rest — leaving the usual padding at the bottom.
    func layoutHeader() {
        let height = header?.preferredHeight ?? 0
        header?.frame = NSRect(x: 0, y: 0, width: bounds.width, height: height)
        guard height != headerHeight else { return }
        headerHeight = height
        textContainerInset = NSSize(
            width: Self.bodyInset.width, height: Self.bodyInset.height + height / 2)
        invalidateTextContainerOrigin()
        needsDisplay = true
    }

    override var textContainerOrigin: NSPoint {
        NSPoint(x: textContainerInset.width, y: Self.bodyInset.height + headerHeight)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        header?.frame.size.width = newSize.width
    }

    /// ↑ on the first line moves into the title, like Obsidian.
    override func moveUp(_ sender: Any?) {
        if let header, caretIsOnFirstLine {
            header.focusField(in: window)
        } else {
            super.moveUp(sender)
        }
    }

    private var caretIsOnFirstLine: Bool {
        let length = (string as NSString).length
        guard length > 0, let layoutManager else { return true }
        let caret = selectedRange().location
        // Past a trailing newline the caret sits on the extra, empty last line.
        if caret >= length, string.hasSuffix("\n") { return false }
        let glyph = layoutManager.glyphIndexForCharacter(at: min(caret, length - 1))
        var line = NSRange()
        layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: &line)
        return line.location == 0
    }

    static func make() -> MarkdownTextView {
        let textView = MarkdownTextView(frame: .zero)
        textView.isRichText = false
        textView.allowsUndo = true
        textView.font = MarkdownStyler.baseFont
        textView.textContainerInset = bodyInset
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
                  let url = URL(string: "seanboy://\(encoded)") else { return }
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

/// Obsidian-style inline title: a large accent-colored field above the note
/// body. Keystrokes report through `onEdit` (the view model debounces the
/// rename); leaving the field fires `onCommit`; Enter, ↓, or Tab move to the
/// body via `onExit`.
final class InlineTitleHeader: NSView, NSTextFieldDelegate {
    let field = NSTextField()
    private let warning = NSTextField(labelWithString: "")
    var onEdit: ((String) -> Void)?
    var onCommit: (() -> Void)?
    var onExit: (() -> Void)?
    var wantsInitialFocus = false

    /// Aligns the title's first glyph with the body text: text container
    /// inset plus the line fragment padding, minus the field cell's own inset.
    private static let leading = MarkdownTextView.bodyInset.width + 5 - 2
    private static let top: CGFloat = 16
    private static let gap: CGFloat = 4

    override var isFlipped: Bool { true }

    init() {
        super.init(frame: .zero)
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 26, weight: .bold)
        field.textColor = .controlAccentColor
        field.placeholderString = "Untitled"
        field.usesSingleLineMode = true
        field.lineBreakMode = .byTruncatingTail
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        field.delegate = self
        addSubview(field)

        warning.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        warning.textColor = .systemOrange
        warning.isHidden = true
        addSubview(warning)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    var preferredHeight: CGFloat {
        var height = Self.top + field.intrinsicContentSize.height
        if !warning.isHidden { height += Self.gap + warning.intrinsicContentSize.height }
        return height
    }

    func setWarning(_ message: String?) {
        warning.stringValue = message ?? ""
        warning.isHidden = message == nil
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let width = max(0, bounds.width - Self.leading * 2)
        let fieldHeight = field.intrinsicContentSize.height
        field.frame = NSRect(x: Self.leading, y: Self.top, width: width, height: fieldHeight)
        warning.frame = NSRect(
            x: Self.leading + 2, y: Self.top + fieldHeight + Self.gap,
            width: width, height: warning.intrinsicContentSize.height)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard wantsInitialFocus, let window else { return }
        wantsInitialFocus = false
        DispatchQueue.main.async { [weak self] in self?.focusField(in: window) }
    }

    func focusField(in window: NSWindow?) {
        guard let window, window.makeFirstResponder(field) else { return }
        // Put the caret at the end instead of selecting the whole title.
        if let editor = field.currentEditor() {
            editor.selectedRange = NSRange(location: (field.stringValue as NSString).length, length: 0)
        }
    }

    // MARK: NSTextFieldDelegate

    func controlTextDidChange(_ notification: Notification) {
        onEdit?(field.stringValue)
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        onCommit?()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)),
             #selector(NSResponder.moveDown(_:)),
             #selector(NSResponder.insertTab(_:)):
            onExit?()
            return true
        default:
            return false
        }
    }
}
