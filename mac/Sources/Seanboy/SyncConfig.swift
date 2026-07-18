import Foundation
import SeanboyCore

/// Bucket credentials, loaded from a JSON file next to the notes folder —
/// never hardcoded and never committed to the repo:
///
///     ~/Library/Application Support/Seanboy/sync.json
///     {
///       "endpoint": "https://<account>.r2.cloudflarestorage.com",
///       "bucket": "seanboy-notes",
///       "accessKeyID": "…",
///       "secretAccessKey": "…"
///     }
///
/// `region` is optional and defaults to "auto" (correct for R2); set it in
/// the file when pointing at another S3-compatible host.
enum SyncConfigFile {
    static var fileURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Seanboy/sync.json")
    }

    static func load() -> S3Config? {
        guard let data = try? Data(contentsOf: fileURL),
              var config = try? JSONDecoder().decode(S3Config.self, from: data) else {
            return nil
        }
        // Defensively clean stray whitespace/newlines from hand-edited or
        // previously mis-saved files — a trailing \n breaks request signing.
        config.bucket = config.bucket.trimmingCharacters(in: .whitespacesAndNewlines)
        config.region = config.region.trimmingCharacters(in: .whitespacesAndNewlines)
        config.accessKeyID = config.accessKeyID.trimmingCharacters(in: .whitespacesAndNewlines)
        config.secretAccessKey = config.secretAccessKey.trimmingCharacters(in: .whitespacesAndNewlines)
        return config
    }

    @discardableResult
    static func save(endpoint: String, bucket: String,
                     accessKeyID: String, secretAccessKey: String) throws -> S3Config {
        // .whitespacesAndNewlines, not .whitespaces — Cloudflare's copy
        // button appends a newline, which would poison the signing key.
        let trimmedBucket = bucket.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedBucket.isEmpty else {
            throw NSError(domain: "Seanboy", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Bucket name is required.",
            ])
        }

        var endpointString = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        while endpointString.hasSuffix("/") { endpointString.removeLast() }
        // Tolerate pasting the full S3 API URL, which includes the bucket.
        if endpointString.hasSuffix("/" + trimmedBucket) {
            endpointString.removeLast(trimmedBucket.count + 1)
        }
        guard let url = URL(string: endpointString),
              url.scheme?.hasPrefix("http") == true, url.host != nil else {
            throw NSError(domain: "Seanboy", code: 1, userInfo: [
                NSLocalizedDescriptionKey:
                    "Endpoint must look like https://<account>.r2.cloudflarestorage.com",
            ])
        }
        let config = S3Config(
            endpoint: url,
            bucket: trimmedBucket,
            region: load()?.region ?? "auto",
            accessKeyID: accessKeyID.trimmingCharacters(in: .whitespacesAndNewlines),
            secretAccessKey: secretAccessKey.trimmingCharacters(in: .whitespacesAndNewlines))
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(config).write(to: fileURL, options: [.atomic])
        return config
    }
}
