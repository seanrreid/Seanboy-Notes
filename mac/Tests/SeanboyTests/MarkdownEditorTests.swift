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
        textView.string = initial
        coordinator.styleAll()
        textView.textStorage?.delegate = coordinator
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

    func testBoldInsideHeadingKeepsHeadingSize() {
        makeEditor("# A **b**")
        XCTAssertTrue(isBold(6))
        XCTAssertEqual(font(at: 6)?.pointSize, 24)
    }
}
