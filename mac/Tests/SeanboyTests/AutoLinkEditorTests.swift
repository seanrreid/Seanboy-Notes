import AppKit
import SwiftUI
import XCTest
import SeanboyCore
@testable import Seanboy

/// Auto-links in the real editor text view (offscreen): other notes' titles
/// get a dotted underline, restyled as you type, and ⌘-click finds the title.
@MainActor
final class AutoLinkEditorTests: XCTestCase {
    private var text = ""
    private var opened: [String] = []
    private var textView: MarkdownTextView!
    private var coordinator: MarkdownEditor.Coordinator!
    private var window: NSWindow?

    private func makeEditor(_ initial: String, titles: [String]) {
        text = initial
        let editor = MarkdownEditor(
            text: Binding(get: { self.text }, set: { self.text = $0 }),
            title: "", titleWarning: nil, focusTitle: false,
            onTitleEdit: { _ in }, onTitleCommit: {}, onOpenWikiLink: { self.opened.append($0) })
        coordinator = editor.makeCoordinator()
        textView = MarkdownTextView.make()
        textView.delegate = coordinator
        coordinator.textView = textView
        textView.layoutManager?.delegate = coordinator.layout
        textView.onOpenAutoLink = { [weak coordinator] in coordinator?.parent.onOpenWikiLink($0) }
        textView.string = initial
        coordinator.autoLinks = AutoLinks(titles: titles)
        coordinator.styleAll()
        textView.textStorage?.delegate = coordinator
    }

    private func autoLink(at index: Int) -> String? {
        textView.textStorage?.attribute(.livePreviewAutoLink, at: index, effectiveRange: nil) as? String
    }

    func testOtherNotesTitlesAreUnderlined() {
        makeEditor("see Recipes and `Recipes`", titles: ["Recipes"])
        XCTAssertEqual(autoLink(at: 4), "Recipes")
        let style = textView.textStorage?.attribute(.underlineStyle, at: 4, effectiveRange: nil) as? Int
        XCTAssertEqual(style, NSUnderlineStyle.single.rawValue | NSUnderlineStyle.patternDot.rawValue)
        XCTAssertNil(autoLink(at: 18), "not inside inline code")
    }

    func testTypingATitleUnderlinesIt() {
        makeEditor("plain", titles: ["Journal"])
        textView.setSelectedRange(NSRange(location: 5, length: 0))
        for character in " journal" {
            textView.insertText(String(character), replacementRange: textView.selectedRange())
        }
        XCTAssertEqual(autoLink(at: 7), "Journal")
    }

    func testNoMatcherMeansNoUnderlines() {
        makeEditor("see Recipes", titles: ["Recipes"])
        coordinator.autoLinks = nil
        coordinator.styleAll()
        XCTAssertNil(autoLink(at: 4))
    }

    func testCommandClickTargetIsTheTitleUnderThePoint() {
        makeEditor("see Recipes today", titles: ["Recipes"])
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: true)
        textView.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        window.contentView = textView
        self.window = window
        let layoutManager = textView.layoutManager!
        let glyphs = layoutManager.glyphRange(forCharacterRange: NSRange(location: 6, length: 1), actualCharacterRange: nil)
        let rect = layoutManager.boundingRect(forGlyphRange: glyphs, in: textView.textContainer!)
        let origin = textView.textContainerOrigin
        let onTitle = NSPoint(x: rect.midX + origin.x, y: rect.midY + origin.y)
        XCTAssertEqual(textView.autoLinkTitle(at: onTitle), "Recipes")

        let before = layoutManager.boundingRect(
            forGlyphRange: layoutManager.glyphRange(forCharacterRange: NSRange(location: 1, length: 1), actualCharacterRange: nil),
            in: textView.textContainer!)
        XCTAssertNil(textView.autoLinkTitle(at: NSPoint(x: before.midX + origin.x, y: before.midY + origin.y)))
    }
}
