import Foundation

/// Local app settings (per-device, not synced):
///
///     ~/Library/Application Support/Seanboy/settings.json
///     { "notesFolderPath": "/Users/you/Documents/Seanboy Notes" }
enum AppSettings {
    struct Contents: Codable, Equatable {
        var notesFolderPath: String?
    }

    static var fileURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Seanboy/settings.json")
    }

    static func load() -> Contents {
        guard let data = try? Data(contentsOf: fileURL),
              let contents = try? JSONDecoder().decode(Contents.self, from: data) else {
            return Contents()
        }
        return contents
    }

    static func save(_ contents: Contents) {
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            try encoder.encode(contents).write(to: fileURL, options: [.atomic])
        } catch {
            NSLog("Seanboy: failed to save settings: \(error)")
        }
    }

    static func setNotesFolder(_ url: URL) {
        var contents = load()
        contents.notesFolderPath = url.path
        save(contents)
    }

    /// Where notes live, in priority order: the user's chosen folder, the
    /// legacy Application Support folder (if it has notes), else a fresh
    /// visible default in Documents.
    static func resolveNotesFolder() -> URL {
        if let path = load().notesFolderPath {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        let legacy = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Seanboy/Notes", isDirectory: true)
        let legacyHasNotes = ((try? FileManager.default.contentsOfDirectory(
            at: legacy, includingPropertiesForKeys: nil)) ?? [])
            .contains { $0.pathExtension == "md" }
        if legacyHasNotes { return legacy }
        return FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Seanboy Notes", isDirectory: true)
    }
}
