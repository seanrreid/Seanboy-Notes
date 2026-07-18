import Foundation
import SwiftUI
import SeanboyCore

@MainActor
final class NotesViewModel: ObservableObject {
    static let shared = NotesViewModel()

    let store: NoteStore
    let sync: SyncService

    @Published var searchText: String = ""
    @Published var selectedNoteID: UUID?
    @Published private(set) var revision = 0  // bumped on any store change

    init() {
        NotesViewModel.migrateLegacySupportDirectoryIfNeeded()
        let directory = NotesViewModel.defaultNotesDirectory()
        do {
            store = try NoteStore(directory: directory)
        } catch {
            fatalError("Cannot create notes directory at \(directory.path): \(error)")
        }
        sync = SyncService(
            store: store,
            stateFileURL: NotesViewModel.supportDirectory()
                .appendingPathComponent("syncstate.json"))
        store.onChange = { [weak self] in
            DispatchQueue.main.async {
                guard let self else { return }
                self.revision += 1
                SpotlightIndexer.reindexAll(notes: self.store.activeNotes)
            }
        }
        if store.activeNotes.isEmpty {
            seedWelcomeNotes()
        }
        selectedNoteID = filteredNotes.first?.id
        sync.syncNow()  // on-demand model: sync at launch, after edits, and on ⇧⌘S
    }

    static func defaultNotesDirectory() -> URL {
        supportDirectory().appendingPathComponent("Notes", isDirectory: true)
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
        note.title = trimmed
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

            - Your notes are plain Markdown files in `~/Library/Application Support/Seanboy/Notes`
            - Search as you type in the sidebar
            - Link between notes with double brackets, like this: [[Ideas]]
            - Clicking a link to a note that doesn't exist *creates it*
            - Press ⌃⌥⌘N anywhere in macOS for quick capture
            - ==Highlight== things, make them **bold** or *italic*

            Open *Settings → Sync* to connect an R2 bucket and sync your machines.
            """)
    }
}
