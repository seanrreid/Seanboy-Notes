package com.torchcodelab.seanboy.core

import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import java.io.File

/**
 * End-to-end engine tests: a real NoteStore + SyncPlanner + S3Client driven by
 * SyncEngine against a MockWebServer standing in for the bucket. Proves the
 * whole sync sequence wires together — the capstone the pure unit tests build
 * toward.
 */
class SyncEngineTest {
    private lateinit var server: MockWebServer
    private lateinit var base: File
    private lateinit var directory: File
    private lateinit var stateFile: File
    private lateinit var store: NoteStore
    private lateinit var engine: SyncEngine

    @Before
    fun setUp() {
        server = MockWebServer()
        server.start()
        base = File.createTempFile("SeanboySync", "").let { it.delete(); File(it.parentFile, it.name + "-d") }
        directory = File(base, "Notes").apply { mkdirs() }
        stateFile = File(base, "syncstate.json")
        store = NoteStore(directory, File(base, "tombstones.json"))
        val client = S3Client(
            S3Config(
                endpoint = server.url("/").toString().trimEnd('/'), bucket = "b",
                accessKeyID = "AK", secretAccessKey = "SK",
            ),
        )
        engine = SyncEngine(store, client, stateFile)
    }

    @After
    fun tearDown() {
        server.shutdown()
        base.deleteRecursively()
    }

    private fun emptyList(): MockResponse =
        MockResponse().setResponseCode(200).setBody("<?xml version=\"1.0\"?><ListBucketResult></ListBucketResult>")

    @Test
    fun firstSyncUploadsLocalNotes() {
        val note = store.create(title = "Hello", body = "world")
        server.enqueue(emptyList()) // list notes/
        server.enqueue(emptyList()) // list .tombstones/
        server.enqueue(MockResponse().setResponseCode(200).addHeader("ETag", "\"e1\"")) // PUT

        val result = engine.sync()
        assertEquals(1, result.uploaded)
        assertEquals(0, result.appliedLocally)

        server.takeRequest() // list notes
        server.takeRequest() // list tombstones
        val put = server.takeRequest()
        assertEquals("PUT", put.method)
        assertEquals("/b/notes/Hello.md", put.path)
        assertTrue(put.body.readUtf8().contains("world"))

        // State recorded the upload so the next sync is a no-op for this note.
        val saved = SyncState.load(stateFile)
        assertEquals("notes/Hello.md", saved[note.id]?.key)
        assertEquals("e1", saved[note.id]?.etag)
    }

    @Test
    fun pullsRemoteOnlyNote() {
        val remote = Note.fromTitle(title = "Remote", body = "remote body")
        val text = NoteDocument.serialize(remote)
        server.enqueue(
            MockResponse().setResponseCode(200).setBody(
                """
                <?xml version="1.0"?>
                <ListBucketResult>
                  <Contents><Key>notes/Remote.md</Key><ETag>"r1"</ETag></Contents>
                </ListBucketResult>
                """.trimIndent(),
            ),
        ) // list notes/
        server.enqueue(emptyList()) // list .tombstones/
        server.enqueue(MockResponse().setResponseCode(200).setBody(text).addHeader("ETag", "\"r1\"")) // GET

        val result = engine.sync()
        assertEquals(0, result.uploaded)
        assertEquals(1, result.appliedLocally)

        // The note now exists locally on disk and in the index.
        assertEquals("remote body", store.noteAtPath("Remote.md")?.body)
        assertTrue(File(directory, "Remote.md").exists())
        assertEquals("notes/Remote.md", SyncState.load(stateFile)[remote.id]?.key)
    }
}
