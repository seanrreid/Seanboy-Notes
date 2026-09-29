package com.torchcodelab.seanboy.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.UUID

/**
 * Ported from `mac/Tests/SeanboyCoreTests/NoteStoreTests.swift`
 * (`NoteDocumentTests`) — the frontmatter round-trip and Obsidian-preservation
 * contract must hold identically on Android so notes interoperate.
 */
class NoteDocumentTest {

    @Test
    fun roundTrip() {
        val note = Note.fromTitle(title = "Groceries", body = "- Milk\n- Eggs\n\n[[Recipes]]")
        val text = NoteDocument.serialize(note)
        val parsed = NoteDocument.note(text, relativePath = "Groceries.md")
        assertTrue(parsed != null)
        assertEquals(note.id, parsed!!.id)
        assertEquals("Groceries", parsed.title)
        assertEquals(note.body, parsed.body)
        assertFalse(parsed.isDeleted)
        assertEquals(note.modifiedAt, parsed.modifiedAt)
    }

    @Test
    fun tombstoneSerialization() {
        val note = Note.fromTitle(title = "Gone").copy(isDeleted = true)
        val parsed = NoteDocument.parse(NoteDocument.serialize(note))
        assertTrue(parsed.deleted)
    }

    @Test
    fun bodyContainingFrontmatterDelimiter() {
        val note = Note.fromTitle(title = "Tricky", body = "intro\n---\noutro")
        val parsed = NoteDocument.note(NoteDocument.serialize(note), relativePath = "Tricky.md")
        assertEquals("intro\n---\noutro", parsed!!.body)
    }

    @Test
    fun noFrontmatterIsAllBodyNeedingAdoption() {
        val parsed = NoteDocument.parse("# Just Markdown\n\nNo header at all.")
        assertNull(parsed.id)
        assertEquals("# Just Markdown\n\nNo header at all.", parsed.body)
    }

    @Test
    fun obsidianFrontmatterPreservedVerbatim() {
        val obsidian = """
            ---
            tags:
              - journal
              - ideas
            aliases: [JRN, Daily]
            cssclass: wide
            created: not-a-date-obsidian-style
            ---

            Body text here.
        """.trimIndent()

        val parsed = NoteDocument.parse(obsidian)
        assertNull(parsed.id)
        // Every unmanaged line survives, order intact — including the
        // unparseable `created:` value, kept as a foreign line.
        assertEquals(
            listOf(
                "tags:",
                "  - journal",
                "  - ideas",
                "aliases: [JRN, Daily]",
                "cssclass: wide",
                "created: not-a-date-obsidian-style",
            ),
            parsed.extraFrontmatter,
        )
        assertEquals("Body text here.", parsed.body)

        // Adoption injects only our managed keys; extras ride along verbatim.
        val adopted = NoteDocument.note(obsidian, relativePath = "Journal/Daily.md", fallbackID = UUID.randomUUID())!!
        val rewritten = NoteDocument.serialize(adopted)
        for (line in parsed.extraFrontmatter) {
            assertTrue("lost line: $line", rewritten.contains(line))
        }
        val reparsed = NoteDocument.parse(rewritten)
        assertEquals(parsed.extraFrontmatter, reparsed.extraFrontmatter)
        assertEquals(adopted.id, reparsed.id)
        assertEquals("Body text here.", reparsed.body)
    }

    @Test
    fun foreignIdStaysOursGoesUnderSeanboyId() {
        val text = """
            ---
            id: 20240811-obsidian-zettel
            ---

            body
        """.trimIndent()

        val adopted = NoteDocument.note(text, relativePath = "Zettel.md", fallbackID = UUID.randomUUID())!!
        val rewritten = NoteDocument.serialize(adopted)
        assertTrue(rewritten.contains("id: 20240811-obsidian-zettel"))
        assertTrue(rewritten.contains("seanboy-id: ${NoteDocument.uuidString(adopted.id)}"))

        val reparsed = NoteDocument.parse(rewritten)
        assertEquals(adopted.id, reparsed.id)
        assertTrue(reparsed.extraFrontmatter.contains("id: 20240811-obsidian-zettel"))
    }

