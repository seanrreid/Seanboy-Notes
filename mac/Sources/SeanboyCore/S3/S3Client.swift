import Foundation

/// Connection details for an S3-compatible bucket. Built for Cloudflare R2
/// (`https://<account>.r2.cloudflarestorage.com`, region `auto`) but works
/// against any S3 host, including MinIO on a NAS.
public struct S3Config: Codable, Equatable, Sendable {
    public var endpoint: URL
    public var bucket: String
    public var region: String
    public var accessKeyID: String
    public var secretAccessKey: String

    public init(endpoint: URL, bucket: String, region: String = "auto",
                accessKeyID: String, secretAccessKey: String) {
        self.endpoint = endpoint
        self.bucket = bucket
        self.region = region
        self.accessKeyID = accessKeyID
        self.secretAccessKey = secretAccessKey
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        endpoint = try container.decode(URL.self, forKey: .endpoint)
        bucket = try container.decode(String.self, forKey: .bucket)
        region = try container.decodeIfPresent(String.self, forKey: .region) ?? "auto"
        accessKeyID = try container.decode(String.self, forKey: .accessKeyID)
        secretAccessKey = try container.decode(String.self, forKey: .secretAccessKey)
    }
}

public struct S3Object: Equatable, Sendable {
    public var key: String
    public var etag: String

    public init(key: String, etag: String) {
        self.key = key
        self.etag = etag
    }
}

public enum S3Error: Error, LocalizedError, Equatable {
    /// A conditional write failed — the object changed under us (or already
    /// exists for If-None-Match). The next sync re-merges and heals this.
    case preconditionFailed(key: String)
    case notFound(key: String)
    case http(status: Int, message: String)
    case badResponse

    public var errorDescription: String? {
        switch self {
        case .preconditionFailed(let key):
            return "\(key) changed on the server — will re-merge on next sync"
        case .notFound(let key):
            return "\(key) does not exist in the bucket"
        case .http(let status, let message):
            return message.isEmpty ? "Server returned HTTP \(status)" : message
        case .badResponse:
            return "Unexpected response from the server"
        }
    }
}

/// Minimal async S3 client: list / get / put / delete / copy, with
/// conditional writes. Paths are bucket-in-path style so a single endpoint
/// URL is all the configuration a provider needs.
public final class S3Client: Sendable {
    public let config: S3Config
    private let session: URLSession

    public init(config: S3Config, session: URLSession = .shared) {
        self.config = config
        self.session = session
    }

    // MARK: - Operations

    /// Lists every object under `prefix`, following continuation tokens.
    public func list(prefix: String) async throws -> [S3Object] {
        var objects: [S3Object] = []
        var continuation: String?
        repeat {
            var query: [(name: String, value: String)] = [
                ("list-type", "2"),
                ("prefix", prefix),
            ]
            if let continuation {
                query.append(("continuation-token", continuation))
            }
            let (data, _) = try await send(
                method: "GET", key: nil, query: query, body: nil)
            let page = ListResultParser.parse(data)
            objects.append(contentsOf: page.objects)
            continuation = page.nextContinuationToken
        } while continuation != nil
        return objects
    }

    public func get(key: String) async throws -> (data: Data, etag: String) {
        let (data, response) = try await send(method: "GET", key: key, query: [], body: nil)
        return (data, etag(from: response, key: key))
    }

    /// Uploads an object. `ifMatch` makes the write conditional on the
    /// current ETag; `ifNoneMatch` requires the key to not exist yet. Either
    /// failing throws `S3Error.preconditionFailed`.
    @discardableResult
    public func put(key: String, data: Data, contentType: String = "text/markdown",
                    ifMatch: String? = nil, ifNoneMatch: Bool = false) async throws -> String {
        var headers = ["content-type": contentType]
        if let ifMatch { headers["if-match"] = "\"\(ifMatch)\"" }
        if ifNoneMatch { headers["if-none-match"] = "*" }
        let (_, response) = try await send(
            method: "PUT", key: key, query: [], body: data, extraHeaders: headers)
        return etag(from: response, key: key)
    }

    /// Idempotent — deleting a missing key succeeds.
    public func delete(key: String) async throws {
        _ = try await send(method: "DELETE", key: key, query: [], body: nil)
    }

