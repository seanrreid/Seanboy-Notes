import XCTest
@testable import TomboyCore

final class WikiLinkParserTests: XCTestCase {
    func testFindsLinks() {
        let text = "See [[Recipes]] and [[Shopping List]] for details."
        let links = WikiLinkParser.links(in: text)
        XCTAssertEqual(links.map(\.title), ["Recipes", "Shopping List"])
        XCTAssertEqual(String(text[links[0].range]), "[[Recipes]]")
    }

    func testTrimsAndSkipsEmpty() {
        let links = WikiLinkParser.links(in: "[[  Padded  ]] [[   ]] [[]]")
        XCTAssertEqual(links.map(\.title), ["Padded"])
    }

    func testNoNestingOrNewlines() {
        XCTAssertTrue(WikiLinkParser.links(in: "[[a\nb]]").isEmpty)
        XCTAssertEqual(WikiLinkParser.links(in: "[[[Extra]]").map(\.title), ["Extra"])
    }

    func testLinkedTitlesDedupesCaseInsensitively() {
        let titles = WikiLinkParser.linkedTitles(in: "[[Ideas]] then [[ideas]] then [[Other]]")
        XCTAssertEqual(titles, ["Ideas", "Other"])
    }

    func testBacklinks() {
        let a = Note(title: "A", body: "links to [[B]]")
        let b = Note(title: "B", body: "no links")
        let c = Note(title: "C", body: "also [[b]] here")
        var d = Note(title: "D", body: "[[B]] but deleted")
        d.isDeleted = true
        let backs = WikiLinkParser.backlinks(to: "B", in: [a, b, c, d])
        XCTAssertEqual(backs.map(\.title), ["A", "C"])
    }
}

final class SearchServiceTests: XCTestCase {
    private let notes = [
        Note(title: "Swift Concurrency", body: "actors and tasks",
             modifiedAt: Date(timeIntervalSince1970: 300)),
        Note(title: "Groceries", body: "milk, eggs, swift delivery",
             modifiedAt: Date(timeIntervalSince1970: 200)),
        Note(title: "Old Ideas", body: "nothing relevant",
             modifiedAt: Date(timeIntervalSince1970: 100)),
    ]

    func testEmptyQueryReturnsAllByRecency() {
        let results = SearchService.search("  ", in: notes)
        XCTAssertEqual(results.map(\.title), ["Swift Concurrency", "Groceries", "Old Ideas"])
    }

    func testTitleMatchOutranksBodyMatch() {
        let results = SearchService.search("swift", in: notes)
        XCTAssertEqual(results.map(\.title), ["Swift Concurrency", "Groceries"])
    }

    func testAllTermsMustMatch() {
        let results = SearchService.search("swift milk", in: notes)
        XCTAssertEqual(results.map(\.title), ["Groceries"])
    }

    func testNoMatches() {
        XCTAssertTrue(SearchService.search("zzz", in: notes).isEmpty)
    }
}
