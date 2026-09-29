package com.torchcodelab.seanboy.core

import java.time.Instant
import java.time.temporal.ChronoUnit
import java.util.UUID

/**
 * A single note. Notes are plain Markdown files in the user's notes folder;
 * the filename (minus `.md`) IS the title, and the path relative to the folder
 * root IS the note's location — locally and in the sync bucket.
 *
 * Faithful Kotlin port of `mac/Sources/SeanboyCore/Note.swift`.
 */
data class Note(
    val id: UUID = UUID.randomUUID(),
    /** Path relative to the notes folder, e.g. `Journal/2026/July.md`. */
    var relativePath: String,
    val body: String = "",
    val createdAt: Instant = nowMillis(),
    val modifiedAt: Instant = nowMillis(),
    /**
     * Deleted notes exist only in memory (from tombstone records or remote
     * tombstone objects) — never as files in the user's folder.
     */
    val isDeleted: Boolean = false,
    /**
     * Frontmatter lines Seanboy doesn't manage (Obsidian tags, aliases, …),
     * preserved verbatim through every save and through sync.
     */
    val extraFrontmatter: List<String> = emptyList(),
) {
    /** The filename minus `.md` — renaming the title moves the file. */
    val title: String
        get() {
            val name = relativePath.substringAfterLast('/')
            return if (name.endsWith(".md")) name.dropLast(3) else name
        }

    /** Containing folder relative to the notes root; "" at the root. */
    val folder: String
        get() {
            val slash = relativePath.lastIndexOf('/')
            return if (slash < 0) "" else relativePath.substring(0, slash)
        }

    /** A copy with the title changed — moves the file within its folder. */
    fun withTitle(newTitle: String): Note {
        val filename = NoteNaming.filename(newTitle)
        val path = if (folder.isEmpty()) filename else "$folder/$filename"
        return copy(relativePath = path)
    }

    companion object {
        /**
         * Convenience for creating a note from a title, at the folder root or
         * inside [folder]. Mirrors the Swift `init(title:folder:…)`.
         */
        fun fromTitle(
            id: UUID = UUID.randomUUID(),
            title: String,
            folder: String = "",
            body: String = "",
            createdAt: Instant = nowMillis(),
            modifiedAt: Instant = nowMillis(),
            isDeleted: Boolean = false,
        ): Note {
            val filename = NoteNaming.filename(title)
            val path = if (folder.isEmpty()) filename else "$folder/$filename"
            return Note(
                id = id,
                relativePath = path,
                body = body,
                createdAt = createdAt,
                modifiedAt = modifiedAt,
                isDeleted = isDeleted,
            )
        }

        /**
         * `Instant.now()` truncated to milliseconds — the precision the
         * frontmatter serializer round-trips (ISO-8601 with fractional
         * seconds), so a serialize→parse cycle is exact.
         */
        internal fun nowMillis(): Instant = Instant.now().truncatedTo(ChronoUnit.MILLIS)
    }
}

/** Title ↔ filename rules shared by the store, sync, and UI. */
object NoteNaming {
    /** A title turned into a safe filename component (no extension). */
    fun sanitize(title: String): String {
        var name = title
            .map { if (it.isISOControl()) ' ' else it }
            .joinToString("")
            .replace("/", "-")
            .replace(":", "-")
            .trim()
        while (name.startsWith(".")) name = name.substring(1)
        if (name.length > 120) name = name.substring(0, 120)
        return name.ifEmpty { "Untitled" }
    }

    fun filename(title: String): String = sanitize(title) + ".md"
}
