import Foundation

/// Local app settings (per-device, not synced):
///
///     ~/Library/Application Support/Seanboy/settings.json
///     { "notesFolderPath": "/Users/you/Documents/Seanboy Notes" }
enum AppSettings {
    struct Contents: Codable, Equatable {
        var notesFolderPath: String?
        /// Auto-links to other notes' titles in the editor; nil means on.
        var autoLinks: Bool?
    }

    /// Set to a scratch directory to run the app fully isolated from the real
    /// settings, notes folder, and sync credentials (development only).
    static let supportOverride = ProcessInfo.processInfo.environment["SEANBOY_SUPPORT_DIR"]
        .map { URL(fileURLWithPath: $0, isDirectory: true) }

    /// `~/Library/Application Support/Seanboy` (or `$SEANBOY_SUPPORT_DIR`).
    static var supportDirectory: URL {
        supportOverride ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Seanboy", isDirectory: true)
    }

    static var fileURL: URL {
        supportDirectory.appendingPathComponent("settings.json")
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

    static func setAutoLinks(_ enabled: Bool) {
        var contents = load()
        contents.autoLinks = enabled
        save(contents)
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
        if let supportOverride {
            return supportOverride.appendingPathComponent("Seanboy Notes", isDirectory: true)
        }
        let legacy = supportDirectory.appendingPathComponent("Notes", isDirectory: true)
        let legacyHasNotes = ((try? FileManager.default.contentsOfDirectory(
            at: legacy, includingPropertiesForKeys: nil)) ?? [])
            .contains { $0.pathExtension == "md" }
        if legacyHasNotes { return legacy }
        return FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Seanboy Notes", isDirectory: true)
    }
}
