import AppKit
import XCTest
@testable import Seanboy

/// The inline title + Properties row, hosted in a real editor text view.
@MainActor
final class InlineHeaderTests: XCTestCase {
    private var window: NSWindow!
    private var textView: MarkdownTextView!
    private var header: InlineTitleHeader!
    private var edits: [String] = []
    private var commits = 0

    override func setUp() async throws {
        textView = MarkdownTextView.make()
        textView.string = "Body"
        header = InlineTitleHeader()
        header.field.stringValue = "Daily"
        header.onPropertiesEdit = { [unowned self] in edits.append($0) }
        header.onPropertiesCommit = { [unowned self] in commits += 1 }
        header.onHeightChange = { [unowned self] in textView.layoutHeader() }
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
                          styleMask: [.titled], backing: .buffered, defer: true)
        textView.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        window.contentView = textView
        textView.header = header
    }

    private func refresh(_ text: String, warning: String? = nil) {
        header.setProperties(text, warning: warning)
        textView.layoutHeader()
        header.layoutSubtreeIfNeeded()
    }

    private var toggleTitle: String { header.propertiesToggle.attributedTitle.string }

    func testNoPropertiesHidesTheRow() {
        let titleOnly = header.preferredHeight
        refresh("")
        XCTAssertTrue(header.propertiesToggle.isHidden)
        XCTAssertTrue(header.propertiesEditor.isHidden)
        XCTAssertEqual(header.preferredHeight, titleOnly)
    }

    func testCollapsedRowSummarizesKeys() {
        refresh("tags:\n  - journal\naliases: [JRN]")
        XCTAssertFalse(header.propertiesToggle.isHidden)
        XCTAssertTrue(header.propertiesEditor.isHidden, "collapsed by default")
        XCTAssertTrue(toggleTitle.contains("Properties  ·  tags · aliases"), toggleTitle)
    }

    func testExpandingShowsEditorAndPushesBodyDown() {
        refresh("tags: [a]\nstatus: draft")
        let collapsedOrigin = textView.textContainerOrigin.y
        header.toggleProperties()
        header.layoutSubtreeIfNeeded()
        XCTAssertFalse(header.propertiesEditor.isHidden)
        XCTAssertEqual(header.propertiesEditor.string, "tags: [a]\nstatus: draft")
        XCTAssertGreaterThan(textView.textContainerOrigin.y, collapsedOrigin + 20,
                             "body text starts below the expanded editor")
        XCTAssertLessThanOrEqual(header.propertiesEditor.frame.maxY, header.frame.height + 0.5, "editor fits inside the header")
        XCTAssertTrue(window.firstResponder === header.propertiesEditor, "expanding focuses the editor")

        header.toggleProperties()
        XCTAssertTrue(header.propertiesEditor.isHidden)
        XCTAssertEqual(textView.textContainerOrigin.y, collapsedOrigin, accuracy: 0.5)
    }

    func testEditingReportsAndCommitsOnFocusOut() {
        refresh("tags: [a]")
        header.toggleProperties()
        header.propertiesEditor.setSelectedRange(NSRange(location: 9, length: 0))
        header.propertiesEditor.insertText("\nstatus: done", replacementRange: header.propertiesEditor.selectedRange())
        XCTAssertEqual(edits.last, "tags: [a]\nstatus: done")
        XCTAssertTrue(toggleTitle.contains("Properties"))

        // While typing, a model refresh must not clobber the editor.
        refresh("tags: [a]")
        XCTAssertEqual(header.propertiesEditor.string, "tags: [a]\nstatus: done")

        window.makeFirstResponder(textView)
        XCTAssertEqual(commits, 1, "leaving the editor commits")
    }

    func testTabInsertsSpaces() {
        refresh("tags:")
        header.toggleProperties()
        header.propertiesEditor.setSelectedRange(NSRange(location: 5, length: 0))
        header.propertiesEditor.insertNewline(nil)
        header.propertiesEditor.doCommand(by: #selector(NSResponder.insertTab(_:)))  // as a keypress does
        XCTAssertEqual(header.propertiesEditor.string, "tags:\n  ")
    }

    func testWarningShowsEvenWhenTextIsEmpty() {
        refresh("", warning: "Not saved")
        XCTAssertFalse(header.propertiesToggle.isHidden, "a rejected edit stays visible to fix")
        let withWarning = header.preferredHeight
        refresh("")
        XCTAssertLessThan(header.preferredHeight, withWarning)
    }
}
