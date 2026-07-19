package com.torchcodelab.seanboy.core

import java.io.File
import java.time.Instant
import java.time.format.DateTimeFormatter
import java.util.UUID

/**
 * Per-device record of deleted notes, kept OUTSIDE the notes folder so the
 * user's directory only ever contains live notes. Sync reads these to push
 * `.tombstones/` objects; a resurrected note clears its record.
 *
 * Kotlin port of `mac/Sources/SeanboyCore/TombstoneStore.swift`. Persists the
 * same JSON shape (`{"tombstones": {"<uuid>": "<iso8601>"}}`). Keys are UUIDs
 * and values ISO-8601 instants, so no JSON escaping is ever needed.
 */
class TombstoneStore(private val file: File) {
    private val _deletedAtByID: MutableMap<UUID, Instant> = mutableMapOf()
    val deletedAtByID: Map<UUID, Instant> get() = _deletedAtByID

    init {
        load()
    }

    fun record(id: UUID, deletedAt: Instant) {
        _deletedAtByID[id] = deletedAt
        save()
    }

    fun clear(id: UUID) {
        if (_deletedAtByID.remove(id) != null) save()
    }

    fun contains(id: UUID): Boolean = _deletedAtByID.containsKey(id)

    // MARK: - Persistence

    private fun load() {
        val text = runCatching { file.readText() }.getOrNull() ?: return
        // Controlled format: extract every "<uuid>": "<instant>" pair.
        val pair = Regex(""""([0-9a-fA-F-]{36})"\s*:\s*"([^"]+)"""")
        for (match in pair.findAll(text)) {
            val id = runCatching { UUID.fromString(match.groupValues[1]) }.getOrNull() ?: continue
            val at = NoteDocument.parseDate(match.groupValues[2]) ?: continue
            _deletedAtByID[id] = at
        }
    }

    private fun save() {
        val entries = _deletedAtByID
            .map { NoteDocument.uuidString(it.key) to DateTimeFormatter.ISO_INSTANT.format(it.value) }
            .sortedBy { it.first }
        val body = entries.joinToString(",\n") { "    \"${it.first}\": \"${it.second}\"" }
        val json = "{\n  \"tombstones\": {\n$body\n  }\n}\n"
        runCatching {
            file.parentFile?.mkdirs()
            val tmp = File(file.parentFile, file.name + ".tmp")
            tmp.writeText(json)
            if (!tmp.renameTo(file)) {
                file.writeText(json)
                tmp.delete()
            }
        }
    }
}
