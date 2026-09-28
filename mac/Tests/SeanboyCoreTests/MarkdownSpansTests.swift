import XCTest
@testable import SeanboyCore

/// Runs the platform-neutral fixtures in `shared/fixtures/markdown-spans.json`
/// (the Kotlin port runs the same file).
final class MarkdownSpansFixtureTests: XCTestCase {
    private struct Fixtures: Decodable {
        let cases: [Case]
    }

    private struct Case: Decodable {
        let name: String
        let input: String
        let spans: [Expected]
    }

    private struct Expected: Decodable, Equatable, CustomStringConvertible {
        let kind: String
        let text: String
        let content: String
        let markers: [String]
        var level: Int?
        var checked: Bool?
        var target: String?
        var start: Int?

        var description: String {
            var parts = ["\(kind) \(text.debugDescription) content=\(content.debugDescription) markers=\(markers)"]
            if let level { parts.append("level=\(level)") }
            if let checked { parts.append("checked=\(checked)") }
            if let target { parts.append("target=\(target.debugDescription)") }
            if let start { parts.append("start=\(start)") }
            return parts.joined(separator: " ")
        }
    }

    private static let fixtureURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // SeanboyCoreTests
        .deletingLastPathComponent()  // Tests
        .deletingLastPathComponent()  // mac
        .deletingLastPathComponent()  // repo root
        .appendingPathComponent("shared/fixtures/markdown-spans.json")

    private func describe(_ span: MarkdownSpan, in input: String, withStart: Bool) -> Expected {
        let ns = input as NSString
        return Expected(
            kind: span.kind.rawValue,
            text: ns.substring(with: span.range),
            content: ns.substring(with: span.content),
            markers: span.markers.map { ns.substring(with: $0) },
            level: span.level == 0 ? nil : span.level,
            checked: span.checked ? true : nil,
            target: span.target,
            start: withStart ? span.range.location : nil)
    }

    func testSharedFixtures() throws {
        let data = try Data(contentsOf: Self.fixtureURL)
        let fixtures = try JSONDecoder().decode(Fixtures.self, from: data)
        XCTAssertFalse(fixtures.cases.isEmpty)
        for fixture in fixtures.cases {
            let spans = MarkdownSpans.parse(fixture.input)
            guard spans.count == fixture.spans.count else {
                XCTFail("""
                \(fixture.name): expected \(fixture.spans.count) spans, got \(spans.count):
                \(spans.map { describe($0, in: fixture.input, withStart: true).description }.joined(separator: "\n"))
                """)
                continue
            }
            for (span, expected) in zip(spans, fixture.spans) {
                let actual = describe(span, in: fixture.input, withStart: expected.start != nil)
                XCTAssertEqual(actual, expected, fixture.name)
            }
        }
    }

    func testEmptyInput() {
        XCTAssertEqual(MarkdownSpans.parse(""), [])
    }

    /// Guards the per-keystroke budget before incremental styling lands.
    func testLargeNotePerformance() {
        let paragraph = """
        # Heading with **bold**
        - item with [[Link]] and `code`
        - [ ] task with ==highlight== and https://example.com
        > a quote with *italic*
        Plain text line that goes on for a while without any syntax at all.

        """
        let note = String(repeating: paragraph, count: 1_000)  // ~6,000 lines
        measure { _ = MarkdownSpans.parse(note) }
    }
}
