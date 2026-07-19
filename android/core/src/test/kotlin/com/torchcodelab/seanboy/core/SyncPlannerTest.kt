package com.torchcodelab.seanboy.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.time.Instant

/** Ported from `mac/Tests/SeanboyCoreTests/SyncPlannerTests.swift`. */
class SyncPlannerTest {

    private val t0: Instant = Instant.ofEpochSecond(1_750_000_000L)
    private fun at(offset: Long): Instant = t0.plusSeconds(offset)

    private fun makeNote(
        title: String,
        body: String = "body",
        created: Long = 0,
        modified: Long = 0,
        deleted: Boolean = false,
    ): Note = Note.fromTitle(
        title = title, body = body,
        createdAt = at(created), modifiedAt = at(modified), isDeleted = deleted,
    )

    private fun stateEntry(note: Note, key: String, etag: String): SyncState {
        val state = SyncState()
        state[note.id] = SyncState.Entry(key = key, etag = etag, modifiedAt = note.modifiedAt)
        return state
    }

    // MARK: - Keys

    @Test
    fun keyMirrorsRelativePath() {
        val note = Note(relativePath = "Journal/2026/July.md")
        assertEquals("notes/Journal/2026/July.md", SyncPlanner.key(note))
        assertEquals("Journal/2026/July.md", SyncPlanner.relativePath("notes/Journal/2026/July.md"))
        assertNull(SyncPlanner.relativePath(".tombstones/x.md"))
    }

    @Test
    fun keyForTombstoneUsesID() {
        val deleted = makeNote("Gone", deleted = true)
        assertEquals(".tombstones/${NoteDocument.uuidString(deleted.id)}.md", SyncPlanner.key(deleted))
    }

    // MARK: - Download selection

    @Test
    fun keysNeedingDownloadSkipsKnownPairs() {
        val note = makeNote("Known")
        val state = stateEntry(note, "notes/Known.md", "e1")
        val listing = listOf(
            SyncPlanner.RemoteFile("notes/Known.md", "e1"),
            SyncPlanner.RemoteFile("notes/Known2.md", "e9"),
            SyncPlanner.RemoteFile("notes/Known.md", "e2"),
        )
        assertEquals(
            listOf("notes/Known2.md", "notes/Known.md"),
            SyncPlanner.keysNeedingDownload(listing, state),
        )
    }

    // MARK: - Planning

    @Test
    fun firstSyncPushesEverythingIncludingTombstones() {
        val live = makeNote("Fresh")
        val dead = makeNote("Dead", deleted = true)
        val plan = SyncPlanner.plan(listOf(live, dead), emptyList(), SyncState())

        assertEquals(2, plan.uploads.size)
        assertTrue(plan.applyLocally.isEmpty())
        assertTrue(plan.deleteRemoteKeys.isEmpty())
        val byID = plan.uploads.associateBy { it.note.id }
        assertEquals("notes/Fresh.md", byID[live.id]?.key)
        assertNull(byID[live.id]?.expectedETag)
        assertEquals(".tombstones/${NoteDocument.uuidString(dead.id)}.md", byID[dead.id]?.key)
    }

    @Test
    fun remoteOnlyNoteIsApplied() {
        val theirs = makeNote("From elsewhere")
        val remote = listOf(SyncPlanner.RemoteFile("notes/From elsewhere.md", "e1", theirs))
        val plan = SyncPlanner.plan(emptyList(), remote, SyncState())

        assertEquals(
            listOf(SyncPlanner.LocalApply(theirs, "notes/From elsewhere.md", "e1")),
            plan.applyLocally,
        )
        assertTrue(plan.uploads.isEmpty())
    }

    @Test
    fun localEditPushesWithIfMatch() {
        val original = makeNote("Edited", modified = 0)
        val state = stateEntry(original, "notes/Edited.md", "e1")
        val note = original.copy(modifiedAt = at(60))
        val remote = listOf(SyncPlanner.RemoteFile("notes/Edited.md", "e1"))

        val plan = SyncPlanner.plan(listOf(note), remote, state)
        assertEquals(listOf(SyncPlanner.Upload(note, "notes/Edited.md", "e1")), plan.uploads)
        assertTrue(plan.applyLocally.isEmpty())
        assertTrue(plan.deleteRemoteKeys.isEmpty())
    }

