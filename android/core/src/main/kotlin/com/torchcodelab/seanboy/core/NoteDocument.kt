package com.torchcodelab.seanboy.core

import java.time.Instant
import java.time.ZoneOffset
import java.time.format.DateTimeFormatter
import java.util.UUID

/**
 * Serializes notes to/from Markdown files with a YAML-style frontmatter block.
 * Seanboy manages only its own keys and preserves everything else (Obsidian
 * tags, aliases, custom fields) verbatim:
 *
 * ```
 * ---
 * id: 8F6B...            ← managed (or `seanboy-id` if `id` is foreign)
 * created: 2026-07-17T12:00:00Z
 * modified: 2026-07-17T12:34:56Z
 * tags:                  ← unmanaged, preserved byte-for-byte
 *   - journal
 * ---
 *
 * Markdown body...
 * ```
 *
 * The title is NOT stored — the filename owns it.
 *
 * Faithful Kotlin port of `mac/Sources/SeanboyCore/NoteDocument.swift`.
 */
object NoteDocument {
    const val DELIMITER = "---"

    /**
     * Always writes fractional seconds + `Z`, matching Swift's
     * `ISO8601DateFormatter` with `.withFractionalSeconds`
     * (e.g. `2026-07-17T12:34:56.000Z`).
     */
    private val outputFormatter: DateTimeFormatter =
        DateTimeFormatter.ofPattern("yyyy-MM-dd'T'HH:mm:ss.SSSX").withZone(ZoneOffset.UTC)

    private val UUID_PATTERN = Regex(
        "^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$",
    )

    /** Strict 8-4-4-4-12 parse, mirroring Swift's `UUID(uuidString:)`. */
    private fun parseUuid(value: String): UUID? =
        if (UUID_PATTERN.matches(value)) runCatching { UUID.fromString(value) }.getOrNull() else null

    /** Uppercase canonical form, matching Swift's `UUID.uuidString`. */
    fun uuidString(id: UUID): String = id.toString().uppercase()

    fun parseDate(string: String): Instant? =
        runCatching { Instant.from(DateTimeFormatter.ISO_INSTANT.parse(string)) }.getOrNull()
            ?: runCatching { java.time.OffsetDateTime.parse(string).toInstant() }.getOrNull()

    fun formatDate(instant: Instant): String = outputFormatter.format(instant)

    // MARK: - Parsing

    /**
     * Everything a file can tell us. Total — any text parses; a file with no
     * frontmatter is all body with a null [id] (needs adoption).
     */
    data class Parsed(
        var id: UUID? = null,
        var created: Instant? = null,
        var modified: Instant? = null,
        var deleted: Boolean = false,
        /** Legacy `title:` value from the pre-v3 format; never written back. */
        var legacyTitle: String? = null,
        /** Unmanaged frontmatter lines, verbatim and in order. */
        var extraFrontmatter: MutableList<String> = mutableListOf(),
        var body: String = "",
    )

    fun parse(text: String): Parsed {
        val parsed = Parsed()
        val lines = text.split("\n")

        val closing = if (lines.firstOrNull()?.trim() == DELIMITER) {
            lines.drop(1).indexOfFirst { it.trim() == DELIMITER }.let { idx ->
                if (idx < 0) -1 else idx + 1 // account for drop(1)
            }
        } else {
            -1
        }

        if (closing < 0) {
            parsed.body = text
            return parsed
        }

        for (line in lines.subList(1, closing)) {
            // Managed keys sit at zero indentation; anything else (indented YAML
            // continuations, lists, unknown keys) is preserved verbatim.
            val colon = line.indexOf(':')
            if (line.startsWith(" ") || line.startsWith("\t") || colon < 0) {
                parsed.extraFrontmatter.add(line)
                continue
            }
            val key = line.substring(0, colon).trim()
            val value = line.substring(colon + 1).trim()

            when (key) {
                "seanboy-id" -> parseUuid(value)?.let { parsed.id = it }
                "id" -> {
                    val uuid = if (parsed.id == null) parseUuid(value) else null
                    if (uuid != null) {
                        parsed.id = uuid
                    } else {
                        // Foreign id (non-UUID, or ours already found) — keep it.
                        parsed.extraFrontmatter.add(line)
                    }
                }
                "created" -> {
                    parsed.created = parseDate(value)
                    if (parsed.created == null) parsed.extraFrontmatter.add(line)
                }
                "modified" -> {
                    parsed.modified = parseDate(value)
                    if (parsed.modified == null) parsed.extraFrontmatter.add(line)
                }
                "deleted" -> parsed.deleted = value == "true"
                "title" -> parsed.legacyTitle = value
                else -> parsed.extraFrontmatter.add(line)
            }
        }

        val bodyLines = lines.subList(closing + 1, lines.size).toMutableList()
        if (bodyLines.firstOrNull()?.isEmpty() == true) bodyLines.removeAt(0)
        parsed.body = bodyLines.joinToString("\n")
        return parsed
    }

    /**
     * Builds a [Note] from file text. `null` when the file has no adoptable
     * identity AND [fallbackID] is null — callers adopting foreign files pass a
     * fresh UUID. Timestamps fall back to the file's fs dates.
     */
    fun note(
        text: String,
        relativePath: String,
        fallbackID: UUID? = null,
        fsCreated: Instant? = null,
        fsModified: Instant? = null,
    ): Note? {
        val parsed = parse(text)
        val id = parsed.id ?: fallbackID ?: return null
        val modified = parsed.modified ?: fsModified ?: Note.nowMillis()
        return Note(
            id = id,
            relativePath = relativePath,
            body = parsed.body,
            createdAt = parsed.created ?: fsCreated ?: modified,
            modifiedAt = modified,
            isDeleted = parsed.deleted,
            extraFrontmatter = parsed.extraFrontmatter.toList(),
        )
    }

    // MARK: - Serialization

    fun serialize(note: Note): String {
        val lines = mutableListOf(DELIMITER)
        // If the note carries a foreign `id:` line among its extras, write ours
        // as `seanboy-id` so the file never has a duplicate key.
        val hasForeignID = note.extraFrontmatter.any { line ->
            !line.startsWith(" ") && !line.startsWith("\t") &&
                line.substringBefore(':', "").trim() == "id"
        }
        lines.add("${if (hasForeignID) "seanboy-id" else "id"}: ${uuidString(note.id)}")
        lines.add("created: ${formatDate(note.createdAt)}")
        lines.add("modified: ${formatDate(note.modifiedAt)}")
        if (note.isDeleted) {
            lines.add("deleted: true")
        }
        lines.addAll(note.extraFrontmatter)
        lines.add(DELIMITER)
        lines.add("")
        lines.add(note.body)
        return lines.joinToString("\n")
    }
}
