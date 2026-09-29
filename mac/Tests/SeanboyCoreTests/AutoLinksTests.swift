import XCTest
@testable import SeanboyCore

/// Runs `shared/fixtures/auto-links.json` (the Kotlin port runs it too).
final class AutoLinksFixtureTests: XCTestCase {
    private struct Fixtures: Decodable { let cases: [Case] }

    private struct Case: Decodable {
        let name: String
        let titles: [String]
        var current: String?
        let input: String
        let links: [Expected]
    }

    private struct Expected: Decodable, Equatable {
        let text: String
        let title: String
        var start: Int?
    }

    private static let fixtureURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("shared/fixtures/auto-links.json")

    func testSharedFixtures() throws {
        let fixtures = try JSONDecoder().decode(Fixtures.self, from: Data(contentsOf: Self.fixtureURL))
        XCTAssertFalse(fixtures.cases.isEmpty)
        for fixture in fixtures.cases {
            let ns = fixture.input as NSString
            let found = AutoLinks(titles: fixture.titles, current: fixture.current)
                .find(in: fixture.input, spans: MarkdownSpans.parse(fixture.input))
            guard found.count == fixture.links.count else {
                XCTFail("\(fixture.name): expected \(fixture.links), got \(found.map { (ns.substring(with: $0.range), $0.title, $0.range.location) })")
                continue
            }
            for (link, expected) in zip(found, fixture.links) {
                let actual = Expected(text: ns.substring(with: link.range), title: link.title,
                                      start: expected.start == nil ? nil : link.range.location)
                XCTAssertEqual(actual, expected, fixture.name)
            }
        }
    }

    func testFindWithinARangeMatchesTheFullSearch() {
        let text = "Recipes here\n`Recipes`\nmore Recipes and Journal"
        let ns = text as NSString
        let links = AutoLinks(titles: ["Recipes", "Journal"])
        let spans = MarkdownSpans.parse(text)
        let full = links.find(in: text, spans: spans)
        let thirdLine = ns.lineRange(for: NSRange(location: ns.length - 1, length: 0))
        XCTAssertEqual(links.find(in: text, spans: spans, range: thirdLine),
                       full.filter { $0.range.location >= thirdLine.location })
        XCTAssertEqual(full.count, 3)
    }
}