    @Test
    fun fullySyncedProducesEmptyPlan() {
        val note = makeNote("Stable")
        val state = stateEntry(note, "notes/Stable.md", "e1")
        val remote = listOf(SyncPlanner.RemoteFile("notes/Stable.md", "e1"))
        assertTrue(SyncPlanner.plan(listOf(note), remote, state).isEmpty)
    }

    @Test
    fun remoteEditAppliesEvenWithOlderTimestamp() {
        // Device B's clock is behind, so its edit carries an older modifiedAt.
        // Local is unchanged — the remote edit must still win.
        val note = makeNote("Skewed", modified = 0)
        val state = stateEntry(note, "notes/Skewed.md", "e1")
        val theirs = note.copy(body = "edited on B", modifiedAt = at(-3600))
        val remote = listOf(SyncPlanner.RemoteFile("notes/Skewed.md", "e2", theirs))

        val plan = SyncPlanner.plan(listOf(note), remote, state)
        assertEquals(1, plan.applyLocally.size)
        assertEquals("edited on B", plan.applyLocally.first().note.body)
        assertNull(plan.applyLocally.first().displacedLocal)
        assertTrue(plan.uploads.isEmpty())
    }

    @Test
    fun conflictLocalWins() {
        val base = makeNote("Conflict", modified = 0)
        val state = stateEntry(base, "notes/Conflict.md", "e1")
        val theirs = base.copy(body = "their edit", modifiedAt = at(30))
        val note = base.copy(body = "my edit", modifiedAt = at(60))
        val remote = listOf(SyncPlanner.RemoteFile("notes/Conflict.md", "e2", theirs))

        val plan = SyncPlanner.plan(listOf(note), remote, state)
        assertEquals(listOf(SyncPlanner.Upload(note, "notes/Conflict.md", "e2")), plan.uploads)
        assertTrue(plan.applyLocally.isEmpty())
    }

    @Test
    fun conflictRemoteWinsPreservesDisplacedLocal() {
        val base = makeNote("Conflict", modified = 0)
        val state = stateEntry(base, "notes/Conflict.md", "e1")
        val theirs = base.copy(body = "their edit", modifiedAt = at(60))
        val note = base.copy(body = "my edit", modifiedAt = at(30))
        val remote = listOf(SyncPlanner.RemoteFile("notes/Conflict.md", "e2", theirs))

        val plan = SyncPlanner.plan(listOf(note), remote, state)
        assertEquals(1, plan.applyLocally.size)
        assertEquals("their edit", plan.applyLocally.first().note.body)
        assertEquals("my edit", plan.applyLocally.first().displacedLocal?.body)
    }

    @Test
    fun renameUploadsNewKeyAndDeletesOld() {
        val base = makeNote("Old Title", modified = 0)
        val state = stateEntry(base, "notes/Old Title.md", "e1")
        val note = base.withTitle("New Title").copy(modifiedAt = at(60))
        val remote = listOf(SyncPlanner.RemoteFile("notes/Old Title.md", "e1"))

        val plan = SyncPlanner.plan(listOf(note), remote, state)
        assertEquals(listOf(SyncPlanner.Upload(note, "notes/New Title.md", null)), plan.uploads)
        assertEquals(listOf("notes/Old Title.md"), plan.deleteRemoteKeys)
    }

    @Test
    fun keyReassignmentRelocatesUnchangedNote() {
        // Same title/timestamps, but the key this note should live at changed
        // (e.g. a collision was resolved). It must still relocate.
        val note = makeNote("Moved")
        val state = stateEntry(note, "notes/Stale Name.md", "e1")
        val remote = listOf(SyncPlanner.RemoteFile("notes/Stale Name.md", "e1"))

        val plan = SyncPlanner.plan(listOf(note), remote, state)
        assertEquals(listOf(SyncPlanner.Upload(note, "notes/Moved.md", null)), plan.uploads)
        assertEquals(listOf("notes/Stale Name.md"), plan.deleteRemoteKeys)
    }

