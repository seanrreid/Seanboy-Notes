package com.torchcodelab.seanboy.core

import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import java.io.File
import java.time.Instant

/**
 * Ported from `mac/Tests/SeanboyCoreTests/NoteStoreTests.swift`
 * (NoteNamingTests + NoteStoreTests). The Mac-only `LegacyMigration` suite is
 * intentionally not ported — migrating old uuid.md files is a desktop concern
 * (an Android non-goal); the phone starts fresh.
 */
class NoteNamingTest {
    @Test
    fun titleDerivesFromFilename() {
        val note = Note(relativePath = "Journal/2026/July Notes.md")
        assertEquals("July Notes", note.title)
        assertEquals("Journal/2026", note.folder)
    }

    @Test
    fun settingTitleMovesWithinFolder() {
        val note = Note(relativePath = "Journal/Old.md").withTitle("New Name")
        assertEquals("Journal/New Name.md", note.relativePath)
    }

    @Test
    fun sanitization() {
        assertEquals("a-b- plan", NoteNaming.sanitize("a/b: plan"))
        assertEquals("hidden", NoteNaming.sanitize("  .hidden  "))
        assertEquals("Untitled", NoteNaming.sanitize(""))
    }
}

class NoteStoreTest {
    private lateinit var base: File
    private lateinit var directory: File
    private lateinit var tombstoneFile: File

    @Before
    fun setUp() {
        base = File.createTempFile("SeanboyStoreTests", "").let { f ->
            f.delete(); File(f.parentFile, f.name + "-dir")
        }
        directory = File(base, "Notes")
        tombstoneFile = File(base, "tombstones.json")
        directory.mkdirs()
    }

    @After
    fun tearDown() {
        base.deleteRecursively()
    }

    private fun makeStore(): NoteStore = NoteStore(directory, tombstoneFile)

    private fun writeFile(path: String, contents: String) {
        val f = File(directory, path)
        f.parentFile?.mkdirs()
        f.writeText(contents)
    }

    @Test
    fun createWritesHumanFilename() {
        val store = makeStore()
        val note = store.create(title = "Grocery List", body = "milk")
        assertEquals("Grocery List.md", note.relativePath)
        assertTrue(File(directory, "Grocery List.md").exists())

        val reloaded = makeStore()
        assertEquals("milk", reloaded.note(note.id)?.body)
        assertEquals("Grocery List", reloaded.note(note.id)?.title)
    }

    @Test
    fun recursiveScanFindsNestedNotes() {
        writeFile("Journal/2026/July.md", "# July\n\nentry")
        writeFile("Projects/Seanboy.md", "notes app")
        writeFile("root.md", "top-level")
        val store = makeStore()

        assertEquals(3, store.activeNotes.size)
        assertNotNull(store.noteAtPath("Journal/2026/July.md"))
        assertEquals("July", store.noteAtPath("Journal/2026/July.md")?.title)
    }

    @Test
    fun adoptionInjectsIDPreservingContent() {
        writeFile(
            "Journal/Daily.md",
            """
            ---
            tags:
              - journal
            ---

            Obsidian body.
            """.trimIndent(),
        )
        val store = makeStore()
        val note = store.noteAtPath("Journal/Daily.md")!!
        assertEquals("Obsidian body.", note.body)
        assertEquals(listOf("tags:", "  - journal"), note.extraFrontmatter)

        val text = File(directory, "Journal/Daily.md").readText()
        assertTrue(text.contains("id: ${NoteDocument.uuidString(note.id)}"))
        assertTrue(text.contains("  - journal"))
        assertTrue(text.contains("Obsidian body."))

        // Adoption is stable: a second store sees the same id.
        val again = makeStore()
        assertEquals(note.id, again.noteAtPath("Journal/Daily.md")?.id)
    }

    @Test
    fun titleEditRenamesFile() {
        val store = makeStore()
        val note = store.create(title = "Draft", body = "text")
        store.update(note.withTitle("Final"))

        assertFalse(File(directory, "Draft.md").exists())
        assertTrue(File(directory, "Final.md").exists())
        assertEquals("Final", store.note(note.id)?.title)
        assertNull(store.noteAtPath("Draft.md"))
    }

