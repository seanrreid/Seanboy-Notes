import Foundation

/// What this device knows about the bucket from its last successful sync:
/// for each note, the remote key it lived at, the ETag it had, and the
/// note's `modifiedAt` at that moment. Comparing against this file is what
/// turns sync into a three-way merge — local change and remote change are
/// detected independently, so a skewed clock can no longer eat an edit.
public struct SyncState: Codable, Equatable, Sendable {
    public struct Entry: Codable, Equatable, Sendable {
        public var key: String
        public var etag: String
        public var modifiedAt: Date

        public init(key: String, etag: String, modifiedAt: Date) {
            self.key = key
            self.etag = etag
            self.modifiedAt = modifiedAt
        }
    }

    /// Keyed by `Note.id.uuidString` (JSON-friendly).
    public var entries: [String: Entry]

    public init(entries: [String: Entry] = [:]) {
        self.entries = entries
    }

    public subscript(id: UUID) -> Entry? {
        get { entries[id.uuidString] }
        set { entries[id.uuidString] = newValue }
    }

    // MARK: - Persistence

    public static func load(from url: URL) -> SyncState {
        guard let data = try? Data(contentsOf: url) else { return SyncState() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(SyncState.self, from: data)) ?? SyncState()
    }

    public func save(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(self).write(to: url, options: [.atomic])
    }
}
