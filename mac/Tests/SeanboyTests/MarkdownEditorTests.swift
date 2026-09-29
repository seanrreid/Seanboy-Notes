import AppKit
import SwiftUI
import XCTest
@testable import Seanboy

/// Drives the real editor text view and coordinator without a window.
@MainActor
final class MarkdownEditorTests: XCTestCase {
    private var text = ""
    private var textView: MarkdownTextView!
    private var coordinator: MarkdownEditor.Coordinator!

    private func makeEditor(_ initial: String) {
        text = initial
        let editor = MarkdownEditor(
            text: Binding(get: { self.text }, set: { self.text = $0 }),
            title: "", titleWarning: nil, focusTitle: false,
            onTitleEdit: { _ in }, onTitleCommit: {}, onOpenWikiLink: { _ in })
        coordinator = editor.makeCoordinator()
        textView = MarkdownTextView.make()
        textView.delegate = coordinator
        coordinator.textView = textView
        textView.layoutManager?.delegate = coordinator.layout
        textView.onFocusChange = { [weak coordinator] in coordinator?.updateRevealedLines() }
        textView.string = initial
        coordinator.styleAll()
        textView.textStorage?.delegate = coordinator
    }

    private var window: NSWindow?

    /// Puts the editor in an offscreen window and focuses it, cursor at `location`.
    private func focus(at location: Int) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: true)
        textView.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        window.contentView = textView
        self.window = window
        textView.setSelectedRange(NSRange(location: location, length: 0))
        XCTAssertTrue(window.makeFirstResponder(textView))
    }

    private func isHidden(_ index: Int) -> Bool {
        textView.textStorage?.attribute(.livePreviewHidden, at: index, effectiveRange: nil) != nil
    }

    private func glyphIsNull(_ index: Int) -> Bool {
        let layoutManager = textView.layoutManager!
        layoutManager.ensureGlyphs(forCharacterRange: NSRange(location: 0, length: textView.string.utf16.count))
        let glyph = layoutManager.glyphIndexForCharacter(at: index)
        return layoutManager.propertyForGlyph(at: glyph).contains(.null)
    }

    private func type(_ string: String, at location: Int? = nil) {
        if let location { textView.setSelectedRange(NSRange(location: location, length: 0)) }
        for character in string { textView.insertText(String(character), replacementRange: textView.selectedRange()) }
    }

    private func font(at index: Int) -> NSFont? {
        textView.textStorage?.attribute(.font, at: index, effectiveRange: nil) as? NSFont
    }

    private func isBold(_ index: Int) -> Bool {
        font(at: index)?.fontDescriptor.symbolicTraits.contains(.bold) == true
    }

    private func isMonospaced(_ index: Int) -> Bool {
        font(at: index)?.fontDescriptor.symbolicTraits.contains(.monoSpace) == true
    }

    func testTypingStylesIncrementallyAndUpdatesBinding() {
        makeEditor("start\n")
        type("a **bold** b", at: 6)
        XCTAssertEqual(text, "start\na **bold** b")
        XCTAssertTrue(isBold(6 + 4), "content of **bold** is bold")
        XCTAssertFalse(isBold(6), "text before stays regular")
        XCTAssertFalse(isBold(0), "other lines untouched")
    }

    func testUnclosingBoldRemovesStyle() {
        makeEditor("x **bold**")
        XCTAssertTrue(isBold(4))
        textView.setSelectedRange(NSRange(location: 9, length: 1))
        textView.deleteBackward(nil)
        XCTAssertEqual(text, "x **bold*")
        XCTAssertFalse(isBold(4))
    }

    func testOpeningAndClosingFenceRestylesBelow() {
        makeEditor("intro\nlet x = 1\nlast line")
        XCTAssertFalse(isMonospaced(8))
        type("```\n", at: 6)  // everything below becomes an unclosed code block
        XCTAssertTrue(isMonospaced(6 + 4 + 2), "line below the new fence is code")
        XCTAssertTrue(isMonospaced((textView.string as NSString).length - 1), "to the end")

        // Delete the fence again: the lines below go back to normal.
        textView.setSelectedRange(NSRange(location: 6, length: 4))
        textView.deleteBackward(nil)
        XCTAssertEqual(text, "intro\nlet x = 1\nlast line")
        XCTAssertFalse(isMonospaced(8))
        XCTAssertFalse(isMonospaced((textView.string as NSString).length - 1))
    }

    func testExternalInsertBeforeSelectionShiftsIt() {
        makeEditor("alpha\nbeta\ngamma")
        textView.setSelectedRange(NSRange(location: 13, length: 2))  // "mm"
        coordinator.applyExternalText("NEW alpha\nbeta\ngamma")
        XCTAssertEqual(textView.string, "NEW alpha\nbeta\ngamma")
        XCTAssertEqual(textView.selectedRange(), NSRange(location: 17, length: 2))
        XCTAssertEqual(text, "alpha\nbeta\ngamma", "external text isn't echoed back to the binding")
    }

    func testExternalAppendAfterSelectionLeavesItAndStyles() {
        makeEditor("alpha\nbeta")
        textView.setSelectedRange(NSRange(location: 1, length: 3))
        coordinator.applyExternalText("alpha\nbeta **g**")
        XCTAssertEqual(textView.selectedRange(), NSRange(location: 1, length: 3))
        XCTAssertTrue(isBold(14), "externally added text is styled")
    }

    func testExternalEditDoesNotSplitSurrogatePairs() {
        makeEditor("a😀b")
        coordinator.applyExternalText("a😁b")
        XCTAssertEqual(textView.string, "a😁b")
    }

    func testWikiLinkAndURLAreLinks() {
        makeEditor("[[Ideas]] and https://example.com")
        let storage = textView.textStorage!
        XCTAssertEqual((storage.attribute(.link, at: 3, effectiveRange: nil) as? URL)?.absoluteString,
                       "seanboy://Ideas")
        XCTAssertEqual((storage.attribute(.link, at: 16, effectiveRange: nil) as? URL)?.absoluteString,
                       "https://example.com")
    }

    // MARK: Live Preview

    func testUnfocusedEditorRendersEveryLine() {
        makeEditor("# Title\n**bold** and [[Link]]")
        XCTAssertTrue(isHidden(0), "# hidden")
        XCTAssertTrue(isHidden(8) && isHidden(9), "** hidden")
        XCTAssertFalse(isHidden(10), "bold content visible")
        XCTAssertTrue(isHidden(21) && isHidden(22), "[[ hidden")
        XCTAssertTrue(glyphIsNull(0), "hidden markers become null glyphs")
        XCTAssertFalse(glyphIsNull(2))
    }

    func testCursorLineRevealsOnlyItsMarkers() {
        makeEditor("**one**\n**two**")
        focus(at: 10)  // inside "two"
        XCTAssertTrue(isHidden(0), "other line still rendered")
        XCTAssertFalse(isHidden(8), "cursor line shows its markers")
        XCTAssertFalse(glyphIsNull(8))

        textView.setSelectedRange(NSRange(location: 2, length: 0))  // move to line 1
        XCTAssertFalse(isHidden(0))
        XCTAssertTrue(isHidden(8), "the old cursor line is rendered again")
    }

    func testSelectionRevealsEveryLineItTouches() {
        makeEditor("**a**\n**b**\n**c**")
        focus(at: 0)
        textView.setSelectedRange(NSRange(location: 2, length: 7))  // from line 1 into line 2
        XCTAssertFalse(isHidden(0))
        XCTAssertFalse(isHidden(6))
        XCTAssertTrue(isHidden(12))
    }

    func testLosingFocusRendersTheCursorLine() {
        makeEditor("**one**")
        focus(at: 3)
        XCTAssertFalse(isHidden(0))
        window?.makeFirstResponder(nil)
        XCTAssertTrue(isHidden(0))
    }

    func testTypingOnTheCursorLineKeepsMarkersVisible() {
        makeEditor("")
        focus(at: 0)
        type("**hi**")
        XCTAssertEqual(text, "**hi**")
        XCTAssertFalse(isHidden(0))
        type("\nnext")
        XCTAssertTrue(isHidden(0), "leaving the line renders it")
    }

    func testCodeBlockFencesShowOnlyWithCursorInside() {
        makeEditor("```\ncode\n```\nafter")
        focus(at: 16)  // "after"
        XCTAssertTrue(isHidden(0) && isHidden(9), "fences hidden")
        textView.setSelectedRange(NSRange(location: 5, length: 0))  // inside the block
        XCTAssertFalse(isHidden(0))
        XCTAssertFalse(isHidden(9), "both fences show when the cursor is anywhere in the block")
    }

    func testBulletsAlwaysRenderAsBulletGlyph() {
        makeEditor("- item")
        focus(at: 3)
        let storage = textView.textStorage!
        XCTAssertNotNil(storage.attribute(.livePreviewBullet, at: 0, effectiveRange: nil))
        XCTAssertEqual(storage.string, "- item", "file text keeps the dash")
        let layoutManager = textView.layoutManager!
        layoutManager.ensureGlyphs(forCharacterRange: NSRange(location: 0, length: 6))
        let font = storage.attribute(.font, at: 0, effectiveRange: nil) as! NSFont
        var dash: UniChar = 0x2D, dashGlyph: CGGlyph = 0
        CTFontGetGlyphsForCharacters(font as CTFont, &dash, &dashGlyph, 1)
        XCTAssertNotEqual(layoutManager.cgGlyph(at: 0), dashGlyph)
    }

    // MARK: Lists and checkboxes

    func testEnterContinuesAndEndsLists() {
        makeEditor("- milk")
        focus(at: 6)
        textView.insertNewline(nil)
        XCTAssertEqual(text, "- milk\n- ")
        textView.insertNewline(nil)  // empty item ends the list
        XCTAssertEqual(text, "- milk\n")
        XCTAssertEqual(textView.selectedRange(), NSRange(location: 7, length: 0))
    }

    func testTabIndentsAndUndoRestores() throws {
        makeEditor("- a\n- b")
        focus(at: 7)
        let undo = try XCTUnwrap(textView.undoManager)
        undo.groupsByEvent = false  // no event loop in tests
        func step(_ action: () -> Void) {
            undo.beginUndoGrouping(); action(); undo.endUndoGrouping()
        }
        step { textView.insertTab(nil) }
        XCTAssertEqual(text, "- a\n\t- b")
        step { textView.insertBacktab(nil) }
        XCTAssertEqual(text, "- a\n- b")
        step { textView.insertTab(nil) }
        undo.undo()
        XCTAssertEqual(textView.string, "- a\n- b", "list edits are undoable")
    }

    func testTabOutsideListInsertsTab() {
        makeEditor("plain")
        focus(at: 5)
        textView.insertTab(nil)
        XCTAssertEqual(text, "plain\t")
    }

    func testBackspaceAfterMarkerRemovesIt() {
        makeEditor("- text")
        focus(at: 2)
        textView.deleteBackward(nil)
        XCTAssertEqual(text, "text")
    }

    func testHomeStopsAtItemText() {
        makeEditor("- some text")
        focus(at: 8)
        textView.moveToBeginningOfLine(nil)
        XCTAssertEqual(textView.selectedRange().location, 2)
        textView.moveToBeginningOfLine(nil)
        XCTAssertEqual(textView.selectedRange().location, 0)
    }

    func testRenderedTaskCollapsesToCheckboxAndClickToggles() {
        makeEditor("- [ ] buy milk\nother")
        focus(at: 17)  // cursor on "other", so the task line renders
        let storage = textView.textStorage!
        XCTAssertTrue(isHidden(0) && isHidden(1) && isHidden(2) && isHidden(4), "- [ and ] hidden")
        XCTAssertEqual(storage.attribute(.livePreviewCheckbox, at: 3, effectiveRange: nil) as? Bool, false)
        XCTAssertFalse(isHidden(5), "gap before the text stays")

        let rect = try! XCTUnwrap(textView.checkboxRect(forCharacterAt: 3))
        let click = NSEvent.mouseEvent(
            with: .leftMouseDown, location: textView.convert(NSPoint(x: rect.midX, y: rect.midY), to: nil),
            modifierFlags: [], timestamp: 0, windowNumber: window!.windowNumber, context: nil,
            eventNumber: 0, clickCount: 1, pressure: 1)!
        textView.mouseDown(with: click)
        XCTAssertEqual(text, "- [x] buy milk\nother")
        XCTAssertEqual(textView.selectedRange(), NSRange(location: 17, length: 0), "click doesn't move the cursor")
        XCTAssertEqual(storage.attribute(.livePreviewCheckbox, at: 3, effectiveRange: nil) as? Bool, true)
    }

    func testTaskOnCursorLineShowsRawMarker() {
        makeEditor("- [ ] buy milk")
        focus(at: 8)
        XCTAssertFalse(isHidden(0))
        XCTAssertNil(textView.textStorage!.attribute(.livePreviewCheckbox, at: 3, effectiveRange: nil))
    }

    func testBoldInsideHeadingKeepsHeadingSize() {
        makeEditor("# A **b**")
        XCTAssertTrue(isBold(6))
        XCTAssertEqual(font(at: 6)?.pointSize, 24)
    }
}