    @Test
    fun caseOnlyRename() {
        val store = makeStore()
        val note = store.create(title = "readme")
        store.update(note.withTitle("README"))
        assertEquals("README", store.note(note.id)?.title)
        val listing = directory.list()!!.filter { it.endsWith(".md") }
        assertEquals(listOf("README.md"), listing)
    }

    @Test
    fun deleteRemovesFileAndRecordsTombstone() {
        val store = makeStore()
        val note = store.create(title = "Doomed")
        store.delete(note.id)

        assertFalse(File(directory, "Doomed.md").exists())
        assertTrue(store.tombstones.contains(note.id))
        assertTrue(store.allNotes.any { it.id == note.id && it.isDeleted })
        val mdFiles = directory.list()!!.filter { it.endsWith(".md") }
        assertTrue(mdFiles.isEmpty())
    }

    @Test
    fun externalEditPicksUpNewBody() {
        val store = makeStore()
        val note = store.create(title = "Shared", body = "original")
        val file = File(directory, "Shared.md")
        file.writeText(file.readText().replace("original", "edited externally"))
        file.setLastModified(System.currentTimeMillis() + 10_000)

        assertTrue(store.reload())
        assertEquals("edited externally", store.note(note.id)?.body)
    }

    @Test
    fun externalRenameMatchedByID() {
        val store = makeStore()
        val note = store.create(title = "Before", body = "same content")
        File(directory, "Archive").mkdirs()
        File(directory, "Before.md").renameTo(File(directory, "Archive/After.md"))

        assertTrue(store.reload())
        val moved = store.note(note.id)!!
        assertEquals("Archive/After.md", moved.relativePath)
        assertEquals("After", moved.title)
        assertFalse(store.tombstones.contains(note.id))
    }

    @Test
    fun externalDeleteRecordsTombstone() {
        val store = makeStore()
        val note = store.create(title = "Removed Outside")
        File(directory, "Removed Outside.md").delete()

        assertTrue(store.reload())
        assertNull(store.note(note.id))
        assertTrue(store.tombstones.contains(note.id))
    }

    @Test
    fun reloadWithoutChangesIsQuiet() {
        val store = makeStore()
        store.create(title = "Stable")
        var fired = false
        store.onChange = { fired = true }
        assertFalse(store.reload())
        assertFalse(fired)
    }

    @Test
    fun uniqueTitlesPerFolderOnly() {
        val store = makeStore()
        val a = store.create(title = "Ideas")
        val b = store.create(title = "Ideas")
        assertEquals("Ideas", a.title)
        assertEquals("Ideas 2", b.title)
        val c = store.create(title = "Ideas", folder = "Projects")
        assertEquals("Projects/Ideas.md", c.relativePath)
    }

    @Test
    fun wikiLinkResolutionAcrossFoldersMostRecentWins() {
        writeFile("Journal/Ideas.md", "old")
        writeFile("Projects/Ideas.md", "new")
        val store = makeStore()
        val older = store.noteAtPath("Journal/Ideas.md")!!
        store.update(older.copy(modifiedAt = Instant.now().minusSeconds(3600)), touchModified = false)
        val newer = store.noteAtPath("Projects/Ideas.md")!!
        store.update(newer.copy(modifiedAt = Instant.now()), touchModified = false)

        assertEquals("Projects/Ideas.md", store.noteTitled("Ideas")?.relativePath)
        assertEquals("Journal/Ideas.md", store.noteTitled("Journal/Ideas")?.relativePath)
    }

    @Test
    fun applyRemoteTombstoneRemovesFile() {
        val store = makeStore()
        val note = store.create(title = "Synced Away")
        store.applyRemote(note.copy(isDeleted = true, modifiedAt = Instant.now()))

        assertNull(store.note(note.id))
        assertFalse(File(directory, "Synced Away.md").exists())
        assertTrue(store.tombstones.contains(note.id))
    }

    @Test
    fun applyRemoteMoveRelocatesFile() {
        val store = makeStore()
        val note = store.create(title = "Mobile", body = "v1")
        store.applyRemote(note.copy(relativePath = "Archive/Mobile.md", body = "v2"))

        assertEquals("Archive/Mobile.md", store.note(note.id)?.relativePath)
        assertEquals("v2", store.note(note.id)?.body)
        assertFalse(File(directory, "Mobile.md").exists())
    }
}
