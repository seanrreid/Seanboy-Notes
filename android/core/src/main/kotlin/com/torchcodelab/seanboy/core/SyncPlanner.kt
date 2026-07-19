package com.torchcodelab.seanboy.core

import java.time.Instant
import java.util.UUID

/**
 * Pure three-way sync planner between the local store, the bucket listing, and
 * the last-sync state. Free of networking so every scenario is unit-testable;
 * the sync service feeds it and executes the returned actions.
 *
 * Bucket layout:
 * - `notes/<relative/path>.md`   live notes, human-browsable
 * - `.tombstones/<uuid>.md`      deleted notes (so deletion propagates)
 * - `.versions/<name>/<ts>.md`   copy-on-overwrite history (service-managed)
 *
 * Faithful Kotlin port of `mac/Sources/SeanboyCore/SyncPlanner.swift`.
 */
object SyncPlanner {

    const val NOTES_PREFIX = "notes/"
    const val TOMBSTONES_PREFIX = ".tombstones/"
    const val VERSIONS_PREFIX = ".versions/"

    /** `modifiedAt` values within this window (seconds) count as equal. */
    const val TIMESTAMP_TOLERANCE = 0.01

    /** A listed bucket object; [note] is populated once downloaded. */
    data class RemoteFile(val key: String, val etag: String, val note: Note? = null)

    data class Upload(
        val note: Note,
        val key: String,
        /**
         * ETag the object must still have (`If-Match`). null means the key must
         * not exist yet (`If-None-Match: *`).
         */
        val expectedETag: String? = null,
    )

    data class LocalApply(
        val note: Note,
        val key: String,
        val etag: String,
        /**
         * Local content displaced by a lost conflict — the service stashes it in
         * `.versions/` before overwriting, so nothing is silently lost.
         */
        val displacedLocal: Note? = null,
    )

    data class Plan(
        val applyLocally: MutableList<LocalApply> = mutableListOf(),
        val uploads: MutableList<Upload> = mutableListOf(),
        /**
         * Remote keys made obsolete (renames, superseded tombstones, duplicate
         * objects). Deleted after uploads succeed.
         */
        val deleteRemoteKeys: MutableList<String> = mutableListOf(),
    ) {
        val isEmpty: Boolean
            get() = applyLocally.isEmpty() && uploads.isEmpty() && deleteRemoteKeys.isEmpty()
    }

    // MARK: - Keys

    /**
     * Object key a note lives at: its relative path under `notes/` (the bucket
     * mirrors the local tree 1:1), UUID under `.tombstones/` once deleted. Paths
     * are unique locally, so no collision handling needed.
     */
    fun key(note: Note): String =
        if (note.isDeleted) TOMBSTONES_PREFIX + NoteDocument.uuidString(note.id) + ".md"
        else NOTES_PREFIX + note.relativePath

    /** The relative path a `notes/`-prefixed key maps to locally. */
    fun relativePath(key: String): String? =
        if (key.startsWith(NOTES_PREFIX)) key.substring(NOTES_PREFIX.length) else null

    // MARK: - Planning

    /**
     * Keys the service must download before planning: any listed object whose
     * (key, etag) pair this device hasn't recorded.
     */
    fun keysNeedingDownload(listing: List<RemoteFile>, state: SyncState): List<String> {
        val known = state.entries.values.map { "${it.key}\u0000${it.etag}" }.toHashSet()
        return listing
            .filter { it.note == null && "${it.key}\u0000${it.etag}" !in known }
            .map { it.key }
    }

