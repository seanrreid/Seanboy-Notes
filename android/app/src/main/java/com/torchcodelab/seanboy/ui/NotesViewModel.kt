package com.torchcodelab.seanboy.ui

import android.app.Application
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import com.torchcodelab.seanboy.core.Note
import com.torchcodelab.seanboy.core.S3Config
import com.torchcodelab.seanboy.core.SearchService
import com.torchcodelab.seanboy.core.WikiLinkParser
import com.torchcodelab.seanboy.data.AppContainer
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.combine
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
    private val container = AppContainer(app)
    private val store = container.store

    private val _notes = MutableStateFlow(store.activeNotes)
    private val _query = MutableStateFlow("")
    val query: StateFlow<String> = _query.asStateFlow()

    private val _selectedId = MutableStateFlow<UUID?>(null)
    val selectedId: StateFlow<UUID?> = _selectedId.asStateFlow()

    private val _sync = MutableStateFlow<SyncStatus>(
        if (container.isSyncConfigured) SyncStatus.Idle else SyncStatus.NotConfigured,
    )
    val sync: StateFlow<SyncStatus> = _sync.asStateFlow()

    /** Search results — the flat, ranked list; empty query returns all by recency. */
    val results: StateFlow<List<Note>> =
        combine(_notes, _query) { notes, q -> SearchService.search(q, notes) }
            .stateIn(viewModelScope, SharingStarted.Eagerly, store.activeNotes)

    val selectedNote: StateFlow<Note?> =
        combine(_notes, _selectedId) { _, id -> id?.let { store.note(it) } }
            .stateIn(viewModelScope, SharingStarted.Eagerly, null)

    init {
        store.onChange = { _notes.value = store.activeNotes }
    }

    // MARK: - Notes

    fun setQuery(value: String) { _query.value = value }

    fun select(id: UUID?) { _selectedId.value = id }

    fun createNote() {
        val note = store.create(title = "New Note")
        _selectedId.value = note.id
        maybeSync()
    }

    fun updateBody(id: UUID, body: String) {
        val note = store.note(id) ?: return
        store.update(note.copy(body = body))
    }

    fun rename(id: UUID, newTitle: String) {
        val note = store.note(id) ?: return
        store.update(note.withTitle(newTitle))
    }

    fun delete(id: UUID) {
        store.delete(id)
        if (_selectedId.value == id) _selectedId.value = null
        maybeSync()
    }

    fun backlinks(note: Note): List<Note> = WikiLinkParser.backlinks(note.title, store.activeNotes)

    /** Follow a `[[link]]`: open the target, creating it at the root if missing. */
    fun openWikiLink(title: String) {
        val existing = store.noteTitled(title)
        val note = existing ?: store.create(title = title)
        _selectedId.value = note.id
        if (existing == null) maybeSync()
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
