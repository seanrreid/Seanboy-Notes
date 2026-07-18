import Foundation

/// One-time migration from the pre-v3 store format: flat `<uuid>.md` files
/// whose titles live in a `title:` frontmatter field become `<Title>.md`.
public enum LegacyMigration {

    /// True when the folder still contains UUID-named notes.
    public static func isNeeded(in directory: URL) -> Bool {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil)) ?? []
        return files.contains {
            $0.pathExtension == "md" && UUID(uuidString: $0.deletingPathExtension().lastPathComponent) != nil
        }
    }

    /// Renames each `<uuid>.md` to its title (collision-suffixed). Legacy
    /// tombstone files (`deleted: true`) move into `tombstoneStore` and are
    /// removed from the folder. Returns the number of files migrated.
    @discardableResult
    public static func run(in directory: URL, tombstones: TombstoneStore) throws -> Int {
        let fm = FileManager.default
        let files = try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        var migrated = 0
        var takenNames = Set(files.map { $0.lastPathComponent.lowercased() })

        for file in files where file.pathExtension == "md" {
            guard UUID(uuidString: file.deletingPathExtension().lastPathComponent) != nil,
                  let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            let parsed = NoteDocument.parse(text)
            guard let id = parsed.id else { continue }

            if parsed.deleted {
                tombstones.record(id: id, deletedAt: parsed.modified ?? Date())
                try fm.removeItem(at: file)
                migrated += 1
                continue
            }

            let title = parsed.legacyTitle ?? "Untitled"
            var name = NoteNaming.sanitize(title)
            if takenNames.contains(name.lowercased() + ".md") {
                var n = 2
                while takenNames.contains("\(name.lowercased()) \(n).md") { n += 1 }
                name = "\(name) \(n)"
            }
            takenNames.insert(name.lowercased() + ".md")

            let note = Note(
                id: id, relativePath: name + ".md", body: parsed.body,
                createdAt: parsed.created ?? Date(),
                modifiedAt: parsed.modified ?? Date(),
                extraFrontmatter: parsed.extraFrontmatter)
            let target = directory.appendingPathComponent(note.relativePath)
            try NoteDocument.serialize(note).write(to: target, atomically: true, encoding: .utf8)
            try fm.removeItem(at: file)
            migrated += 1
        }
        return migrated
    }
}