    @Test
    fun localDeletePushesTombstoneAndRemovesLiveObject() {
        val base = makeNote("Doomed", modified = 0)
        val state = stateEntry(base, "notes/Doomed.md", "e1")
        val note = base.copy(isDeleted = true, modifiedAt = at(60))
        val remote = listOf(SyncPlanner.RemoteFile("notes/Doomed.md", "e1"))

        val plan = SyncPlanner.plan(listOf(note), remote, state)
        assertEquals(
            listOf(SyncPlanner.Upload(note, ".tombstones/${NoteDocument.uuidString(note.id)}.md", null)),
            plan.uploads,
        )
        assertEquals(listOf("notes/Doomed.md"), plan.deleteRemoteKeys)
    }

    @Test
    fun remoteTombstoneApplies() {
        val base = makeNote("Deleted elsewhere", modified = 0)
        val state = stateEntry(base, "notes/Deleted elsewhere.md", "e1")
        val theirs = base.copy(isDeleted = true, modifiedAt = at(60))
        val key = ".tombstones/${NoteDocument.uuidString(base.id)}.md"
        val remote = listOf(SyncPlanner.RemoteFile(key, "t1", theirs))

        val plan = SyncPlanner.plan(listOf(base), remote, state)
        assertEquals(1, plan.applyLocally.size)
        assertEquals(true, plan.applyLocally.first().note.isDeleted)
        assertEquals(key, plan.applyLocally.first().key)
    }

    @Test
    fun editAfterRemoteDeleteResurrectsNote() {
        val base = makeNote("Lazarus", modified = 0)
        val state = stateEntry(base, "notes/Lazarus.md", "e1")
        val theirs = base.copy(isDeleted = true, modifiedAt = at(30))
        val note = base.copy(body = "edited after their delete", modifiedAt = at(60))
        val tombstoneKey = ".tombstones/${NoteDocument.uuidString(base.id)}.md"
        val remote = listOf(SyncPlanner.RemoteFile(tombstoneKey, "t1", theirs))

        val plan = SyncPlanner.plan(listOf(note), remote, state)
        assertEquals(listOf(SyncPlanner.Upload(note, "notes/Lazarus.md", null)), plan.uploads)
        assertEquals(listOf(tombstoneKey), plan.deleteRemoteKeys)
    }

    @Test
    fun vanishedRemoteObjectIsRestored() {
        val note = makeNote("Vanished")
        val state = stateEntry(note, "notes/Vanished.md", "e1")

        val plan = SyncPlanner.plan(listOf(note), emptyList(), state)
        assertEquals(listOf(SyncPlanner.Upload(note, "notes/Vanished.md", null)), plan.uploads)
    }

    @Test
    fun stateLossRecognizesEquivalentNotes() {
        val note = makeNote("Recovered")
        val remote = listOf(SyncPlanner.RemoteFile("notes/Recovered.md", "e1", note))

        val plan = SyncPlanner.plan(listOf(note), remote, SyncState())
        assertTrue(plan.uploads.isEmpty())
        assertEquals(
            listOf(SyncPlanner.LocalApply(note, "notes/Recovered.md", "e1")),
            plan.applyLocally,
        )
    }

    @Test
    fun duplicateRemoteObjectsKeepNewest() {
        val base = makeNote("Dup", modified = 60)
        val older = base.copy(modifiedAt = at(0))
        val newer = base.copy(modifiedAt = at(60))
        val remote = listOf(
            SyncPlanner.RemoteFile("notes/Dup (old).md", "e1", older),
            SyncPlanner.RemoteFile("notes/Dup.md", "e2", newer),
        )

        val plan = SyncPlanner.plan(emptyList(), remote, SyncState())
        assertEquals(listOf("notes/Dup (old).md"), plan.deleteRemoteKeys)
        assertEquals(listOf("notes/Dup.md"), plan.applyLocally.map { it.key })
    }

    @Test
    fun foreignObjectIsLeftAlone() {
        // A README someone dropped into notes/ — undecodable, never touched.
        val remote = listOf(SyncPlanner.RemoteFile("notes/README.txt", "x1"))
        val plan = SyncPlanner.plan(emptyList(), remote, SyncState())
        assertTrue(plan.isEmpty)
    }
}
