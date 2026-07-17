import Foundation

/// Supabase credentials, loaded from a JSON file next to the notes folder —
/// never hardcoded and never committed to the repo:
///
///     ~/Library/Application Support/TomboyMac/supabase.json
///     { "url": "https://xyzcompany.supabase.co", "anonKey": "eyJ..." }
struct SupabaseConfig: Codable, Equatable {
    var url: URL
    var anonKey: String

    static var fileURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TomboyMac/supabase.json")
    }

    static func load() -> SupabaseConfig? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(SupabaseConfig.self, from: data)
    }

    static func save(urlString: String, anonKey: String) throws -> SupabaseConfig {
        guard let url = URL(string: urlString.trimmingCharacters(in: .whitespaces)),
              url.scheme?.hasPrefix("http") == true else {
            throw NSError(domain: "TomboyMac", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Project URL must look like https://xyz.supabase.co",
            ])
        }
        let config = SupabaseConfig(url: url, anonKey: anonKey.trimmingCharacters(in: .whitespaces))
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted]
        try encoder.encode(config).write(to: fileURL, options: [.atomic])
        return config
    }
}
