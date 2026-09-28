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
    @Published var selectedNoteID: UUID? {
        didSet {
            guard selectedNoteID != oldValue else { return }
            flushPendingEdits()
            titleClash = nil
            propertiesRejection = nil
            if freshNoteID != selectedNoteID { freshNoteID = nil }
        }
    }
    @Published private(set) var revision = 0  // bumped on any store change

    /// A note created blank by ⌘N; its inline title starts empty (showing
    /// the "Untitled" placeholder) until it's renamed or deselected.
    @Published private(set) var freshNoteID: UUID?
    /// A title edit that couldn't be applied because another note in the
    /// same folder already has that name.
    @Published private(set) var titleClash: TitleClash?
    private var pendingTitle: (id: UUID, title: String)?
    /// Properties text that couldn't be saved as written (see
    /// `NoteDocument.editedFrontmatter`); shown with a warning until fixed.
    @Published private(set) var propertiesRejection: PropertiesRejection?
    private var pendingProperties: (id: UUID, text: String)?

    struct PropertiesRejection: Equatable {
        let noteID: UUID
        let attempted: String
        let lines: [String]
    }
    private var titleCommitTask: Task<Void, Never>?

    struct TitleClash: Equatable {
        let noteID: UUID
        let attempted: String
        let existingTitle: String
    }

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
        AppSettings.supportDirectory
    }

    /// One-time rename of the pre-rebrand `TomboyMac` support directory to
    /// `Seanboy`, so existing notes carry over. Runs
    /// only when the new directory doesn't exist yet and the legacy one does.
    static func migrateLegacySupportDirectoryIfNeeded() {
        guard AppSettings.supportOverride == nil else { return }
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

    /// New notes start as `Untitled.md` with an empty inline title; pass a
    /// title for notes created from a wiki link or quick capture.
    @discardableResult
    func createNote(title: String? = nil, body: String = "") -> Note {
        let note = store.create(title: title ?? "", body: body)
        searchText = ""
        selectedNoteID = note.id
        freshNoteID = title == nil ? note.id : nil
        sync.noteDidChange()
        return note
    }

    func updateBody(_ body: String, for id: UUID) {
        guard var note = store.note(id: id), note.body != body else { return }
        note.body = body
        store.update(note)
        sync.noteDidChange()
    }

    /// Applies every pending inline edit (title, properties) now.
    func flushPendingEdits() {
        flushPendingTitle()
        flushPendingProperties()
    }

    // MARK: - Properties (unmanaged frontmatter)

    func propertiesText(for note: Note) -> String {
        if let rejection = propertiesRejection, rejection.noteID == note.id { return rejection.attempted }
        return NoteDocument.propertiesText(for: note)
    }

    func propertiesWarning(for id: UUID) -> String? {
        guard let rejection = propertiesRejection, rejection.noteID == id else { return nil }
        let list = rejection.lines.map { "“\($0)”" }.joined(separator: ", ")
        return "Not saved: \(list) would be lost or break the note’s header. Seanboy manages id, created, and modified itself."
    }

    /// Called on every keystroke in the Properties editor; saved on
    /// focus-out and at the same flush points as the title.
    func editProperties(_ text: String, for id: UUID) {
        pendingProperties = (id, text)
    }

    func flushPendingProperties() {
        guard let (id, text) = pendingProperties else { return }
        pendingProperties = nil
        guard var note = store.note(id: id) else { return }
        switch NoteDocument.editedFrontmatter(text, for: note) {
        case .accepted(let lines):
            propertiesRejection = nil
            guard lines != note.extraFrontmatter else { return }
            note.extraFrontmatter = lines
            store.update(note)
            sync.noteDidChange()
        case .rejected(let lines):
            propertiesRejection = PropertiesRejection(noteID: id, attempted: text, lines: lines)
        }
    }

    // MARK: - Inline title

    /// What the inline title field shows for `note`.
    func displayedTitle(for note: Note) -> String {
        if let clash = titleClash, clash.noteID == note.id { return clash.attempted }
        return freshNoteID == note.id ? "" : note.title
    }

    func titleWarning(for id: UUID) -> String? {
        guard let clash = titleClash, clash.noteID == id else { return nil }
        return "A note named “\(clash.existingTitle)” already exists in this folder."
    }

    /// Called on every keystroke in the title; renames after a short pause.
    func editTitle(_ title: String, for id: UUID) {
        pendingTitle = (id, title)
        titleCommitTask?.cancel()
        titleCommitTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(750))
            guard !Task.isCancelled else { return }
            self?.flushPendingTitle()
        }
    }

    /// Applies any pending title edit now. Called on focus-out, note
    /// switches, window close, and app deactivation/quit so a typed title
    /// is never lost.
    func flushPendingTitle() {
        titleCommitTask?.cancel()
        titleCommitTask = nil
        guard let (id, title) = pendingTitle else { return }
        pendingTitle = nil
        switch store.rename(id: id, to: title) {  // moves the file — filename is the title
        case .renamed:
            titleClash = nil
            if freshNoteID == id { freshNoteID = nil }
            sync.noteDidChange()
        case .unchanged:
            titleClash = nil
        case .clash(let existingTitle):
            titleClash = TitleClash(noteID: id, attempted: title, existingTitle: existingTitle)
        }
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
