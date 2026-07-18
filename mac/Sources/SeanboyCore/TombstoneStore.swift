import Foundation

/// Per-device record of deleted notes, kept OUTSIDE the notes folder so the
/// user's directory only ever contains live notes. Sync reads these to push
/// `.tombstones/` objects; a resurrected note clears its record.
public final class TombstoneStore {
    public private(set) var deletedAtByID: [UUID: Date] = [:]
    private let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
        load()
    }

    public func record(id: UUID, deletedAt: Date) {
        deletedAtByID[id] = deletedAt
        save()
    }

    public func clear(id: UUID) {
        guard deletedAtByID.removeValue(forKey: id) != nil else { return }
        save()
    }

    public func contains(id: UUID) -> Bool {
        deletedAtByID[id] != nil
    }

    // MARK: - Persistence

    private struct File: Codable {
        var tombstones: [String: Date]
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let file = try? decoder.decode(File.self, from: data) else { return }
        deletedAtByID = file.tombstones.reduce(into: [:]) { result, entry in
            if let id = UUID(uuidString: entry.key) { result[id] = entry.value }
        }
    }

    private func save() {
        let file = File(tombstones: Dictionary(
            uniqueKeysWithValues: deletedAtByID.map { ($0.key.uuidString, $0.value) }))
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try encoder.encode(file).write(to: fileURL, options: [.atomic])
        } catch {
            NSLog("Seanboy: failed to save tombstones: \(error)")
        }
    }
}
