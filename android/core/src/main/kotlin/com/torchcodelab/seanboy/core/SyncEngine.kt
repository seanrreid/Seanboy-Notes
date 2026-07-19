package com.torchcodelab.seanboy.core

import java.io.File
import java.time.Instant
import java.time.ZoneOffset
import java.time.format.DateTimeFormatter

/**
 * UI-free orchestrator that syncs a [NoteStore] with an S3 bucket using the
 * pure [SyncPlanner]. One blocking [sync] pass runs the full sequence: list,
 * download-what's-new, plan, upload (version-copying overwrites), apply remote
 * changes, delete obsolete keys, retry blocked uploads. Callers run it off the
 * main thread and own the on-demand triggers (open / debounced-after-edit /
 * "Sync now") and the observable status.
 *
 * Port of the sync sequence in `mac/Sources/Seanboy/SyncService.swift`, with
 * the SwiftUI/@MainActor/debounce concerns left to the Android ViewModel.
 */
class SyncEngine(
    private val store: NoteStore,
    private val client: S3Client,
    private val stateFile: File,
    private val versionCap: Int = 10,
) {
    data class Result(
        val uploaded: Int,
        val appliedLocally: Int,
        val deletedRemote: Int,
        val unresolved: Int,
    )

    private val versionStamp: DateTimeFormatter =
        DateTimeFormatter.ofPattern("yyyyMMdd-HHmmss").withZone(ZoneOffset.UTC)

    fun sync(): Result {
        val syncState = SyncState.load(stateFile)

        // 1. List live notes and tombstones.
        val listing = (client.list(SyncPlanner.NOTES_PREFIX) + client.list(SyncPlanner.TOMBSTONES_PREFIX))
            .map { SyncPlanner.RemoteFile(key = it.key, etag = it.etag) }
            .toMutableList()

        // 2. Download anything this device hasn't seen. Objects that don't parse
        // as notes stay note-less and are left untouched.
        val needed = SyncPlanner.keysNeedingDownload(listing, syncState).toSet()
        for (i in listing.indices) {
            val key = listing[i].key
            if (key !in needed) continue
            val got = client.get(key)
            val text = String(got.data, Charsets.UTF_8)
            listing[i] = listing[i].copy(
                etag = got.etag,
                note = NoteDocument.note(text, relativePath = SyncPlanner.relativePath(key) ?: ""),
            )
        }

        val plan = SyncPlanner.plan(store.allNotes, listing, syncState)

        // 3. Uploads. A 412 means another device wrote concurrently — set aside
        // and retry after deletes may have freed the key.
        var uploaded = 0
        val blocked = mutableListOf<SyncPlanner.Upload>()
        for (upload in plan.uploads) {
            try {
                performUpload(upload, syncState); uploaded++
            } catch (e: S3Error.PreconditionFailed) {
                blocked.add(upload)
            }
        }

        // 4. Apply remote changes locally, stashing any displaced local edit
        // into .versions/ so a lost conflict is never lost data.
        for (apply in plan.applyLocally) {
            apply.displacedLocal?.let { displaced ->
                val name = NoteNaming.sanitize(displaced.title)
                runCatching {
                    client.put(versionKey(name), NoteDocument.serialize(displaced).toByteArray())
                }
            }
            store.applyRemote(apply.note)
            syncState[apply.note.id] = SyncState.Entry(apply.key, apply.etag, apply.note.modifiedAt)
        }

        // 5. Deletions last, so an upload failure never orphans a note.
        for (key in plan.deleteRemoteKeys) {
            if (key.startsWith(SyncPlanner.NOTES_PREFIX)) versionCopy(key)
            runCatching { client.delete(key) }
        }

        // 6. Retry uploads that hit a taken key — a rename in step 5 may have
        // just freed it. Whatever still fails heals next sync.
        var unresolved = 0
        for (upload in blocked) {
            try {
                performUpload(upload, syncState); uploaded++
            } catch (e: Exception) {
                unresolved++
            }
        }

        syncState.save(stateFile)
        return Result(uploaded, plan.applyLocally.size, plan.deleteRemoteKeys.size, unresolved)
    }

    private fun performUpload(upload: SyncPlanner.Upload, syncState: SyncState) {
        if (upload.expectedETag != null) versionCopy(upload.key)
        val etag = client.put(
            key = upload.key,
            data = NoteDocument.serialize(upload.note).toByteArray(),
            ifMatch = upload.expectedETag,
            ifNoneMatch = upload.expectedETag == null,
        )
        syncState[upload.note.id] = SyncState.Entry(upload.key, etag, upload.note.modifiedAt)
    }

    // MARK: - Versioning

    /**
     * Best-effort copy of the current object into `.versions/<name>/`, pruned
     * to the newest [versionCap] entries.
     */
    private fun versionCopy(key: String) {
        if (!key.startsWith(SyncPlanner.NOTES_PREFIX)) return
        val name = key.removePrefix(SyncPlanner.NOTES_PREFIX).removeSuffix(".md")
        runCatching { client.copy(key, versionKey(name)) }

        val prefix = SyncPlanner.VERSIONS_PREFIX + name + "/"
        val versions = runCatching { client.list(prefix) }.getOrNull() ?: return
        if (versions.size <= versionCap) return
        // Timestamped names sort lexically — oldest first.
        versions.sortedBy { it.key }.take(versions.size - versionCap).forEach { old ->
            runCatching { client.delete(old.key) }
        }
    }

    private fun versionKey(name: String): String =
        SyncPlanner.VERSIONS_PREFIX + name + "/" + versionStamp.format(Instant.now()) + ".md"
}
