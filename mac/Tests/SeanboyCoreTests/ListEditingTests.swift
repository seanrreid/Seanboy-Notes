import XCTest
@testable import SeanboyCore

/// Runs `shared/fixtures/list-editing.json` (the Kotlin port runs it too).
final class ListEditingFixtureTests: XCTestCase {
    private struct Fixtures: Decodable { let cases: [Case] }
    private struct Case: Decodable {
        let name: String
        let action: String
        let before: String
        let after: String?
    }

    private static let fixtureURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("shared/fixtures/list-editing.json")

    /// "a|b" → ("ab", caret 1); "«ab»" → ("ab", selection 0..2).
    private func decode(_ marked: String) -> (String, NSRange) {
        var text = ""
        var start = 0, end: Int?
        for character in marked {
            switch character {
            case "|": start = (text as NSString).length
            case "«": start = (text as NSString).length
            case "»": end = (text as NSString).length
            default: text.append(character)
            }
        }
        return (text, NSRange(location: start, length: (end ?? start) - start))
    }

    private func encode(_ text: String, _ selection: NSRange) -> String {
        let ns = text as NSString
        let head = ns.substring(to: selection.location)
        if selection.length == 0 { return head + "|" + ns.substring(from: selection.location) }
        return head + "«" + ns.substring(with: selection) + "»" + ns.substring(from: NSMaxRange(selection))
    }

    private func run(_ action: String, _ text: String, _ selection: NSRange) -> (String, NSRange)? {
        let edit: ListEditing.Edit?
        switch action {
        case "enter": edit = ListEditing.enter(text, selection: selection)
        case "tab": edit = ListEditing.indent(text, selection: selection, outdent: false)
        case "shiftTab": edit = ListEditing.indent(text, selection: selection, outdent: true)
        case "backspace": edit = ListEditing.backspace(text, selection: selection)
        case "toggle": edit = ListEditing.toggleTask(text, at: selection.location)
        case "home":
            return ListEditing.lineStart(text, caret: selection.location)
                .map { (text, NSRange(location: $0, length: 0)) }
        default:
            XCTFail("unknown action \(action)")
            return nil
        }
        guard let edit else { return nil }
        let result = (text as NSString).replacingCharacters(in: edit.range, with: edit.replacement)
        return (result, edit.selection)
    }

    func testSharedFixtures() throws {
        let fixtures = try JSONDecoder().decode(Fixtures.self, from: Data(contentsOf: Self.fixtureURL))
        XCTAssertFalse(fixtures.cases.isEmpty)
        for fixture in fixtures.cases {
            let (text, selection) = decode(fixture.before)
            let result = run(fixture.action, text, selection).map { encode($0.0, $0.1) }
            XCTAssertEqual(result, fixture.after, fixture.name)
        }
    }
}
