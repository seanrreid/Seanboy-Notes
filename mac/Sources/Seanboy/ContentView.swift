import SwiftUI
import CoreSpotlight
import SeanboyCore

struct ContentView: View {
    @EnvironmentObject private var model: NotesViewModel

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 220, ideal: 260)
        } detail: {
            if let note = model.selectedNote {
                NoteDetailView(note: note)
                    .id(note.id)
            } else {
                ContentUnavailableView(
                    "No Note Selected",
                    systemImage: "note.text",
                    description: Text("Select a note or press ⌘N to create one."))
            }
        }
        .onContinueUserActivity(CSSearchableItemActionType) { activity in
            if let idString = activity.userInfo?[CSSearchableItemActivityIdentifier] as? String,
               let id = UUID(uuidString: idString) {
                model.openNote(id: id)
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    model.createNote()
                } label: {
                    Label("New Note", systemImage: "square.and.pencil")
                }
                .help("New Note (⌘N)")
            }
            ToolbarItem {
                SyncStatusButton()
            }
        }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            List(selection: $model.selectedNoteID) {
                if model.searchText.isEmpty {
                    // Browse: the real folder structure.
                    OutlineGroup(model.folderTree, children: \.children) { node in
                        if let noteID = node.noteID, let note = model.store.note(id: noteID) {
                            NoteRow(note: note)
                                .tag(noteID)
                                .contextMenu {
                                    Button("Delete Note", role: .destructive) {
                                        model.deleteNote(id: noteID)
                                    }
                                }
                        } else {
                            Label(node.name, systemImage: "folder")
                        }
                    }
                } else {
                    // Search: flat, ranked results across the whole tree.
                    ForEach(model.filteredNotes) { note in
                        NoteRow(note: note)
                            .tag(note.id)
                            .contextMenu {
                                Button("Delete Note", role: .destructive) {
                                    model.deleteNote(id: note.id)
                                }
                            }
                    }
                }
            }
            .listStyle(.sidebar)
        }
        .searchable(text: $model.searchText, placement: .sidebar, prompt: "Search notes")
    }
}

private struct NoteRow: View {
    let note: Note

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(note.title)
                .font(.body.weight(.medium))
                .lineLimit(1)
            Text(snippet)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.vertical, 2)
    }

    private var snippet: String {
        let firstLine = note.body
            .split(separator: "\n", omittingEmptySubsequences: true)
            .first.map(String.init) ?? ""
        let cleaned = firstLine
            .replacingOccurrences(of: "#", with: "")
            .trimmingCharacters(in: .whitespaces)
        return cleaned.isEmpty
            ? note.modifiedAt.formatted(date: .abbreviated, time: .shortened)
            : cleaned
    }
}

struct NoteDetailView: View {
    @EnvironmentObject private var model: NotesViewModel
    let note: Note
    @State private var title: String = ""

    var body: some View {
        VStack(spacing: 0) {
            TextField("Title", text: $title)
                .textFieldStyle(.plain)
                .font(.title2.weight(.semibold))
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .onSubmit { model.updateTitle(title, for: note.id) }

            Divider()

            MarkdownEditor(
                text: Binding(
                    get: { model.selectedNote?.body ?? note.body },
                    set: { model.updateBody($0, for: note.id) }
                ),
                onOpenWikiLink: { model.openNote(titled: $0) }
            )

            backlinksBar
        }
        .onAppear { title = note.title }
        .onDisappear { model.updateTitle(title, for: note.id) }
        .navigationTitle("")
    }

    @ViewBuilder
    private var backlinksBar: some View {
        let backlinks = model.backlinks(for: note)
        if !backlinks.isEmpty {
            Divider()
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    Label("Linked from:", systemImage: "arrow.turn.up.left")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ForEach(backlinks) { source in
                        Button(source.title) {
                            model.openNote(id: source.id)
                        }
                        .buttonStyle(.link)
                        .font(.caption)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
            }
            .background(.bar)
        }
    }
}

struct SyncStatusButton: View {
    @EnvironmentObject private var model: NotesViewModel
    @ObservedObject private var sync: SyncService

    init() {
        _sync = ObservedObject(wrappedValue: NotesViewModel.shared.sync)
    }

    var body: some View {
        Button {
            model.syncNow()
        } label: {
            switch sync.state {
            case .idle:
                Label("Sync Now", systemImage: "arrow.triangle.2.circlepath")
            case .syncing:
                Label("Syncing…", systemImage: "arrow.triangle.2.circlepath")
                    .symbolEffect(.pulse, isActive: true)
            case .success(let date):
                Label("Synced \(date.formatted(date: .omitted, time: .shortened))",
                      systemImage: "checkmark.icloud")
            case .error:
                Label("Sync Failed", systemImage: "exclamationmark.icloud")
                    .foregroundStyle(.red)
            case .notConfigured:
                Label("Sync Off", systemImage: "icloud.slash")
                    .foregroundStyle(.secondary)
            }
        }
        .help(sync.statusDescription)
        .disabled(sync.state == .syncing)
    }
}