    /**
     * [remote] must contain every listed object under `notes/` and
     * `.tombstones/`, with [RemoteFile.note] populated for each key returned by
     * [keysNeedingDownload].
     */
    fun plan(local: List<Note>, remote: List<RemoteFile>, state: SyncState): Plan {
        val plan = Plan()

        val etagByKey = LinkedHashMap<String, String>()
        for (file in remote) etagByKey.putIfAbsent(file.key, file.etag)

        // Downloaded remote notes by ID; duplicates (stale rename leftovers)
        // resolve to the newest copy, the rest get cleaned up.
        val remoteByID = LinkedHashMap<UUID, RemoteFile>()
        for (file in remote) {
            val note = file.note ?: continue
            val existing = remoteByID[note.id]
            val existingNote = existing?.note
            if (existing != null && existingNote != null) {
                if (secondsBetween(note.modifiedAt, existingNote.modifiedAt) > 0) {
                    plan.deleteRemoteKeys.add(existing.key)
                    remoteByID[note.id] = file
                } else {
                    plan.deleteRemoteKeys.add(file.key)
                }
            } else {
                remoteByID[note.id] = file
            }
        }

        val localByID = local.associateBy { it.id }

        for (note in local) {
            val entry = state[note.id]
            val target = key(note)
            val localChanged =
                if (entry != null) secondsBetween(note.modifiedAt, entry.modifiedAt) > TIMESTAMP_TOLERANCE
                else true

            val file = remoteByID[note.id]
            val theirs = file?.note
            if (file != null && theirs != null) {
                // Remote changed (or state was lost and everything re-downloaded).
                if (notesEquivalent(note, theirs)) {
                    // Already in sync — just refresh state via a no-op apply.
                    plan.applyLocally.add(LocalApply(note = note, key = file.key, etag = file.etag))
                    continue
                }
                // Timestamps decide only a true conflict (both sides changed); a
                // remote-only change always applies, so clock skew on another
                // device can never override an edit made here.
                val localWins = localChanged &&
                    secondsBetween(note.modifiedAt, theirs.modifiedAt) > TIMESTAMP_TOLERANCE
                if (localWins) {
                    plan.uploads.add(
                        Upload(
                            note = note,
                            key = target,
                            expectedETag = if (target == file.key) file.etag else null,
                        ),
                    )
                    if (target != file.key) plan.deleteRemoteKeys.add(file.key)
                } else {
                    // Remote wins; preserve the losing local edit if there was one.
                    plan.applyLocally.add(
                        LocalApply(
                            note = theirs,
                            key = file.key,
                            etag = file.etag,
                            displacedLocal = if (localChanged) note else null,
                        ),
                    )
                    if (entry != null && entry.key != file.key && etagByKey[entry.key] != null) {
                        plan.deleteRemoteKeys.add(entry.key)
                    }
                }
            } else if (entry != null) {
                if (etagByKey[entry.key] == null) {
                    // The object vanished without a tombstone (manual bucket edit
                    // or interrupted rename) — restore it from local.
                    plan.uploads.add(Upload(note = note, key = target, expectedETag = null))
                } else if (localChanged || target != entry.key) {
                    // Remote untouched since last sync; push the local edit (or
                    // relocate the object after a key reassignment).
                    plan.uploads.add(
                        Upload(
                            note = note,
                            key = target,
                            expectedETag = if (target == entry.key) entry.etag else null,
                        ),
                    )
                    if (target != entry.key) plan.deleteRemoteKeys.add(entry.key)
                }
                // else: fully in sync — nothing to do.
            } else {
                // Never synced from this device — push, tombstones included, so
                // deletes made before first sync still propagate.
                plan.uploads.add(Upload(note = note, key = target, expectedETag = null))
            }
        }

        // Remote-only notes: new on another device — pull them in.
        for ((id, file) in remoteByID) {
            if (localByID[id] != null) continue
            val note = file.note ?: continue
            plan.applyLocally.add(LocalApply(note = note, key = file.key, etag = file.etag))
        }

        return plan
    }

    /**
     * Content-equal within timestamp tolerance — used to recognize
     * already-in-sync notes after a state-file loss.
     */
    fun notesEquivalent(a: Note, b: Note): Boolean =
        a.id == b.id && a.relativePath == b.relativePath && a.body == b.body &&
            a.isDeleted == b.isDeleted && a.extraFrontmatter == b.extraFrontmatter &&
            kotlin.math.abs(secondsBetween(a.modifiedAt, b.modifiedAt)) <= TIMESTAMP_TOLERANCE

    private fun secondsBetween(a: Instant, b: Instant): Double =
        (a.toEpochMilli() - b.toEpochMilli()) / 1000.0
}