    public func copy(from sourceKey: String, to destinationKey: String) async throws {
        let source = "/" + SigV4.encode(config.bucket + "/" + sourceKey, encodeSlash: false)
        _ = try await send(method: "PUT", key: destinationKey, query: [], body: nil,
                           extraHeaders: ["x-amz-copy-source": source])
    }

    // MARK: - Request plumbing

    private func send(method: String, key: String?,
                      query: [(name: String, value: String)], body: Data?,
                      extraHeaders: [String: String] = [:]) async throws
        -> (Data, HTTPURLResponse) {
        guard let host = config.endpoint.host else { throw S3Error.badResponse }

        var path = "/" + config.bucket
        if let key { path += "/" + key }

        let payloadHash = SigV4.hexHash(body ?? Data())
        var headers = extraHeaders
        headers["host"] = host
        headers["x-amz-content-sha256"] = payloadHash

        let signed = SigV4.sign(
            SigV4.Request(method: method, path: path, queryItems: query,
                          headers: headers, payloadHash: payloadHash, date: Date()),
            credentials: .init(accessKeyID: config.accessKeyID,
                               secretAccessKey: config.secretAccessKey),
            region: config.region)
        headers.merge(signed) { _, new in new }
        headers.removeValue(forKey: "host")  // URLSession sets Host itself

        var urlString = config.endpoint.absoluteString
        if urlString.hasSuffix("/") { urlString.removeLast() }
        urlString += SigV4.encode(path, encodeSlash: false)
        let queryString = SigV4.canonicalQuery(query)
        if !queryString.isEmpty { urlString += "?" + queryString }
        guard let url = URL(string: urlString) else { throw S3Error.badResponse }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        for (name, value) in headers {
            request.setValue(value, forHTTPHeaderField: name)
        }

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw S3Error.badResponse }

        switch http.statusCode {
        case 200..<300:
            return (data, http)
        case 412:
            throw S3Error.preconditionFailed(key: key ?? path)
        case 404 where method == "DELETE":
            return (data, http)  // deleting a missing key is fine
        case 404:
            throw S3Error.notFound(key: key ?? path)
        default:
            throw S3Error.http(status: http.statusCode,
                               message: ErrorResultParser.message(from: data))
        }
    }

    private func etag(from response: HTTPURLResponse, key: String) -> String {
        let raw = response.value(forHTTPHeaderField: "ETag") ?? ""
        return raw.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
    }
}

// MARK: - XML parsing

/// Parses a ListObjectsV2 result page.
final class ListResultParser: NSObject, XMLParserDelegate {
    struct Page {
        var objects: [S3Object] = []
        var nextContinuationToken: String?
    }

    private var page = Page()
    private var currentElement = ""
    private var currentText = ""
    private var inContents = false
    private var key = ""
    private var etag = ""

    static func parse(_ data: Data) -> Page {
        let delegate = ListResultParser()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.parse()
        return delegate.page
    }

    func parser(_ parser: XMLParser, didStartElement name: String,
                namespaceURI: String?, qualifiedName: String?,
                attributes: [String: String] = [:]) {
        currentElement = name
        currentText = ""
        if name == "Contents" {
            inContents = true
            key = ""
            etag = ""
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        currentText += string
    }

    func parser(_ parser: XMLParser, didEndElement name: String,
                namespaceURI: String?, qualifiedName: String?) {
        let text = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
        switch name {
        case "Key" where inContents:
            key = text
        case "ETag" where inContents:
            etag = text.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        case "Contents":
            inContents = false
            page.objects.append(S3Object(key: key, etag: etag))
        case "NextContinuationToken":
            page.nextContinuationToken = text
        default:
            break
        }
        currentText = ""
    }
}

/// Pulls the human-readable message out of an S3 error body.
final class ErrorResultParser: NSObject, XMLParserDelegate {
    private var message = ""
    private var code = ""
    private var currentElement = ""
    private var currentText = ""

    static func message(from data: Data) -> String {
        let delegate = ErrorResultParser()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.parse()
        if !delegate.message.isEmpty { return delegate.message }
        return delegate.code
    }

    func parser(_ parser: XMLParser, didStartElement name: String,
                namespaceURI: String?, qualifiedName: String?,
                attributes: [String: String] = [:]) {
        currentElement = name
        currentText = ""
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        currentText += string
    }

    func parser(_ parser: XMLParser, didEndElement name: String,
                namespaceURI: String?, qualifiedName: String?) {
        let text = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
        if name == "Message" { message = text }
        if name == "Code" { code = text }
        currentText = ""
    }
}
