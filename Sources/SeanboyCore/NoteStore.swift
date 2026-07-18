import Foundation

/// Local-first storage: every note is one Markdown file (`<uuid>.md`) inside
/// a notes directory. The store keeps an in-memory cache of all notes and
/// writes through to disk on every mutation, so the files are always the
/// source of truth.
public final class NoteStore {
    public let directory: URL
    public private(set) var notesByID: [UUID: Note] = [:]

    /// Called after any mutation (create/update/delete/reload/merge).
    public var onChange: (() -> Void)?

    public init(directory: URL) throws {
        self.directory = directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try reload()
    }

    // MARK: - Queries

    /// All live (non-tombstoned) notes, most recently modified first.
    public var activeNotes: [Note] {
        notesByID.values
            .filter { !$0.isDeleted }
            .sorted { $0.modifiedAt > $1.modifiedAt }
    }

    /// Every note including tombstones — used by the sync engine.
    public var allNotes: [Note] { Array(notesByID.values) }

    public func note(id: UUID) -> Note? { notesByID[id] }

    /// Case-insensitive title lookup among live notes (wiki-link resolution).
    public func note(titled title: String) -> Note? {
        let needle = title.trimmingCharacters(in: .whitespaces).lowercased()
        return activeNotes.first { $0.title.lowercased() == needle }
    }

    // MARK: - Mutations

    @discardableResult
    public func create(title: String, body: String = "") -> Note {
        let note = Note(title: uniqueTitle(from: title), body: body)
        write(note)
        return note
    }

    public func update(_ note: Note, touchModified: Bool = true) {
        var updated = note
        if touchModified { updated.modifiedAt = Date() }
        write(updated)
    }

    /// Tombstones the note so the deletion propagates through sync.
    public func delete(id: UUID) {
        guard var note = notesByID[id] else { return }
        note.isDeleted = true
        note.modifiedAt = Date()
        write(note)
    }

    /// Applies a note coming from the sync engine verbatim (no timestamp touch).
    public func applyRemote(_ note: Note) {
        write(note)
    }

    // MARK: - Disk

    public func reload() throws {
        var loaded: [UUID: Note] = [:]
        let files = try FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil)
        for file in files where file.pathExtension == "md" {
            guard let text = try? String(contentsOf: file, encoding: .utf8),
                  let note = NoteDocument.deserialize(text) else { continue }
            loaded[note.id] = note
        }
        notesByID = loaded
        onChange?()
    }

    public func fileURL(for id: UUID) -> URL {
        directory.appendingPathComponent("\(id.uuidString).md")
    }

    private func write(_ note: Note) {
        let url = fileURL(for: note.id)
        do {
            try NoteDocument.serialize(note).write(to: url, atomically: true, encoding: .utf8)
            notesByID[note.id] = note
            onChange?()
        } catch {
            NSLog("Seanboy: failed to write note \(note.id): \(error)")
        }
    }

    /// "New Note", "New Note 2", "New Note 3", ... among live notes.
    private func uniqueTitle(from base: String) -> String {
        let trimmed = base.trimmingCharacters(in: .whitespaces)
        let candidate = trimmed.isEmpty ? "New Note" : trimmed
        if note(titled: candidate) == nil { return candidate }
        var n = 2
        while note(titled: "\(candidate) \(n)") != nil { n += 1 }
        return "\(candidate) \(n)"
    }
}
