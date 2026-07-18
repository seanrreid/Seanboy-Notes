import XCTest
@testable import SeanboyCore

/// Verified against the worked examples in the AWS SigV4 documentation
/// ("Authenticating Requests: Using the Authorization Header", examplebucket).
final class SigV4Tests: XCTestCase {

    private let credentials = SigV4.Credentials(
        accessKeyID: "AKIAIOSFODNN7EXAMPLE",
        secretAccessKey: "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY")

    /// 2013-05-24T00:00:00Z — the timestamp all AWS examples use.
    private var exampleDate: Date {
        var components = DateComponents()
        components.year = 2013
        components.month = 5
        components.day = 24
        components.timeZone = TimeZone(identifier: "UTC")
        return Calendar(identifier: .gregorian).date(from: components)!
    }

    private func signature(_ headers: [String: String]) -> String {
        headers["Authorization"]!
            .components(separatedBy: "Signature=").last!
    }

    func testGetObjectExample() {
        let headers = SigV4.sign(
            SigV4.Request(
                method: "GET",
                path: "/test.txt",
                headers: [
                    "host": "examplebucket.s3.amazonaws.com",
                    "range": "bytes=0-9",
                    "x-amz-content-sha256": SigV4.emptyPayloadHash,
                ],
                payloadHash: SigV4.emptyPayloadHash,
                date: exampleDate),
            credentials: credentials, region: "us-east-1")

        XCTAssertEqual(headers["x-amz-date"], "20130524T000000Z")
        XCTAssertEqual(
            signature(headers),
            "f0e8bdb87c964420e857bd35b5d6ed310bd44f0170aba48dd91039c6036bdb41")
    }

    func testPutObjectExample() {
        let payloadHash = SigV4.hexHash("Welcome to Amazon S3.")
        XCTAssertEqual(
            payloadHash,
            "44ce7dd67c959e0d3524ffac1771dfbba87d2b6b4b4e99e42034a8b803f8b072")

        let headers = SigV4.sign(
            SigV4.Request(
                method: "PUT",
                path: "/test$file.text",
                headers: [
                    "date": "Fri, 24 May 2013 00:00:00 GMT",
                    "host": "examplebucket.s3.amazonaws.com",
                    "x-amz-content-sha256": payloadHash,
                    "x-amz-storage-class": "REDUCED_REDUNDANCY",
                ],
                payloadHash: payloadHash,
                date: exampleDate),
            credentials: credentials, region: "us-east-1")

        XCTAssertEqual(
            signature(headers),
            "98ad721746da40c64f1a55b78f14c238d841ea1380cd77a1b5971af0ece108bd")
    }

    func testListObjectsExample() {
        let headers = SigV4.sign(
            SigV4.Request(
                method: "GET",
                path: "/",
                queryItems: [("max-keys", "2"), ("prefix", "J")],
                headers: [
                    "host": "examplebucket.s3.amazonaws.com",
                    "x-amz-content-sha256": SigV4.emptyPayloadHash,
                ],
                payloadHash: SigV4.emptyPayloadHash,
                date: exampleDate),
            credentials: credentials, region: "us-east-1")

        XCTAssertEqual(
            signature(headers),
            "34b48302e7b5fa45bde8084f4b7868a86f0a534bc59db6670ed5711ef69dc6f7")
    }

    func testEncodingRules() {
        XCTAssertEqual(SigV4.encode("notes/Grocery List.md", encodeSlash: false),
                       "notes/Grocery%20List.md")
        XCTAssertEqual(SigV4.encode("a+b=c&d"), "a%2Bb%3Dc%26d")
        XCTAssertEqual(SigV4.encode("héllo"), "h%C3%A9llo")
        XCTAssertEqual(SigV4.encode("safe-._~chars"), "safe-._~chars")
    }
}
