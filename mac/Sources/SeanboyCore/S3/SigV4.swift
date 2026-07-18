import Foundation
import CryptoKit

/// AWS Signature Version 4 request signing — the tiny slice of it S3 needs.
/// Pure functions over strings so it can be verified against the documented
/// AWS test vectors.
public enum SigV4 {

    public struct Credentials: Equatable, Sendable {
        public var accessKeyID: String
        public var secretAccessKey: String

        public init(accessKeyID: String, secretAccessKey: String) {
            self.accessKeyID = accessKeyID
            self.secretAccessKey = secretAccessKey
        }
    }

    /// The pieces of an HTTP request that participate in signing. `headers`
    /// must contain every header that will be sent and signed (including
    /// `host` and `x-amz-content-sha256`); `x-amz-date` is derived from `date`.
    public struct Request: Sendable {
        public var method: String
        public var path: String
        public var queryItems: [(name: String, value: String)]
        public var headers: [String: String]
        public var payloadHash: String
        public var date: Date

        public init(method: String, path: String,
                    queryItems: [(name: String, value: String)] = [],
                    headers: [String: String], payloadHash: String, date: Date) {
            self.method = method
            self.path = path
            self.queryItems = queryItems
            self.headers = headers
            self.payloadHash = payloadHash
            self.date = date
        }
    }

    public static let unsignedPayload = "UNSIGNED-PAYLOAD"

    /// SHA-256 of an empty body — the payload hash for GET/DELETE requests.
    public static let emptyPayloadHash =
        "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"

    /// Returns the headers to add to the request: `Authorization` and
    /// `x-amz-date` (the latter is also included in the signature).
    public static func sign(_ request: Request, credentials: Credentials,
                            region: String, service: String = "s3") -> [String: String] {
        let amzDate = timestamp(request.date)
        let dateStamp = String(amzDate.prefix(8))

        var headers = request.headers
        headers["x-amz-date"] = amzDate

        let sortedHeaders = headers
            .map { (name: $0.key.lowercased(), value: $0.value.trimmingCharacters(in: .whitespaces)) }
            .sorted { $0.name < $1.name }
        let canonicalHeaders = sortedHeaders.map { "\($0.name):\($0.value)\n" }.joined()
        let signedHeaders = sortedHeaders.map(\.name).joined(separator: ";")

        let canonicalRequest = [
            request.method,
            canonicalURI(request.path),
            canonicalQuery(request.queryItems),
            canonicalHeaders,
            signedHeaders,
            request.payloadHash,
        ].joined(separator: "\n")

        let scope = "\(dateStamp)/\(region)/\(service)/aws4_request"
        let stringToSign = [
            "AWS4-HMAC-SHA256",
            amzDate,
            scope,
            hexHash(canonicalRequest),
        ].joined(separator: "\n")

        var key = hmac(Data(("AWS4" + credentials.secretAccessKey).utf8), dateStamp)
        key = hmac(key, region)
        key = hmac(key, service)
        key = hmac(key, "aws4_request")
        let signature = hex(hmac(key, stringToSign))

        let authorization = "AWS4-HMAC-SHA256 "
            + "Credential=\(credentials.accessKeyID)/\(scope), "
            + "SignedHeaders=\(signedHeaders), "
            + "Signature=\(signature)"

        return ["Authorization": authorization, "x-amz-date": amzDate]
    }

    // MARK: - Canonical pieces

    /// RFC 3986 unreserved characters — everything else gets percent-encoded.
    private static let unreserved: Set<Character> = {
        var set = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789")
        set.formUnion("-._~")
        return set
    }()

    /// Percent-encodes a string for SigV4. S3 canonical URIs are encoded
    /// once, with `/` left intact in paths (`encodeSlash: false`).
    public static func encode(_ string: String, encodeSlash: Bool = true) -> String {
        var out = ""
        for byte in Data(string.utf8) {
            let char = Character(UnicodeScalar(byte))
            if unreserved.contains(char) || (!encodeSlash && char == "/") {
                out.append(char)
            } else {
                out += String(format: "%%%02X", byte)
            }
        }
        return out
    }

    static func canonicalURI(_ path: String) -> String {
        path.isEmpty ? "/" : encode(path, encodeSlash: false)
    }

    static func canonicalQuery(_ items: [(name: String, value: String)]) -> String {
        var pairs: [(String, String)] = items.map { (encode($0.name), encode($0.value)) }
        pairs.sort { (a: (String, String), b: (String, String)) -> Bool in
            a.0 == b.0 ? a.1 < b.1 : a.0 < b.0
        }
        return pairs.map { "\($0.0)=\($0.1)" }.joined(separator: "&")
    }

    // MARK: - Crypto helpers

    public static func hexHash(_ string: String) -> String {
        hexHash(Data(string.utf8))
    }

    public static func hexHash(_ data: Data) -> String {
        hex(Data(SHA256.hash(data: data)))
    }

    private static func hmac(_ key: Data, _ message: String) -> Data {
        let mac = HMAC<SHA256>.authenticationCode(
            for: Data(message.utf8), using: SymmetricKey(data: key))
        return Data(mac)
    }

    private static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    static func timestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return formatter.string(from: date)
    }
}
