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
    /// The note's unmanaged frontmatter as editable text (Properties row).
    var propertiesText: String = ""
    var propertiesWarning: String?
    var onPropertiesEdit: (String) -> Void = { _ in }
    var onPropertiesCommit: () -> Void = {}
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
        textView.layoutManager?.delegate = context.coordinator.layout
        textView.onFocusChange = { [weak coordinator = context.coordinator] in
            coordinator?.updateRevealedLines()
        }
        textView.string = text
        context.coordinator.styleAll()
        textView.textStorage?.delegate = context.coordinator

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
        header.setProperties(propertiesText, warning: propertiesWarning)
        header.onPropertiesEdit = { [weak coordinator = context.coordinator] in
            coordinator?.parent.onPropertiesEdit($0)
        }
        header.onPropertiesCommit = { [weak coordinator = context.coordinator] in
            coordinator?.parent.onPropertiesCommit()
        }
        header.onHeightChange = { [weak textView] in textView?.layoutHeader() }
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
            header.setProperties(propertiesText, warning: propertiesWarning)
            textView.layoutHeader()
        }
        // External changes (watcher, sync) arrive here. Never mid-IME.
        if textView.string != text, !textView.hasMarkedText() {
            context.coordinator.applyExternalText(text)
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate, NSTextStorageDelegate {
        var parent: MarkdownEditor
        weak var textView: MarkdownTextView?
        private var fenceLineCount = 0
        private var isApplyingExternalText = false
        /// Lines whose markers are visible: the cursor/selection lines while
        /// the editor has focus, else nil (everything rendered).
        private(set) var revealedLines: NSRange?
        let layout = LivePreviewLayout()

        init(_ parent: MarkdownEditor) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView, !isApplyingExternalText else { return }
            parent.text = textView.string
        }

        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            guard let url = link as? URL, url.scheme == "seanboy" else { return false }
            if let title = url.host(percentEncoded: false) {
                parent.onOpenWikiLink(title)
            }
            return true
        }

        // MARK: Styling

        func styleAll() {
            guard let storage = textView?.textStorage else { return }
            fenceLineCount = MarkdownSpans.fenceLineCount(storage.string)
            revealedLines = currentRevealedLines()
            storage.beginEditing()
            MarkdownStyler.restyle(storage, around: NSRange(location: 0, length: storage.length),
                                   revealing: revealedLines)
            storage.endEditing()
        }

        private func currentRevealedLines() -> NSRange? {
            guard let textView, textView.isEditorFocused else { return nil }
            let ns = textView.string as NSString
            let selection = textView.selectedRange()
            let clamped = NSRange(location: min(selection.location, ns.length),
                                  length: min(selection.length, ns.length - min(selection.location, ns.length)))
            return ns.lineRange(for: clamped)
        }

        /// Moving the cursor to another line (or focus in/out) swaps which
        /// lines show their markers: restyle the old and new cursor lines.
        func updateRevealedLines() {
            guard let storage = textView?.textStorage else { return }
            let new = currentRevealedLines()
            guard new != revealedLines else { return }
            let old = revealedLines
            revealedLines = new
            storage.beginEditing()
            for lines in [old, new].compactMap({ $0 }) {
                let clamped = NSRange(location: min(lines.location, storage.length),
                                      length: min(lines.length, storage.length - min(lines.location, storage.length)))
                MarkdownStyler.restyle(storage, around: clamped, revealing: new)
            }
            storage.endEditing()
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            updateRevealedLines()
        }

        /// Restyles only the edited lines. Adding, removing, or changing a
        /// code fence can restyle everything below it, so that restyles to
        /// the end. Skipped while IME text is being composed — resetting
        /// attributes would erase its marked-text underline; the commit is
        /// itself an edit and restyles.
        func textStorage(_ storage: NSTextStorage, didProcessEditing mask: NSTextStorageEditActions,
                         range edited: NSRange, changeInLength delta: Int) {
            guard mask.contains(.editedCharacters), textView?.hasMarkedText() != true else { return }
            let ns = storage.string as NSString
            let editedLines = ns.lineRange(for: edited)
            let lines = ns.substring(with: editedLines)
            // Typing happens at the cursor, so the edited lines are the
            // revealed ones; a selection change right after corrects any
            // edit made elsewhere (undo, external changes).
            if textView?.isEditorFocused == true { revealedLines = editedLines }
            let fences = MarkdownSpans.fenceLineCount(storage.string)
            if fences != fenceLineCount || lines.contains("```") || lines.contains("~~~") {
                fenceLineCount = fences
                MarkdownStyler.restyle(storage, around: NSRange(
                    location: edited.location, length: storage.length - edited.location),
                    revealing: revealedLines)
            } else {
                MarkdownStyler.restyle(storage, around: edited, revealing: revealedLines)
            }
        }

        // MARK: External edits

        /// Replaces only the part of the text that differs, as one undoable
        /// edit, so the selection, scroll position, and undo history survive
        /// a file changing underneath the editor.
        func applyExternalText(_ text: String) {
            guard let textView, let storage = textView.textStorage else { return }
            let old = Array(textView.string.utf16)
            let new = Array(text.utf16)
            var prefix = 0
            while prefix < min(old.count, new.count), old[prefix] == new[prefix] { prefix += 1 }
            var suffix = 0
            while suffix < min(old.count, new.count) - prefix,
                  old[old.count - 1 - suffix] == new[new.count - 1 - suffix] { suffix += 1 }
            // Don't split a surrogate pair.
            if prefix > 0, UTF16.isLeadSurrogate(old[prefix - 1]) { prefix -= 1 }
            if suffix > 0, UTF16.isTrailSurrogate(old[old.count - suffix]) { suffix -= 1 }

            let range = NSRange(location: prefix, length: old.count - prefix - suffix)
            let replacement = String(utf16CodeUnits: Array(new[prefix..<(new.count - suffix)]),
                                     count: new.count - prefix - suffix)
            let delta = (replacement as NSString).length - range.length

            var selection = textView.selectedRange()
            if selection.location >= NSMaxRange(range) {
                selection.location += delta
            } else if NSMaxRange(selection) > range.location {
                selection = NSRange(location: min(selection.location, range.location + (replacement as NSString).length), length: 0)
            }

            isApplyingExternalText = true
            defer { isApplyingExternalText = false }
            if textView.shouldChangeText(in: range, replacementString: replacement) {
                storage.replaceCharacters(in: range, with: replacement)
                textView.didChangeText()
            } else {
                textView.string = text
                styleAll()
            }
            let length = (textView.string as NSString).length
            textView.setSelectedRange(NSRange(location: min(selection.location, length),
                                              length: min(selection.length, length - min(selection.location, length))))
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

    /// Focus drives Live Preview: without focus every line is rendered.
    private(set) var isEditorFocused = false
    var onFocusChange: (() -> Void)?

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted {
            isEditorFocused = true
            onFocusChange?()
        }
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        let accepted = super.resignFirstResponder()
        if accepted {
            isEditorFocused = false
            onFocusChange?()
        }
        return accepted
    }

    // MARK: Live Preview decorations

    /// Quote bars, code block backgrounds, and horizontal rules, drawn
    /// behind the text for lines tagged by `MarkdownStyler`.
    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        guard let layoutManager, let textContainer, let storage = textStorage else { return }
        let origin = textContainerOrigin
        let visible = rect.offsetBy(dx: -origin.x, dy: -origin.y)
        let glyphs = layoutManager.glyphRange(forBoundingRect: visible, in: textContainer)
        let characters = layoutManager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        let width = textContainer.size.width

        func lineRects(_ range: NSRange) -> [NSRect] {
            var rects: [NSRect] = []
            let glyphRange = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            layoutManager.enumerateLineFragments(forGlyphRange: glyphRange) { lineRect, _, _, _, _ in
                rects.append(lineRect.offsetBy(dx: origin.x, dy: origin.y))
            }
            return rects
        }

        storage.enumerateAttribute(.livePreviewCodeBlock, in: characters) { value, range, _ in
            guard value != nil else { return }
            let rects = lineRects(range)
            guard let first = rects.first, let last = rects.last else { return }
            let block = NSRect(x: origin.x, y: first.minY, width: width, height: last.maxY - first.minY)
            NSColor.quaternaryLabelColor.withAlphaComponent(0.08).setFill()
            NSBezierPath(roundedRect: block, xRadius: 6, yRadius: 6).fill()
        }
        storage.enumerateAttribute(.livePreviewQuote, in: characters) { value, range, _ in
            guard value != nil else { return }
            NSColor.controlAccentColor.withAlphaComponent(0.6).setFill()
            for line in lineRects(range) {
                NSRect(x: origin.x + 5, y: line.minY + 2, width: 3, height: line.height - 4).fill()
            }
        }
        storage.enumerateAttribute(.livePreviewCheckbox, in: characters) { value, range, _ in
            guard let checked = value as? Bool, let rect = checkboxRect(forCharacterAt: range.location)
            else { return }
            let configuration = NSImage.SymbolConfiguration(pointSize: Self.checkboxSize, weight: .regular)
                .applying(.init(paletteColors: [checked ? .controlAccentColor : .secondaryLabelColor]))
            let symbol = NSImage(systemSymbolName: checked ? "checkmark.square.fill" : "square",
                                 accessibilityDescription: checked ? "Done" : "To do")?
                .withSymbolConfiguration(configuration)
            symbol?.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1,
                         respectFlipped: true, hints: nil)
        }
        storage.enumerateAttribute(.livePreviewRule, in: characters) { value, range, _ in
            guard value != nil else { return }
            NSColor.separatorColor.setFill()
            for line in lineRects(range) {
                NSRect(x: origin.x + 5, y: line.midY.rounded(), width: width - 10, height: 1).fill()
            }
        }
    }

    /// Sizes the header to the view's width and reserves room for it. NSTextView
    /// pads top and bottom by the same `textContainerInset.height`, so the
    /// inset grows by half the header and `textContainerOrigin` shifts the
    /// text down by the rest — leaving the usual padding at the bottom.
    func layoutHeader() {
        header?.frame.size.width = bounds.width  // wrapped warnings depend on width
        let height = header?.preferredHeight ?? 0
        header?.frame = NSRect(x: 0, y: 0, width: bounds.width, height: height)
        header?.needsLayout = true
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
        layoutHeader()
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
        textView.linkTextAttributes = [
            .foregroundColor: NSColor.controlAccentColor,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
            .cursor: NSCursor.pointingHand,
        ]
        textView.drawsBackground = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(
            width: 0, height: CGFloat.greatestFiniteMagnitude)
        return textView
    }

    // MARK: List editing (SeanboyCore.ListEditing)

    /// Applies a list rule's edit as one undoable change. Nil means the rule
    /// doesn't apply, and the caller falls back to the normal behavior.
    private func perform(_ edit: ListEditing.Edit?) -> Bool {
        guard let edit, !hasMarkedText() else { return false }
        if edit.range.length > 0 || !edit.replacement.isEmpty {
            guard shouldChangeText(in: edit.range, replacementString: edit.replacement) else { return true }
            replaceCharacters(in: edit.range, with: edit.replacement)
            didChangeText()
        }
        setSelectedRange(edit.selection)
        scrollRangeToVisible(edit.selection)
        return true
    }

    override func insertNewline(_ sender: Any?) {
        if !perform(ListEditing.enter(string, selection: selectedRange())) { super.insertNewline(sender) }
    }

    override func insertTab(_ sender: Any?) {
        if !perform(ListEditing.indent(string, selection: selectedRange(), outdent: false)) {
            super.insertTab(sender)
        }
    }

    override func insertBacktab(_ sender: Any?) {
        if !perform(ListEditing.indent(string, selection: selectedRange(), outdent: true)) {
            super.insertBacktab(sender)
        }
    }

    override func deleteBackward(_ sender: Any?) {
        if !perform(ListEditing.backspace(string, selection: selectedRange())) { super.deleteBackward(sender) }
    }

    override func moveToBeginningOfLine(_ sender: Any?) {
        if !moveToListItemStart() { super.moveToBeginningOfLine(sender) }
    }

    override func moveToLeftEndOfLine(_ sender: Any?) {
        if !moveToListItemStart() { super.moveToLeftEndOfLine(sender) }
    }

    /// Home/⌘← stops at the start of a list item's text first.
    private func moveToListItemStart() -> Bool {
        guard selectedRange().length == 0,
              let target = ListEditing.lineStart(string, caret: selectedRange().location) else { return false }
        setSelectedRange(NSRange(location: target, length: 0))
        return true
    }

    // MARK: Checkboxes

    static let checkboxSize: CGFloat = 14

    /// Where the checkbox for the task marker at `index` is drawn.
    func checkboxRect(forCharacterAt index: Int) -> NSRect? {
        guard let layoutManager, let textContainer else { return nil }
        let glyphs = layoutManager.glyphRange(forCharacterRange: NSRange(location: index, length: 1),
                                              actualCharacterRange: nil)
        guard glyphs.length > 0 else { return nil }
        let glyphRect = layoutManager.boundingRect(forGlyphRange: glyphs, in: textContainer)
        let line = layoutManager.lineFragmentUsedRect(forGlyphAt: glyphs.location, effectiveRange: nil)
        let size = Self.checkboxSize
        let origin = textContainerOrigin
        return NSRect(x: glyphRect.minX + origin.x + 1,
                      y: line.midY + origin.y - size / 2,
                      width: size, height: size)
    }

    /// Clicking a rendered checkbox toggles it without moving the cursor.
    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let index = checkboxIndex(at: point) {
            let selection = selectedRange()
            if perform(ListEditing.toggleTask(string, at: index)) {
                setSelectedRange(selection)
                return
            }
        }
        super.mouseDown(with: event)
    }

    private func checkboxIndex(at point: NSPoint) -> Int? {
        guard let layoutManager, let textContainer, let storage = textStorage, storage.length > 0 else { return nil }
        let origin = textContainerOrigin
        let index = layoutManager.characterIndex(
            for: NSPoint(x: point.x - origin.x, y: point.y - origin.y),
            in: textContainer, fractionOfDistanceBetweenInsertionPoints: nil)
        let line = (string as NSString).lineRange(for: NSRange(location: min(index, storage.length), length: 0))
        var hit: Int?
        storage.enumerateAttribute(.livePreviewCheckbox, in: line) { value, range, stop in
            guard value != nil, let rect = checkboxRect(forCharacterAt: range.location),
                  rect.insetBy(dx: -4, dy: -4).contains(point) else { return }
            hit = range.location
            stop.pointee = true
        }
        return hit
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

/// Obsidian-style inline title: a large accent-colored field above the note
/// body. Keystrokes report through `onEdit` (the view model debounces the
/// rename); leaving the field fires `onCommit`; Enter, ↓, or Tab move to the
/// body via `onExit`.
final class InlineTitleHeader: NSView, NSTextFieldDelegate, NSTextViewDelegate {
    let field = NSTextField()
    private let warning = NSTextField(wrappingLabelWithString: "")
    var onEdit: ((String) -> Void)?
    var onCommit: (() -> Void)?
    var onExit: (() -> Void)?
    var wantsInitialFocus = false

    // Properties row: the note's unmanaged frontmatter (Obsidian tags,
    // aliases, …). Collapsed it's one faded line of keys; expanded it's a
    // raw YAML editor. Hidden when the note has none.
    let propertiesToggle = NSButton()
    let propertiesEditor = NSTextView()
    private let propertiesWarning = NSTextField(wrappingLabelWithString: "")
    private(set) var propertiesExpanded = false
    var onPropertiesEdit: ((String) -> Void)?
    var onPropertiesCommit: (() -> Void)?
    /// The header's height changed; the text view must re-reserve room.
    var onHeightChange: (() -> Void)?

    /// Aligns the title's first glyph with the body text: text container
    /// inset plus the line fragment padding, minus the field cell's own inset.
    private static let leading = MarkdownTextView.bodyInset.width + 5 - 2
    private static let top: CGFloat = 16
    private static let gap: CGFloat = 4
    private static let editorInset = NSSize(width: 6, height: 6)

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

        for label in [warning, propertiesWarning] {
            label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            label.textColor = .systemOrange
            label.isHidden = true
            addSubview(label)
        }

        propertiesToggle.isBordered = false
        propertiesToggle.imagePosition = .imageLeading
        propertiesToggle.alignment = .left
        propertiesToggle.target = self
        propertiesToggle.action = #selector(toggleProperties)
        propertiesToggle.isHidden = true
        addSubview(propertiesToggle)

        propertiesEditor.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        propertiesEditor.textColor = .secondaryLabelColor
        propertiesEditor.isRichText = false
        propertiesEditor.allowsUndo = true
        propertiesEditor.isAutomaticQuoteSubstitutionEnabled = false
        propertiesEditor.isAutomaticDashSubstitutionEnabled = false
        propertiesEditor.isAutomaticTextReplacementEnabled = false
        propertiesEditor.isAutomaticSpellingCorrectionEnabled = false
        propertiesEditor.textContainerInset = Self.editorInset
        propertiesEditor.textContainer?.widthTracksTextView = true
        propertiesEditor.backgroundColor = NSColor.quaternaryLabelColor.withAlphaComponent(0.08)
        propertiesEditor.wantsLayer = true
        propertiesEditor.layer?.cornerRadius = 6
        propertiesEditor.delegate = self
        propertiesEditor.isHidden = true
        propertiesEditor.setAccessibilityLabel("Properties")
        addSubview(propertiesEditor)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private var contentWidth: CGFloat { max(200, bounds.width - Self.leading * 2) }

    private func height(of label: NSTextField) -> CGFloat {
        label.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: contentWidth, height: .greatestFiniteMagnitude)).height ?? 0
    }

    private var editorHeight: CGFloat {
        guard let layoutManager = propertiesEditor.layoutManager,
              let container = propertiesEditor.textContainer else { return 0 }
        container.containerSize = NSSize(width: contentWidth - Self.editorInset.width * 2,
                                         height: .greatestFiniteMagnitude)
        layoutManager.ensureLayout(for: container)
        let used = max(layoutManager.usedRect(for: container).height,
                       propertiesEditor.font?.boundingRectForFont.height ?? 14)
        return ceil(used) + Self.editorInset.height * 2
    }

    var preferredHeight: CGFloat {
        var height = Self.top + field.intrinsicContentSize.height
        if !warning.isHidden { height += Self.gap + self.height(of: warning) }
        if !propertiesToggle.isHidden { height += Self.gap + propertiesToggle.intrinsicContentSize.height }
        if !propertiesEditor.isHidden { height += Self.gap + editorHeight }
        if !propertiesWarning.isHidden { height += Self.gap + self.height(of: propertiesWarning) }
        return height
    }

    func setWarning(_ message: String?) {
        warning.stringValue = message ?? ""
        warning.isHidden = message == nil
        needsLayout = true
    }

    /// Updates the Properties row. The editor's text is never replaced while
    /// the user is typing in it.
    func setProperties(_ text: String, warning message: String?) {
        let editing = window?.firstResponder === propertiesEditor
        if !editing, propertiesEditor.string != text { propertiesEditor.string = text }
        let current = editing ? propertiesEditor.string : text
        // Hidden when there's nothing to show — unless open or being fixed.
        let hasProperties = !current.isEmpty || propertiesExpanded || message != nil
        propertiesToggle.isHidden = !hasProperties
        propertiesEditor.isHidden = !(hasProperties && propertiesExpanded)
        propertiesWarning.stringValue = message ?? ""
        propertiesWarning.isHidden = message == nil
        updateToggleTitle(keys: NoteDocument.propertyKeys(current.components(separatedBy: "\n")))
        needsLayout = true
    }

    private func updateToggleTitle(keys: [String]) {
        let symbol = propertiesExpanded ? "chevron.down" : "chevron.right"
        propertiesToggle.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 9, weight: .semibold))
        propertiesToggle.contentTintColor = .tertiaryLabelColor
        let summary = propertiesExpanded || keys.isEmpty ? "Properties" : "Properties  ·  " + keys.joined(separator: " · ")
        propertiesToggle.attributedTitle = NSAttributedString(string: " " + summary, attributes: [
            .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
            .foregroundColor: NSColor.tertiaryLabelColor,
        ])
        propertiesToggle.setAccessibilityLabel(propertiesExpanded ? "Hide properties" : "Show properties")
    }

    @objc func toggleProperties() {
        propertiesExpanded.toggle()
        if !propertiesExpanded, window?.firstResponder === propertiesEditor {
            window?.makeFirstResponder(nil)  // commits via textDidEndEditing
        }
        setProperties(propertiesEditor.string, warning: propertiesWarning.isHidden ? nil : propertiesWarning.stringValue)
        onHeightChange?()
        if propertiesExpanded { window?.makeFirstResponder(propertiesEditor) }
    }

    override func layout() {
        super.layout()
        let width = contentWidth
        var y = Self.top
        let fieldHeight = field.intrinsicContentSize.height
        field.frame = NSRect(x: Self.leading, y: y, width: width, height: fieldHeight)
        y += fieldHeight
        if !warning.isHidden {
            y += Self.gap
            let h = height(of: warning)
            warning.frame = NSRect(x: Self.leading + 2, y: y, width: width, height: h)
            y += h
        }
        if !propertiesToggle.isHidden {
            y += Self.gap
            let size = propertiesToggle.intrinsicContentSize
            propertiesToggle.frame = NSRect(x: Self.leading + 1, y: y, width: min(size.width, width), height: size.height)
            y += size.height
        }
        if !propertiesEditor.isHidden {
            y += Self.gap
            let h = editorHeight
            propertiesEditor.frame = NSRect(x: Self.leading + 2, y: y, width: width - 2, height: h)
            y += h
        }
        if !propertiesWarning.isHidden {
            y += Self.gap
            propertiesWarning.frame = NSRect(x: Self.leading + 2, y: y, width: width,
                                             height: height(of: propertiesWarning))
        }
    }

    // MARK: Properties editor (NSTextViewDelegate)

    func textDidChange(_ notification: Notification) {
        guard notification.object as? NSTextView === propertiesEditor else { return }
        onPropertiesEdit?(propertiesEditor.string)
        updateToggleTitle(keys: NoteDocument.propertyKeys(propertiesEditor.string.components(separatedBy: "\n")))
        needsLayout = true
        onHeightChange?()
    }

    func textDidEndEditing(_ notification: Notification) {
        guard notification.object as? NSTextView === propertiesEditor else { return }
        onPropertiesCommit?()
    }

    /// YAML indents with spaces, so Tab inserts two.
    func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard textView === propertiesEditor, selector == #selector(NSResponder.insertTab(_:)) else { return false }
        textView.insertText("  ", replacementRange: textView.selectedRange())
        return true
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
