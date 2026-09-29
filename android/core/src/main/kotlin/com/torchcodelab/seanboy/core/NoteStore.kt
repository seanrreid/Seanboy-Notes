package com.torchcodelab.seanboy.core

import java.io.File
import java.nio.file.Files
import java.nio.file.attribute.BasicFileAttributes
import java.time.Instant
import java.util.UUID

/**
 * Local-first storage over a folder of human-named Markdown files
 * (`Journal/2026/July.md`), scanned recursively. The files are the source of
 * truth; the store is an in-memory index that writes through on every mutation.
 *
 * Kotlin port of `mac/Sources/SeanboyCore/NoteStore.swift`, adapted for
 * Android's app-private folder: there is no system Trash, so [delete] removes
 * the file and records a tombstone outside the folder (the user's directory
 * only ever contains live notes). `reload()` still reconciles the folder so
 * pre-seeded or externally-synced files are adopted.
 */
class NoteStore(
    val directory: File,
    tombstoneFile: File,
) {
    val tombstones: TombstoneStore = TombstoneStore(tombstoneFile)

    private val _notesByID: MutableMap<UUID, Note> = mutableMapOf()
    val notesByID: Map<UUID, Note> get() = _notesByID

    private val idByPath: MutableMap<String, UUID> = mutableMapOf()

    /** fs mtime last seen per path — lets reconcile skip unchanged files. */
    private val fsModifiedByPath: MutableMap<String, Instant> = mutableMapOf()

    /** Called after any mutation (create/update/delete/reload/merge). */
    var onChange: (() -> Unit)? = null

    init {
        directory.mkdirs()
        reload()
    }

    // MARK: - Queries

    /** All live notes, most recently modified first. */
    val activeNotes: List<Note>
        get() = _notesByID.values.sortedByDescending { it.modifiedAt }

    /**
     * Live notes plus tombstone records (as deleted [Note]s) — the sync
     * engine's view of this device.
     */
    val allNotes: List<Note>
        get() {
            val all = _notesByID.values.toMutableList()
            for ((id, deletedAt) in tombstones.deletedAtByID) {
                if (!_notesByID.containsKey(id)) {
                    all.add(
                        Note(
                            id = id, relativePath = "", body = "",
                            createdAt = deletedAt, modifiedAt = deletedAt, isDeleted = true,
                        ),
                    )
                }
            }
            return all
        }

    fun note(id: UUID): Note? = _notesByID[id]

    fun noteAtPath(path: String): Note? = idByPath[path.lowercase()]?.let { _notesByID[it] }

    /**
     * Wiki-link resolution. `[[Title]]` matches by filename anywhere in the tree
     * (most recently modified wins on ambiguity); `[[folder/Title]]` pins the
     * exact path.
     */
    fun noteTitled(title: String): Note? {
        val needle = title.trim()
        if (needle.isEmpty()) return null
        if (needle.contains("/")) {
            return noteAtPath("$needle.md") ?: noteAtPath(needle)
        }
        val lowered = needle.lowercase()
        return activeNotes.firstOrNull { it.title.lowercase() == lowered }
    }

    // MARK: - Mutations

    fun create(title: String, body: String = "", folder: String = ""): Note {
        val unique = uniqueTitle(title, folder)
        val note = Note.fromTitle(title = unique, folder = folder, body = body)
        write(note)
        return note
    }

    /**
     * Persists an edit. A changed [Note.relativePath] (title edit or move)
     * renames the file on disk.
     */
    fun update(note: Note, touchModified: Boolean = true) {
        val updated = if (touchModified) note.copy(modifiedAt = Note.nowMillis()) else note
        val existing = _notesByID[note.id]
        if (existing != null && existing.relativePath != updated.relativePath) {
            moveFile(existing.relativePath, updated.relativePath)
            idByPath.remove(existing.relativePath.lowercase())
            fsModifiedByPath.remove(existing.relativePath)
        }
        write(updated)
    }

    /** Removes the file and records a tombstone so the deletion syncs. */
    fun delete(id: UUID) {
        val note = _notesByID[id] ?: return
        deleteFile(note.relativePath)
        removeFromIndex(note)
        tombstones.record(id, Note.nowMillis())
        onChange?.invoke()
    }

    /** Applies a note coming from the sync engine verbatim. */
    fun applyRemote(note: Note) {
        if (note.isDeleted) {
            _notesByID[note.id]?.let { existing ->
                deleteFile(existing.relativePath)
                removeFromIndex(existing)
            }
            tombstones.record(note.id, note.modifiedAt)
            onChange?.invoke()
            return
        }
        tombstones.clear(note.id) // resurrection cancels the tombstone
        val existing = _notesByID[note.id]
        if (existing != null && existing.relativePath != note.relativePath) {
            moveFile(existing.relativePath, note.relativePath)
            idByPath.remove(existing.relativePath.lowercase())
            fsModifiedByPath.remove(existing.relativePath)
        }
        write(note)
    }

    // MARK: - Disk

    /**
     * Recursive scan reconciled against the in-memory index. Adopts foreign
     * Markdown (injects an `id`), matches external renames by id, treats
     * vanished files as deletions (except on first load). Returns whether
     * anything actually changed; fires [onChange] only then.
     */
    fun reload(): Boolean {
        val firstLoad = _notesByID.isEmpty() && idByPath.isEmpty()
        val scanned = mutableMapOf<UUID, Note>()
        val scannedPaths = mutableMapOf<String, UUID>()
        val scannedMtimes = mutableMapOf<String, Instant>()

        for (file in markdownFiles()) {
            val path = relativePathOf(file)
            val mtime = Instant.ofEpochMilli(file.lastModified())

            // Unchanged since last seen — reuse the in-memory note.
            val knownMtime = fsModifiedByPath[path]
            val knownID = idByPath[path.lowercase()]
            val known = knownID?.let { _notesByID[it] }
            if (knownMtime != null && knownMtime == mtime && known != null) {
                scanned[known.id] = known
                scannedPaths[path.lowercase()] = known.id
                scannedMtimes[path] = mtime
                continue
            }

            val text = runCatching { file.readText() }.getOrNull() ?: continue
            val parsed = NoteDocument.parse(text)
            val created = parsed.created ?: fsCreated(file) ?: mtime
            var note: Note
            if (parsed.id != null) {
                // mtime wins over frontmatter when an external editor touched the
                // file without updating the header.
                val modified = if (isExternallyEdited(parsed, mtime)) mtime else (parsed.modified ?: mtime)
                note = Note(
                    id = parsed.id!!, relativePath = path, body = parsed.body,
                    createdAt = created, modifiedAt = modified, isDeleted = false,
                    extraFrontmatter = parsed.extraFrontmatter.toList(),
                )
            } else {
                // Foreign Markdown — adopt: inject an id, keep everything else.
                note = Note(
                    id = UUID.randomUUID(), relativePath = path, body = parsed.body,
                    createdAt = created, modifiedAt = parsed.modified ?: mtime, isDeleted = false,
                    extraFrontmatter = parsed.extraFrontmatter.toList(),
                )
                runCatching { file.writeText(NoteDocument.serialize(note)) }
            }
            if (scanned.containsKey(note.id)) {
                // Same id at two paths (a duplicated file) — keep the first,
                // re-adopt the copy under a fresh id.
                note = note.copy(id = UUID.randomUUID())
                runCatching { file.writeText(NoteDocument.serialize(note)) }
            }
            scanned[note.id] = note
            scannedPaths[path.lowercase()] = note.id
            scannedMtimes[path] = Instant.ofEpochMilli(file.lastModified())
        }

        // Vanished files = external deletions (never on first load).
        var changed = false
        if (!firstLoad) {
            for (id in _notesByID.keys) {
                if (!scanned.containsKey(id)) {
                    tombstones.record(id, Note.nowMillis())
                    changed = true
                }
            }
        }

        if (scanned != _notesByID) changed = true
        _notesByID.clear(); _notesByID.putAll(scanned)
        idByPath.clear(); idByPath.putAll(scannedPaths)
        fsModifiedByPath.clear(); fsModifiedByPath.putAll(scannedMtimes)
        // A note that came back (file restored, undo of a delete) cancels its tombstone.
        for (id in scanned.keys) {
            if (tombstones.contains(id)) {
                tombstones.clear(id)
                changed = true
            }
        }
        if (changed || firstLoad) onChange?.invoke()
        return changed
    }

    fun fileFor(path: String): File = File(directory, path)

    fun fileFor(id: UUID): File? = _notesByID[id]?.let { fileFor(it.relativePath) }

    // MARK: - Private

    private fun markdownFiles(): List<File> =
        directory.walkTopDown()
            .onEnter { it == directory || !it.name.startsWith(".") }
            .filter { it.isFile && !it.name.startsWith(".") && it.extension.lowercase() == "md" }
            .toList()

    private fun fsCreated(file: File): Instant? = runCatching {
        Files.readAttributes(file.toPath(), BasicFileAttributes::class.java).creationTime().toInstant()
    }.getOrNull()

    /** An external edit bumped the fs mtime past what our frontmatter says. */
    private fun isExternallyEdited(parsed: NoteDocument.Parsed, mtime: Instant): Boolean {
        val recorded = parsed.modified ?: return true
        return (mtime.toEpochMilli() - recorded.toEpochMilli()) / 1000.0 > 1.5
    }

    private fun relativePathOf(file: File): String =
        file.relativeToOrNull(directory)?.invariantSeparatorsPath ?: file.name

    private fun write(note: Note) {
        val file = fileFor(note.relativePath)
        runCatching {
            file.parentFile?.mkdirs()
            file.writeText(NoteDocument.serialize(note))
            _notesByID[note.id] = note
            idByPath[note.relativePath.lowercase()] = note.id
            fsModifiedByPath[note.relativePath] = Instant.ofEpochMilli(file.lastModified())
            onChange?.invoke()
        }
    }

    private fun moveFile(oldPath: String, newPath: String) {
        val source = fileFor(oldPath)
        val target = fileFor(newPath)
        if (!source.exists()) return
        target.parentFile?.mkdirs()
        if (oldPath.lowercase() == newPath.lowercase() && oldPath != newPath) {
            // Case-only rename on a case-insensitive filesystem needs a hop.
            val hop = File(source.parentFile, ".seanboy-rename-${UUID.randomUUID()}")
            if (source.renameTo(hop)) hop.renameTo(target)
        } else {
            source.renameTo(target)
        }
    }

    private fun deleteFile(path: String) {
        val file = fileFor(path)
        if (file.exists()) file.delete()
    }

    private fun removeFromIndex(note: Note) {
        _notesByID.remove(note.id)
        idByPath.remove(note.relativePath.lowercase())
        fsModifiedByPath.remove(note.relativePath)
    }

    /** "New Note", "New Note 2", … unique within [folder]. */
    private fun uniqueTitle(base: String, folder: String): String {
        val trimmed = base.trim()
        val candidate = trimmed.ifEmpty { "New Note" }
        fun taken(title: String): Boolean {
            val filename = NoteNaming.filename(title)
            val path = if (folder.isEmpty()) filename else "$folder/$filename"
            return idByPath[path.lowercase()] != null
        }
        if (!taken(candidate)) return candidate
        var n = 2
        while (taken("$candidate $n")) n++
        return "$candidate $n"
    }
}
