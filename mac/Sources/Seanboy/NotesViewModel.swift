import Foundation
import SwiftUI
import SeanboyCore

@MainActor
final class NotesViewModel: ObservableObject {
    static let shared = NotesViewModel()

    private(set) var store: NoteStore
    private(set) var sync: SyncService
    private var watcher: FolderWatcher?

    @Published var searchText: String = ""
    @Published var selectedNoteID: UUID?
    @Published private(set) var revision = 0  // bumped on any store change

    init() {
        NotesViewModel.migrateLegacySupportDirectoryIfNeeded()
        let directory = AppSettings.resolveNotesFolder()
        do {
            store = try NotesViewModel.makeStore(directory: directory)
        } catch {
            fatalError("Cannot open notes folder at \(directory.path): \(error)")
        }
        sync = SyncService(
            store: store,
            stateFileURL: NotesViewModel.supportDirectory()
                .appendingPathComponent("syncstate.json"))
        wireStore()
        if store.activeNotes.isEmpty {
            seedWelcomeNotes()
        }
        selectedNoteID = filteredNotes.first?.id
        startWatcher()
        sync.syncNow()  // on-demand model: sync at launch, after edits, and on ⇧⌘S
    }

    private static func makeStore(directory: URL) throws -> NoteStore {
        let tombstoneURL = supportDirectory().appendingPathComponent("tombstones.json")
        // Pre-v3 folders hold <uuid>.md files — migrate them to <Title>.md once.
        if LegacyMigration.isNeeded(in: directory) {
            let tombstones = TombstoneStore(fileURL: tombstoneURL)
            let migrated = (try? LegacyMigration.run(in: directory, tombstones: tombstones)) ?? 0
            NSLog("Seanboy: migrated \(migrated) legacy notes to human filenames")
        }
        return try NoteStore(directory: directory, tombstoneFileURL: tombstoneURL)
    }

    private func wireStore() {
        store.onChange = { [weak self] in
            DispatchQueue.main.async {
                guard let self else { return }
                self.revision += 1
                SpotlightIndexer.reindexAll(notes: self.store.activeNotes)
            }
        }
    }

    private func startWatcher() {
        watcher?.stop()
        let watcher = FolderWatcher(url: store.directory) { [weak self] in
            self?.reconcileExternalChanges()
        }
        watcher.start()
        self.watcher = watcher
    }

    /// The folder changed underneath us (vim, Obsidian, Finder, Synology…).
    private func reconcileExternalChanges() {
        let changed = (try? store.reload()) ?? false
        if changed {
            if let id = selectedNoteID, store.note(id: id) == nil {
                selectedNoteID = filteredNotes.first?.id
            }
            sync.noteDidChange()
        }
    }

    /// Repoints the app at a different notes folder.
    func setNotesFolder(_ url: URL) {
        AppSettings.setNotesFolder(url)
        do {
            let newStore = try NotesViewModel.makeStore(directory: url)
            store = newStore
            sync.attach(store: newStore)
            wireStore()
            store.onChange?()
            selectedNoteID = filteredNotes.first?.id
            startWatcher()
            sync.syncNow()
        } catch {
            NSLog("Seanboy: cannot open notes folder at \(url.path): \(error)")
        }
    }

    static func defaultNotesDirectory() -> URL {
        AppSettings.resolveNotesFolder()
    }

