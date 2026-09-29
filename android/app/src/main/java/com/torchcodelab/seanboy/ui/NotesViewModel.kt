package com.torchcodelab.seanboy.ui

import android.app.Application
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import com.torchcodelab.seanboy.core.FolderListing
import com.torchcodelab.seanboy.core.Note
import com.torchcodelab.seanboy.core.NoteStore
import com.torchcodelab.seanboy.core.S3Config
import com.torchcodelab.seanboy.core.SearchService
import com.torchcodelab.seanboy.core.WikiLinkParser
import com.torchcodelab.seanboy.data.AppContainer
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.util.UUID

sealed interface SyncStatus {
    data object NotConfigured : SyncStatus
    data object Idle : SyncStatus
    data object Syncing : SyncStatus
    data class Ok(val summary: String) : SyncStatus
    data class Failed(val message: String) : SyncStatus
}

/**
 * Holds the [com.torchcodelab.seanboy.core.NoteStore] and exposes reactive views
 * over it (search results, selected note, backlinks) plus the on-demand sync
 * triggers. All engine work runs off the main thread.
 */
class NotesViewModel(app: Application) : AndroidViewModel(app) {
    companion object {
        /** Typing pause before a title edit renames the file (same as the Mac). */
        const val TITLE_COMMIT_DELAY_MS = 750L
    }

    private val container = AppContainer(app)
    private val store = container.store

    private val _notes = MutableStateFlow(store.activeNotes)
    private val _query = MutableStateFlow("")
    val query: StateFlow<String> = _query.asStateFlow()

    /** Folder being browsed when the search is empty; "" is the root. */
    private val _folder = MutableStateFlow("")

    private val _selectedId = MutableStateFlow<UUID?>(null)
    val selectedId: StateFlow<UUID?> = _selectedId.asStateFlow()

    /** A note created blank by ＋: its title field starts empty ("Untitled" placeholder). */
    private val _freshNoteId = MutableStateFlow<UUID?>(null)
    val freshNoteId: StateFlow<UUID?> = _freshNoteId.asStateFlow()

    /** A title edit that couldn't be applied: another note in the folder has that name. */
    data class TitleClash(val noteId: UUID, val attempted: String, val existingTitle: String)
    private val _titleClash = MutableStateFlow<TitleClash?>(null)
    val titleClash: StateFlow<TitleClash?> = _titleClash.asStateFlow()

    private var pendingTitle: Pair<UUID, String>? = null
    private var titleCommitJob: Job? = null

    private val _sync = MutableStateFlow<SyncStatus>(
        if (container.isSyncConfigured) SyncStatus.Idle else SyncStatus.NotConfigured,
    )
    val sync: StateFlow<SyncStatus> = _sync.asStateFlow()

    /** Search results — the flat, ranked list; empty query returns all by recency. */
    val results: StateFlow<List<Note>> =
        combine(_notes, _query) { notes, q -> SearchService.search(q, notes) }
            .stateIn(viewModelScope, SharingStarted.Eagerly, store.activeNotes)

    /**
     * The browsed folder's contents. If the folder disappears (its last note
     * deleted or synced away), this falls back to its nearest ancestor.
     */
    val listing: StateFlow<FolderListing> =
        combine(_notes, _folder) { notes, folder ->
            FolderListing.of(notes, FolderListing.nearestExisting(notes, folder))
        }.stateIn(viewModelScope, SharingStarted.Eagerly, FolderListing.of(store.activeNotes, ""))

    /** Every folder, depth-first, for the side drawer. */
    val folderTree: StateFlow<List<FolderListing.Subfolder>> =
        _notes.map { FolderListing.tree(it) }
            .stateIn(viewModelScope, SharingStarted.Eagerly, FolderListing.tree(store.activeNotes))

    val selectedNote: StateFlow<Note?> =
        combine(_notes, _selectedId) { _, id -> id?.let { store.note(it) } }
            .stateIn(viewModelScope, SharingStarted.Eagerly, null)

    init {
        store.onChange = { _notes.value = store.activeNotes }
    }

    // MARK: - Notes

    fun setQuery(value: String) { _query.value = value }

