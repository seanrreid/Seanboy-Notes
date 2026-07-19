package com.torchcodelab.seanboy.core

import java.time.Instant
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
}