    /// Base Application Support directory for the app (`.../Seanboy`).
    static func supportDirectory() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Seanboy", isDirectory: true)
    }

    /// One-time rename of the pre-rebrand `TomboyMac` support directory to
    /// `Seanboy`, so existing notes carry over. Runs
    /// only when the new directory doesn't exist yet and the legacy one does.
    static func migrateLegacySupportDirectoryIfNeeded() {
        let fm = FileManager.default
        let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let legacy = appSupport.appendingPathComponent("TomboyMac", isDirectory: true)
        let current = appSupport.appendingPathComponent("Seanboy", isDirectory: true)
        guard fm.fileExists(atPath: legacy.path),
              !fm.fileExists(atPath: current.path) else { return }
        do {
            try fm.moveItem(at: legacy, to: current)
            NSLog("Seanboy: migrated legacy support directory TomboyMac → Seanboy")
        } catch {
            NSLog("Seanboy: failed to migrate legacy support directory: \(error)")
        }
    }

    // MARK: - Derived state

    var filteredNotes: [Note] {
        SearchService.search(searchText, in: store.activeNotes)
    }

    /// Folder tree for the sidebar when no search is active.
    var folderTree: [SidebarNode] {
        SidebarNode.tree(from: store.activeNotes)
    }

    var selectedNote: Note? {
        selectedNoteID.flatMap { store.note(id: $0) }.flatMap { $0.isDeleted ? nil : $0 }
    }

    func backlinks(for note: Note) -> [Note] {
        WikiLinkParser.backlinks(to: note.title, in: store.activeNotes)
    }

    // MARK: - Actions

    @discardableResult
    func createNote(title: String = "New Note", body: String = "") -> Note {
        let note = store.create(title: title, body: body)
        searchText = ""
        selectedNoteID = note.id
        sync.noteDidChange()
        return note
    }

    func updateBody(_ body: String, for id: UUID) {
        guard var note = store.note(id: id), note.body != body else { return }
        note.body = body
        store.update(note)
        sync.noteDidChange()
    }

    func updateTitle(_ title: String, for id: UUID) {
        let trimmed = title.trimmingCharacters(in: .whitespaces)
        guard var note = store.note(id: id), !trimmed.isEmpty, note.title != trimmed else { return }
        note.title = trimmed  // moves the file — filename is the title
        store.update(note)
        sync.noteDidChange()
    }

    func deleteNote(id: UUID) {
        store.delete(id: id)
        SpotlightIndexer.remove(id: id)
        sync.noteDidChange()
        if selectedNoteID == id {
            selectedNoteID = filteredNotes.first?.id
        }
    }

    /// Wiki-link navigation: open the note with this title, creating it first
    /// if it doesn't exist yet (classic Tomboy behavior).
    func openNote(titled title: String) {
        if let existing = store.note(titled: title) {
            searchText = ""
            selectedNoteID = existing.id
        } else {
            createNote(title: title)
        }
    }

    func openNote(id: UUID) {
        guard let note = store.note(id: id), !note.isDeleted else { return }
        searchText = ""
        selectedNoteID = note.id
    }

    func syncNow() {
        sync.syncNow()
    }

    private func seedWelcomeNotes() {
        store.create(
            title: "Start Here",
            body: """
            # Welcome to Seanboy

            A small, fast, local-first notes app in the spirit of **Tomboy**.

            - Your notes are plain Markdown files — this folder is yours.
              Subfolders welcome; edit with any app, Seanboy keeps up.
            - Search as you type in the sidebar; clear it to browse folders
            - Link between notes with double brackets, like this: [[Ideas]]
            - Clicking a link to a note that doesn't exist *creates it*
            - Press ⌃⌥⌘N anywhere in macOS for quick capture
            - ==Highlight== things, make them **bold** or *italic*

            Open *Settings → Sync* to connect an R2 bucket and sync your machines.
            """)
    }
}

/// A folder or note row in the sidebar tree.
struct SidebarNode: Identifiable, Hashable {
    let id: String            // folder path or note id string
    let name: String
    let noteID: UUID?         // nil for folders
    var children: [SidebarNode]?  // nil for notes (leaf)

    static func tree(from notes: [Note]) -> [SidebarNode] {
        var root = FolderBuilder()
        for note in notes {
            root.insert(note: note, components: note.folder.isEmpty
                ? [] : note.folder.components(separatedBy: "/"))
        }
        return root.nodes(pathPrefix: "")
    }

    private struct FolderBuilder {
        var subfolders: [String: FolderBuilder] = [:]
        var notes: [Note] = []

        mutating func insert(note: Note, components: [String]) {
            guard let first = components.first else {
                notes.append(note)
                return
            }
            subfolders[first, default: FolderBuilder()]
                .insert(note: note, components: Array(components.dropFirst()))
        }

        func nodes(pathPrefix: String) -> [SidebarNode] {
            let folderNodes = subfolders.keys.sorted(by: { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending })
                .map { name -> SidebarNode in
                    let path = pathPrefix.isEmpty ? name : pathPrefix + "/" + name
                    return SidebarNode(
                        id: "folder:" + path, name: name, noteID: nil,
                        children: subfolders[name]!.nodes(pathPrefix: path))
                }
            let noteNodes = notes
                .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
                .map { SidebarNode(id: $0.id.uuidString, name: $0.title, noteID: $0.id, children: nil) }
            return folderNodes + noteNodes
        }
    }
}
