import Foundation

/// Local-first storage over a user-chosen folder of human-named Markdown
/// files (`Journal/2026/July.md`), scanned recursively. The files are the
/// source of truth; the store is an in-memory index that writes through on
/// every mutation. Deleting moves files to the macOS Trash and records a
/// tombstone outside the folder — the user's directory only contains live
/// notes.
public final class NoteStore {
    public let directory: URL
    public let tombstones: TombstoneStore
    public private(set) var notesByID: [UUID: Note] = [:]
    private var idByPath: [String: UUID] = [:]
    /// fs mtime last seen per path — lets reconcile skip unchanged files.
    private var fsModifiedByPath: [String: Date] = [:]

    /// Called after any mutation (create/update/delete/reload/merge).
    public var onChange: (() -> Void)?

    public init(directory: URL, tombstoneFileURL: URL) throws {
        self.directory = directory
        self.tombstones = TombstoneStore(fileURL: tombstoneFileURL)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        _ = try reload()
    }

    // MARK: - Queries

    /// All live notes, most recently modified first.
    public var activeNotes: [Note] {
        notesByID.values.sorted { $0.modifiedAt > $1.modifiedAt }
    }

    /// Live notes plus tombstone records (as deleted `Note`s) — the sync
    /// engine's view of this device.
    public var allNotes: [Note] {
        var all = Array(notesByID.values)
        for (id, deletedAt) in tombstones.deletedAtByID where notesByID[id] == nil {
            all.append(Note(id: id, relativePath: "", body: "",
                            createdAt: deletedAt, modifiedAt: deletedAt, isDeleted: true))
        }
        return all
    }

    public func note(id: UUID) -> Note? { notesByID[id] }

    public func note(atPath path: String) -> Note? {
        idByPath[path.lowercased()].flatMap { notesByID[$0] }
    }

