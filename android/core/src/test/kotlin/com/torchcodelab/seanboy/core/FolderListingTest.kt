package com.torchcodelab.seanboy.core

import org.junit.Assert.assertEquals
import org.junit.Test

class FolderListingTest {
    private fun note(path: String, deleted: Boolean = false) =
        Note(relativePath = path, isDeleted = deleted)

    private val notes = listOf(
        note("Start Here.md"),
        note("ideas.md"),
        note("Journal/2026/July.md"),
        note("Journal/2026/August.md"),
        note("Journal/Plans.md"),
        note("Projects/Seanboy.md"),
        note("archive/Old.md"),
        note("Gone/Deleted.md", deleted = true),
    )

    @Test
    fun rootListsTopFoldersThenRootNotes() {
        val listing = FolderListing.of(notes, "")
        assertEquals(
            listOf(
                FolderListing.Subfolder("archive", "archive", 1),
                FolderListing.Subfolder("Journal", "Journal", 3),
                FolderListing.Subfolder("Projects", "Projects", 1),
            ),
            listing.subfolders,
        )
        assertEquals(listOf("ideas", "Start Here"), listing.notes.map { it.title })
    }

    @Test
    fun nestedFolderCountsRecursivelyAndListsOwnNotes() {
        val listing = FolderListing.of(notes, "Journal")
        assertEquals(listOf(FolderListing.Subfolder("2026", "Journal/2026", 2)), listing.subfolders)
        assertEquals(listOf("Plans"), listing.notes.map { it.title })
        assertEquals(listOf("August", "July"), FolderListing.of(notes, "Journal/2026").notes.map { it.title })
    }

    @Test
    fun deletedNotesAndTheirFoldersAreHidden() {
        assertEquals(emptyList<String>(), FolderListing.of(notes, "").subfolders.map { it.name }.filter { it == "Gone" })
    }

    @Test
    fun similarlyNamedFoldersDontLeak() {
        val listing = FolderListing.of(listOf(note("Journal2/x.md"), note("Journal/y.md")), "Journal")
        assertEquals(listOf("y"), listing.notes.map { it.title })
        assertEquals(emptyList<FolderListing.Subfolder>(), listing.subfolders)
    }

    @Test
    fun nearestExistingWalksUpToAFolderWithNotes() {
        assertEquals("Journal/2026", FolderListing.nearestExisting(notes, "Journal/2026"))
        assertEquals("Journal", FolderListing.nearestExisting(notes, "Journal/2025/Q1"))
        assertEquals("", FolderListing.nearestExisting(notes, "Gone"))
        assertEquals("", FolderListing.nearestExisting(notes, ""))
    }

    @Test
    fun parentAndBreadcrumbs() {
        assertEquals("Journal", FolderListing.parent("Journal/2026"))
        assertEquals("", FolderListing.parent("Journal"))
        assertEquals(
            listOf(
                FolderListing.Crumb("Seanboy", ""),
                FolderListing.Crumb("Journal", "Journal"),
                FolderListing.Crumb("2026", "Journal/2026"),
            ),
            FolderListing.breadcrumbs("Journal/2026", rootName = "Seanboy"),
        )
        assertEquals(listOf(FolderListing.Crumb("Seanboy", "")), FolderListing.breadcrumbs("", "Seanboy"))
    }

    @Test
    fun treeIsDepthFirstInSidebarOrder() {
        assertEquals(
            listOf(
                FolderListing.Subfolder("archive", "archive", 1),
                FolderListing.Subfolder("Journal", "Journal", 3),
                FolderListing.Subfolder("2026", "Journal/2026", 2),
                FolderListing.Subfolder("Projects", "Projects", 1),
            ),
            FolderListing.tree(notes),
        )
        assertEquals(1, FolderListing.depth("Journal/2026"))
        assertEquals(0, FolderListing.depth("Journal"))
    }
}
