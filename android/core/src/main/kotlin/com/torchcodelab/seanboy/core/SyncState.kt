package com.torchcodelab.seanboy.core

import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import java.io.File
import java.time.Instant
import java.time.format.DateTimeFormatter
import java.util.UUID

/**
 * What this device knows about the bucket from its last successful sync: for
 * each note, the remote key it lived at, the ETag it had, and the note's
 * `modifiedAt` at that moment. Comparing against this is what turns sync into a
 * three-way merge — local change and remote change are detected independently,
 * so a skewed clock can no longer eat an edit.
 *
 * Kotlin port of `mac/Sources/SeanboyCore/SyncState.swift`. The in-memory shape
 * lands here; JSON persistence to app-private storage arrives with the sync
 * integration milestone.
 */
data class SyncState(
    /** Keyed by uppercase `Note.id` (JSON-friendly, matches the Mac). */
    val entries: MutableMap<String, Entry> = mutableMapOf(),
) {
    data class Entry(val key: String, val etag: String, val modifiedAt: Instant)

    operator fun get(id: UUID): Entry? = entries[NoteDocument.uuidString(id)]

    operator fun set(id: UUID, entry: Entry?) {
        val k = NoteDocument.uuidString(id)
        if (entry == null) entries.remove(k) else entries[k] = entry
    }

    // MARK: - Persistence (device-local; never synced)

    fun save(file: File) {
        val dto = Dto(entries.mapValues { EntryDto(it.value.key, it.value.etag, ISO.format(it.value.modifiedAt)) })
        file.parentFile?.mkdirs()
        val tmp = File(file.parentFile, file.name + ".tmp")
        tmp.writeText(json.encodeToString(Dto.serializer(), dto))
        if (!tmp.renameTo(file)) { file.writeText(tmp.readText()); tmp.delete() }
    }

    @Serializable
    private data class Dto(val entries: Map<String, EntryDto> = emptyMap())

    @Serializable
    private data class EntryDto(val key: String, val etag: String, val modifiedAt: String)

    companion object {
        private val ISO: DateTimeFormatter = DateTimeFormatter.ISO_INSTANT
        private val json = Json { prettyPrint = true; ignoreUnknownKeys = true }

        fun load(file: File): SyncState {
            val text = runCatching { file.readText() }.getOrNull() ?: return SyncState()
            val dto = runCatching { json.decodeFromString(Dto.serializer(), text) }.getOrNull()
                ?: return SyncState()
            val entries = dto.entries.mapValues { (_, e) ->
                Entry(e.key, e.etag, NoteDocument.parseDate(e.modifiedAt) ?: Instant.EPOCH)
            }.toMutableMap()
            return SyncState(entries)
        }
    }
}
