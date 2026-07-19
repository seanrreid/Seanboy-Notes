package com.torchcodelab.seanboy.core

import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

/**
 * Exercises the S3 client against a MockWebServer — request shape (path,
 * query, signing headers, conditional writes) and ListObjectsV2 XML parsing.
 * The Mac side has no S3Client unit tests; this adds coverage the port earns
 * from being on the JVM.
 */
class S3ClientTest {
    private lateinit var server: MockWebServer
    private lateinit var client: S3Client

    @Before
    fun setUp() {
        server = MockWebServer()
        server.start()
        val endpoint = server.url("/").toString().trimEnd('/')
        client = S3Client(
            S3Config(
                endpoint = endpoint, bucket = "mybucket", region = "auto",
                accessKeyID = "AKIAEXAMPLE", secretAccessKey = "secretExampleKey",
            ),
        )
    }

    @After
    fun tearDown() {
        server.shutdown()
    }

    @Test
    fun listFollowsContinuationTokens() {
        server.enqueue(
            MockResponse().setResponseCode(200).setBody(
                """
                <?xml version="1.0" encoding="UTF-8"?>
                <ListBucketResult>
                  <Contents><Key>notes/A.md</Key><ETag>"e1"</ETag></Contents>
                  <NextContinuationToken>TOK</NextContinuationToken>
                </ListBucketResult>
                """.trimIndent(),
            ),
        )
        server.enqueue(
            MockResponse().setResponseCode(200).setBody(
                """
                <?xml version="1.0" encoding="UTF-8"?>
                <ListBucketResult>
                  <Contents><Key>notes/B.md</Key><ETag>"e2"</ETag></Contents>
                </ListBucketResult>
                """.trimIndent(),
            ),
        )

        val objects = client.list("notes/")
        assertEquals(listOf(S3Object("notes/A.md", "e1"), S3Object("notes/B.md", "e2")), objects)

        val first = server.takeRequest()
        assertTrue(first.path!!.startsWith("/mybucket?"))
        assertTrue(first.path!!.contains("list-type=2"))
        assertTrue(first.path!!.contains("prefix=notes%2F"))
        assertTrue(first.getHeader("Authorization")!!.startsWith("AWS4-HMAC-SHA256 "))
        // Second request carries the continuation token.
        val second = server.takeRequest()
        assertTrue(second.path!!.contains("continuation-token=TOK"))
    }

    @Test
    fun getReturnsBodyAndEtag() {
        server.enqueue(MockResponse().setResponseCode(200).setBody("hello body").addHeader("ETag", "\"abc123\""))
        val result = client.get("notes/A.md")
        assertEquals("hello body", String(result.data))
        assertEquals("abc123", result.etag)

        val req = server.takeRequest()
        assertEquals("GET", req.method)
        assertEquals("/mybucket/notes/A.md", req.path)
    }

    @Test
    fun putSendsIfMatchAndReturnsEtag() {
        server.enqueue(MockResponse().setResponseCode(200).addHeader("ETag", "\"newetag\""))
        val etag = client.put("notes/A.md", "content".toByteArray(), ifMatch = "old")
        assertEquals("newetag", etag)

        val req = server.takeRequest()
        assertEquals("PUT", req.method)
        assertEquals("\"old\"", req.getHeader("if-match"))
        assertEquals("content", req.body.readUtf8())
    }

    @Test
    fun putPreconditionFailedThrows() {
        server.enqueue(MockResponse().setResponseCode(412))
        assertThrows(S3Error.PreconditionFailed::class.java) {
            client.put("notes/A.md", "x".toByteArray(), ifNoneMatch = true)
        }
    }

    @Test
    fun deleteMissingKeySucceeds() {
        server.enqueue(MockResponse().setResponseCode(404))
        client.delete("notes/Gone.md") // must not throw
        assertEquals("DELETE", server.takeRequest().method)
    }

    @Test
    fun copySendsCopySourceHeader() {
        server.enqueue(MockResponse().setResponseCode(200))
        client.copy("notes/A.md", ".versions/A.md/ts.md")

        val req = server.takeRequest()
        assertEquals("PUT", req.method)
        assertEquals("/mybucket/notes/A.md", req.getHeader("x-amz-copy-source"))
    }
}
