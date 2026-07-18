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
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(S3Config.self, from: data)
    }

    @discardableResult
    static func save(endpoint: String, bucket: String,
                     accessKeyID: String, secretAccessKey: String) throws -> S3Config {
        guard let url = URL(string: endpoint.trimmingCharacters(in: .whitespaces)),
              url.scheme?.hasPrefix("http") == true, url.host != nil else {
            throw NSError(domain: "Seanboy", code: 1, userInfo: [
                NSLocalizedDescriptionKey:
                    "Endpoint must look like https://<account>.r2.cloudflarestorage.com",
            ])
        }
        let trimmedBucket = bucket.trimmingCharacters(in: .whitespaces)
        guard !trimmedBucket.isEmpty else {
            throw NSError(domain: "Seanboy", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Bucket name is required.",
            ])
        }
        let config = S3Config(
            endpoint: url,
            bucket: trimmedBucket,
            region: load()?.region ?? "auto",
            accessKeyID: accessKeyID.trimmingCharacters(in: .whitespaces),
            secretAccessKey: secretAccessKey.trimmingCharacters(in: .whitespaces))
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(config).write(to: fileURL, options: [.atomic])
        return config
    }
}