    @Test
    fun legacyTitleReadButNeverWritten() {
        val legacy = """
            ---
            id: ${UUID.randomUUID()}
            title: Old Style Note
            created: 2026-07-17T12:00:00Z
            modified: 2026-07-17T12:34:56Z
            deleted: false
            ---

            legacy body
        """.trimIndent()

        val parsed = NoteDocument.parse(legacy)
        assertEquals("Old Style Note", parsed.legacyTitle)
        val note = NoteDocument.note(legacy, relativePath = "Old Style Note.md")!!
        assertFalse(NoteDocument.serialize(note).contains("title:"))
    }

    @Test
    fun garbageIsJustBody() {
        val parsed = NoteDocument.parse("")
        assertNull(parsed.id)
        assertEquals("", parsed.body)
    }

    // MARK: - Properties editing (ported from the Mac's NoteStoreTests)

    private fun noteWith(extras: List<String>) =
        Note.fromTitle(title = "Daily", body = "body").copy(extraFrontmatter = extras)

    private fun obsidianNote() = noteWith(listOf("tags:", "  - journal", "aliases: [JRN]", "", "cssclass: wide"))

    @Test
    fun propertiesUnchangedTextIsByteFaithful() {
        val note = noteWith(listOf("tags: x", "", ""))
        val text = NoteDocument.propertiesText(note)
        // Trailing blank lines from the file survive when nothing was edited.
        assertEquals(NoteDocument.FrontmatterEdit.Accepted(listOf("tags: x", "", "")), NoteDocument.editedFrontmatter(text, note))
    }

    @Test
    fun propertiesEditAcceptsNormalYaml() {
        val edited = "tags:\n  - journal\n  - ideas\naliases: [JRN]\nstatus: draft\n\n"
        assertEquals(
            NoteDocument.FrontmatterEdit.Accepted(listOf("tags:", "  - journal", "  - ideas", "aliases: [JRN]", "status: draft")),
            NoteDocument.editedFrontmatter(edited, obsidianNote()),
        )
    }

    @Test
    fun propertiesEditCanClearEverything() {
        assertEquals(NoteDocument.FrontmatterEdit.Accepted(emptyList()), NoteDocument.editedFrontmatter("", obsidianNote()))
    }

    @Test
    fun propertiesEditRejectsBlockTerminator() {
        val result = NoteDocument.editedFrontmatter("tags: x\n---\nmore: y", obsidianNote())
        assertTrue(result is NoteDocument.FrontmatterEdit.Rejected && "---" in result.lines)
    }

    @Test
    fun propertiesEditRejectsManagedKeys() {
        val note = obsidianNote()
        for (line in listOf(
            "created: 2026-01-01T00:00:00Z", "seanboy-id: ${UUID.randomUUID()}", "deleted: true", "title: Sneaky",
        )) {
            assertEquals(line, NoteDocument.FrontmatterEdit.Rejected(listOf(line)), NoteDocument.editedFrontmatter("tags: x\n$line", note))
        }
    }

    @Test
    fun propertiesEditKeepsForeignValuesOfManagedNames() {
        // Values Seanboy can't parse as its own stay the user's.
        assertEquals(
            NoteDocument.FrontmatterEdit.Accepted(listOf("created: last spring", "id: zettel-42")),
            NoteDocument.editedFrontmatter("created: last spring\nid: zettel-42", obsidianNote()),
        )
    }

    @Test
    fun propertyKeys() {
        assertEquals(listOf("tags", "aliases", "cssclass"), NoteDocument.propertyKeys(obsidianNote().extraFrontmatter))
        assertEquals(listOf("a"), NoteDocument.propertyKeys(listOf("# comment: no", "a: 1", "a: 2", "  b: nested")))
    }
}