    /** Opens a note (or returns to the list with null), committing any typed title first. */
    fun select(id: UUID?) {
        if (id == _selectedId.value) return
        flushPendingTitle()
        _titleClash.value = null
        if (_freshNoteId.value != id) _freshNoteId.value = null
        _selectedId.value = id
    }

    fun openFolder(path: String) { _folder.value = path }

    /** Back from a folder to its parent. False at the root (nothing to do). */
    fun goUp(): Boolean {
        val current = listing.value.folder
        if (current.isEmpty()) return false
        _folder.value = FolderListing.parent(current)
        return true
    }

    /** New notes land in the folder being browsed, as `Untitled` with an empty title field. */
    fun createNote() {
        val note = store.create(title = "", folder = listing.value.folder)
        select(note.id)
        _freshNoteId.value = note.id
        maybeSync()
    }

    fun updateBody(id: UUID, body: String) {
        val note = store.note(id) ?: return
        store.update(note.copy(body = body))
    }

    // MARK: - Inline title

    /** What the title field shows: the rejected attempt during a clash, blank for a fresh note. */
    fun displayedTitle(note: Note): String {
        _titleClash.value?.let { if (it.noteId == note.id) return it.attempted }
        return if (_freshNoteId.value == note.id) "" else note.title
    }

    /** Called on every keystroke in the title; renames after a short pause. */
    fun editTitle(id: UUID, title: String) {
        pendingTitle = id to title
        titleCommitJob?.cancel()
        titleCommitJob = viewModelScope.launch {
            delay(TITLE_COMMIT_DELAY_MS)
            flushPendingTitle()
        }
    }

    /**
     * Applies any pending title edit now. Called on focus-out, Back, note
     * switches, and when the app goes to the background, so a typed title is
     * never lost.
     */
    fun flushPendingTitle() {
        titleCommitJob?.cancel()
        titleCommitJob = null
        val (id, title) = pendingTitle ?: return
        pendingTitle = null
        when (val result = store.rename(id, title)) { // moves the file — the filename is the title
            is NoteStore.RenameResult.Renamed -> {
                _titleClash.value = null
                if (_freshNoteId.value == id) _freshNoteId.value = null
                maybeSync()
            }
            NoteStore.RenameResult.Unchanged -> _titleClash.value = null
            is NoteStore.RenameResult.Clash ->
                _titleClash.value = TitleClash(id, attempted = title, existingTitle = result.existingTitle)
        }
    }

    fun delete(id: UUID) {
        if (pendingTitle?.first == id) {
            titleCommitJob?.cancel()
            pendingTitle = null
        }
        store.delete(id)
        if (_selectedId.value == id) select(null)
        maybeSync()
    }

    fun backlinks(note: Note): List<Note> = WikiLinkParser.backlinks(note.title, store.activeNotes)

    /** Follow a `[[link]]`: open the target, creating it at the root if missing. */
    fun openWikiLink(title: String) {
        val existing = store.noteTitled(title)
        val note = existing ?: store.create(title = title)
        select(note.id)
        if (existing == null) maybeSync()
    }

    override fun onCleared() {
        flushPendingTitle()
    }

    // MARK: - Sync

    fun reloadFromDisk() {
        store.reload()
        _notes.value = store.activeNotes
    }

    fun saveCredentials(config: S3Config) {
        container.credentials.save(config)
        _sync.value = SyncStatus.Idle
    }

    fun clearCredentials() {
        container.credentials.clear()
        _sync.value = SyncStatus.NotConfigured
    }

    fun currentConfig(): S3Config? = container.credentials.load()

    private fun maybeSync() {
        if (container.isSyncConfigured) syncNow()
    }

    fun syncNow() {
        val engine = container.syncEngine() ?: run {
            _sync.value = SyncStatus.NotConfigured
            return
        }
        if (_sync.value is SyncStatus.Syncing) return
        _sync.value = SyncStatus.Syncing
        viewModelScope.launch {
            val result = withContext(Dispatchers.IO) { runCatching { engine.sync() } }
            _notes.value = store.activeNotes
            result
                .onSuccess { r ->
                    _sync.value = SyncStatus.Ok("${r.uploaded} up · ${r.appliedLocally} down · ${r.deletedRemote} cleaned")
                }
                .onFailure { e -> _sync.value = SyncStatus.Failed(e.message ?: "sync failed") }
        }
    }
}
