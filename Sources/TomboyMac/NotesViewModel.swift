import Foundation
import SwiftUI
import TomboyCore

@MainActor
final class NotesViewModel: ObservableObject {
    static let shared = NotesViewModel()

    let store: NoteStore
    let sync: SyncService

    @Published var searchText: String = ""
    @Published var selectedNoteID: UUID?
    @Published private(set) var revision = 0  // bumped on any store change

    init() {
        let directory = NotesViewModel.defaultNotesDirectory()
        do {
            store = try NoteStore(directory: directory)
        } catch {
            fatalError("Cannot create notes directory at \(directory.path): \(error)")
        }
        sync = SyncService(store: store)
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
        sync.startAutoSync()
    }

    static func defaultNotesDirectory() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TomboyMac/Notes", isDirectory: true)
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
        return note
    }

    func updateBody(_ body: String, for id: UUID) {
        guard var note = store.note(id: id), note.body != body else { return }
        note.body = body
        store.update(note)
    }

    func updateTitle(_ title: String, for id: UUID) {
        let trimmed = title.trimmingCharacters(in: .whitespaces)
        guard var note = store.note(id: id), !trimmed.isEmpty, note.title != trimmed else { return }
        note.title = trimmed
        store.update(note)
    }

    func deleteNote(id: UUID) {
        store.delete(id: id)
        SpotlightIndexer.remove(id: id)
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
            # Welcome to Tomboy Mac

            A small, fast, local-first notes app in the spirit of **Tomboy**.

            - Your notes are plain Markdown files in `~/Library/Application Support/TomboyMac/Notes`
            - Search as you type in the sidebar
            - Link between notes with double brackets, like this: [[Ideas]]
            - Clicking a link to a note that doesn't exist *creates it*
            - Press ⌃⌥⌘N anywhere in macOS for quick capture
            - ==Highlight== things, make them **bold** or *italic*

            Open *Settings → Sync* to connect Supabase and sync your Macs.
            """)
    }
}
