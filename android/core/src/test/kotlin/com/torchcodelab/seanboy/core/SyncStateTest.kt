package com.torchcodelab.seanboy.core

import org.junit.Assert.assertEquals
import org.junit.Test
import java.io.File
import java.time.Instant
import java.time.temporal.ChronoUnit
import java.util.UUID

class SyncStateTest {
    @Test
    fun persistenceRoundTrips() {
        val id = UUID.randomUUID()
        val at = Instant.now().truncatedTo(ChronoUnit.MILLIS)
        val state = SyncState()
        // A key with spaces and a quote exercises JSON string escaping.
        state[id] = SyncState.Entry(key = "notes/Grocery \"List\".md", etag = "e1", modifiedAt = at)

        val file = File.createTempFile("syncstate", ".json")
        file.deleteOnExit()
        state.save(file)

        val loaded = SyncState.load(file)
        assertEquals("notes/Grocery \"List\".md", loaded[id]?.key)
        assertEquals("e1", loaded[id]?.etag)
        assertEquals(at, loaded[id]?.modifiedAt)
    }

    @Test
    fun missingFileLoadsEmpty() {
        val loaded = SyncState.load(File("/nonexistent/path/syncstate.json"))
        assertEquals(0, loaded.entries.size)
    }
}