    /// Wiki-link resolution. `[[Title]]` matches by filename anywhere in the
    /// tree (most recently modified wins on ambiguity); `[[folder/Title]]`
    /// pins the exact path.
    public func note(titled title: String) -> Note? {
        let needle = title.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return nil }
        if needle.contains("/") {
            return note(atPath: needle + ".md") ?? note(atPath: needle)
        }
        let lowered = needle.lowercased()
        return activeNotes.first { $0.title.lowercased() == lowered }
    }

    // MARK: - Mutations

    @discardableResult
    public func create(title: String, body: String = "", folder: String = "") -> Note {
        let unique = uniqueTitle(from: title, in: folder)
        let note = Note(title: unique, folder: folder, body: body)
        write(note)
        return note
    }

    /// Persists an edit. A changed `relativePath` (title edit or move)
    /// renames the file on disk.
    public func update(_ note: Note, touchModified: Bool = true) {
        var updated = note
        if touchModified { updated.modifiedAt = Date() }
        if let existing = notesByID[note.id], existing.relativePath != updated.relativePath {
            moveFile(from: existing.relativePath, to: updated.relativePath)
            idByPath[existing.relativePath.lowercased()] = nil
            fsModifiedByPath[existing.relativePath] = nil
        }
        write(updated)
    }

    /// Moves the file to the macOS Trash and records a tombstone so the
    /// deletion syncs to other devices.
    public func delete(id: UUID) {
        guard let note = notesByID[id] else { return }
        trashFile(at: note.relativePath)
        removeFromIndex(note)
        tombstones.record(id: id, deletedAt: Date())
        onChange?()
    }

    /// Applies a note coming from the sync engine verbatim.
    public func applyRemote(_ note: Note) {
        if note.isDeleted {
            if let existing = notesByID[note.id] {
                trashFile(at: existing.relativePath)
                removeFromIndex(existing)
            }
            tombstones.record(id: note.id, deletedAt: note.modifiedAt)
            onChange?()
            return
        }
        tombstones.clear(id: note.id)  // resurrection cancels the tombstone
        if let existing = notesByID[note.id], existing.relativePath != note.relativePath {
            moveFile(from: existing.relativePath, to: note.relativePath)
            idByPath[existing.relativePath.lowercased()] = nil
            fsModifiedByPath[existing.relativePath] = nil
        }
        write(note)
    }

    // MARK: - Disk

    /// Recursive scan reconciled against the in-memory index. Adopts foreign
    /// Markdown (injects an `id`), matches external renames by id, treats
    /// vanished files as deletions (except on first load). Returns whether
    /// anything actually changed; fires `onChange` only then.
    @discardableResult
    public func reload() throws -> Bool {
        let firstLoad = notesByID.isEmpty && idByPath.isEmpty
        var scanned: [UUID: Note] = [:]
        var scannedPaths: [String: UUID] = [:]
        var scannedMtimes: [String: Date] = [:]
        let fm = FileManager.default

        let enumerator = fm.enumerator(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey, .creationDateKey, .isDirectoryKey],
            options: [.skipsHiddenFiles])
        while let file = enumerator?.nextObject() as? URL {
            let values = try? file.resourceValues(
                forKeys: [.contentModificationDateKey, .creationDateKey, .isDirectoryKey])
            if values?.isDirectory == true { continue }
            guard file.pathExtension.lowercased() == "md" else { continue }
            let path = relativePath(of: file)
            let mtime = values?.contentModificationDate ?? Date()

            // Unchanged since last seen — reuse the in-memory note.
            if let knownMtime = fsModifiedByPath[path], knownMtime == mtime,
               let id = idByPath[path.lowercased()], let known = notesByID[id] {
                scanned[id] = known
                scannedPaths[path.lowercased()] = id
                scannedMtimes[path] = mtime
                continue
            }

            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            let parsed = NoteDocument.parse(text)
            var note: Note
            if let id = parsed.id {
                // mtime wins over frontmatter when an external editor
                // touched the file without updating the header.
                let modified = isExternallyEdited(parsed: parsed, mtime: mtime)
                    ? mtime : (parsed.modified ?? mtime)
                note = Note(id: id, relativePath: path, body: parsed.body,
                            createdAt: parsed.created ?? values?.creationDate ?? mtime,
                            modifiedAt: modified,
                            isDeleted: false,
                            extraFrontmatter: parsed.extraFrontmatter)
            } else {
                // Foreign Markdown — adopt: inject an id, keep everything else.
                note = Note(id: UUID(), relativePath: path, body: parsed.body,
                            createdAt: parsed.created ?? values?.creationDate ?? mtime,
                            modifiedAt: parsed.modified ?? mtime,
                            isDeleted: false,
                            extraFrontmatter: parsed.extraFrontmatter)
                try? NoteDocument.serialize(note)
                    .write(to: file, atomically: true, encoding: .utf8)
            }
            if scanned[note.id] != nil {
                // Same id at two paths (user duplicated a file in Finder) —
                // keep the first, re-adopt the copy under a fresh id.
                note.id = UUID()
                try? NoteDocument.serialize(note)
                    .write(to: file, atomically: true, encoding: .utf8)
            }
            scanned[note.id] = note
            scannedPaths[path.lowercased()] = note.id
            scannedMtimes[path] = (try? file.resourceValues(
                forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? mtime
        }

        // Vanished files = external deletions (never on first load).
        var changed = false
        if !firstLoad {
            for id in notesByID.keys where scanned[id] == nil {
                tombstones.record(id: id, deletedAt: Date())
                changed = true
            }
        }

        if scanned != notesByID { changed = true }
        notesByID = scanned
        idByPath = scannedPaths
        fsModifiedByPath = scannedMtimes
        // A note that came back (file restored, undo of a delete) cancels
        // its tombstone.
        for id in scanned.keys where tombstones.contains(id: id) {
            tombstones.clear(id: id)
            changed = true
        }
        if changed || firstLoad { onChange?() }
        return changed
    }

    public func fileURL(forPath path: String) -> URL {
        directory.appendingPathComponent(path)
    }

    public func fileURL(for id: UUID) -> URL? {
        notesByID[id].map { fileURL(forPath: $0.relativePath) }
    }

    // MARK: - Private

    /// An external edit bumped the fs mtime past what our frontmatter says.
    private func isExternallyEdited(parsed: NoteDocument.Parsed, mtime: Date) -> Bool {
        guard let recorded = parsed.modified else { return true }
        return mtime.timeIntervalSince(recorded) > 1.5
    }

    private func relativePath(of file: URL) -> String {
        let base = directory.standardizedFileURL.path + "/"
        let full = file.standardizedFileURL.path
        return full.hasPrefix(base) ? String(full.dropFirst(base.count)) : file.lastPathComponent
    }

    private func write(_ note: Note) {
        let url = fileURL(forPath: note.relativePath)
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try NoteDocument.serialize(note).write(to: url, atomically: true, encoding: .utf8)
            notesByID[note.id] = note
            idByPath[note.relativePath.lowercased()] = note.id
            fsModifiedByPath[note.relativePath] = (try? url.resourceValues(
                forKeys: [.contentModificationDateKey]))?.contentModificationDate
            onChange?()
        } catch {
            NSLog("Seanboy: failed to write note \(note.relativePath): \(error)")
        }
    }

    private func moveFile(from oldPath: String, to newPath: String) {
        let fm = FileManager.default
        let source = fileURL(forPath: oldPath)
        let target = fileURL(forPath: newPath)
        guard fm.fileExists(atPath: source.path) else { return }
        do {
            try fm.createDirectory(
                at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            if oldPath.lowercased() == newPath.lowercased() {
                // Case-only rename on a case-insensitive filesystem needs a hop.
                let hop = source.deletingLastPathComponent()
                    .appendingPathComponent(".seanboy-rename-\(UUID().uuidString)")
                try fm.moveItem(at: source, to: hop)
                try fm.moveItem(at: hop, to: target)
            } else {
                try fm.moveItem(at: source, to: target)
            }
        } catch {
            NSLog("Seanboy: failed to move \(oldPath) → \(newPath): \(error)")
        }
    }

    private func trashFile(at path: String) {
        let url = fileURL(forPath: path)
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return }
        do {
            try fm.trashItem(at: url, resultingItemURL: nil)
        } catch {
            try? fm.removeItem(at: url)  // e.g. volumes without a Trash
        }
    }

    private func removeFromIndex(_ note: Note) {
        notesByID[note.id] = nil
        idByPath[note.relativePath.lowercased()] = nil
        fsModifiedByPath[note.relativePath] = nil
    }

    /// "New Note", "New Note 2", … unique within `folder`.
    private func uniqueTitle(from base: String, in folder: String) -> String {
        let trimmed = base.trimmingCharacters(in: .whitespaces)
        let candidate = trimmed.isEmpty ? "New Note" : trimmed
        func taken(_ title: String) -> Bool {
            let filename = NoteNaming.filename(forTitle: title)
            let path = folder.isEmpty ? filename : folder + "/" + filename
            return idByPath[path.lowercased()] != nil
        }
        if !taken(candidate) { return candidate }
        var n = 2
        while taken("\(candidate) \(n)") { n += 1 }
        return "\(candidate) \(n)"
    }
}
