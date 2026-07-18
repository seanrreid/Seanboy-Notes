import XCTest
@testable import SeanboyCore

final class SyncStateTests: XCTestCase {

    func testRoundTrip() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SeanboyTests-\(UUID().uuidString)")
        let url = directory.appendingPathComponent("syncstate.json")
        defer { try? FileManager.default.removeItem(at: directory) }

        var state = SyncState()
        let id = UUID()
        state[id] = .init(key: "notes/Round Trip.md", etag: "abc123",
                          modifiedAt: Date(timeIntervalSince1970: 1_750_000_000))
        try state.save(to: url)

        let loaded = SyncState.load(from: url)
        XCTAssertEqual(loaded[id]?.key, "notes/Round Trip.md")
        XCTAssertEqual(loaded[id]?.etag, "abc123")
        XCTAssertEqual(loaded[id]!.modifiedAt.timeIntervalSince1970,
                       1_750_000_000, accuracy: 1)
    }

    func testMissingFileLoadsEmpty() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("does-not-exist-\(UUID().uuidString).json")
        XCTAssertEqual(SyncState.load(from: url), SyncState())
    }

    func testListParserPagination() {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <ListBucketResult>
          <IsTruncated>true</IsTruncated>
          <NextContinuationToken>token==123</NextContinuationToken>
          <Contents>
            <Key>notes/Grocery List.md</Key>
            <ETag>&quot;abc&quot;</ETag>
            <Size>42</Size>
          </Contents>
          <Contents>
            <Key>notes/Ideas.md</Key>
            <ETag>&quot;def&quot;</ETag>
          </Contents>
        </ListBucketResult>
        """
        let page = ListResultParser.parse(Data(xml.utf8))
        XCTAssertEqual(page.objects, [
            S3Object(key: "notes/Grocery List.md", etag: "abc"),
            S3Object(key: "notes/Ideas.md", etag: "def"),
        ])
        XCTAssertEqual(page.nextContinuationToken, "token==123")
    }

    func testErrorParser() {
        let xml = """
        <Error><Code>NoSuchBucket</Code><Message>The bucket does not exist</Message></Error>
        """
        XCTAssertEqual(ErrorResultParser.message(from: Data(xml.utf8)),
                       "The bucket does not exist")
    }
}
