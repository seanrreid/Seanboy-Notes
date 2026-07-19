package com.torchcodelab.seanboy.core

import org.junit.Assert.assertEquals
import org.junit.Test
import java.time.Instant

/**
 * Verified against the worked examples in the AWS SigV4 documentation
 * ("Authenticating Requests: Using the Authorization Header", examplebucket).
 * Ported from `mac/Tests/SeanboyCoreTests/SigV4Tests.swift`.
 */
class SigV4Test {

    private val credentials = SigV4.Credentials(
        accessKeyID = "AKIAIOSFODNN7EXAMPLE",
        secretAccessKey = "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY",
    )

    /** 2013-05-24T00:00:00Z — the timestamp all AWS examples use. */
    private val exampleDate: Instant = Instant.parse("2013-05-24T00:00:00Z")

    private fun signature(headers: Map<String, String>): String =
        headers["Authorization"]!!.substringAfterLast("Signature=")

    @Test
    fun getObjectExample() {
        val headers = SigV4.sign(
            SigV4.Request(
                method = "GET",
                path = "/test.txt",
                headers = mapOf(
                    "host" to "examplebucket.s3.amazonaws.com",
                    "range" to "bytes=0-9",
                    "x-amz-content-sha256" to SigV4.EMPTY_PAYLOAD_HASH,
                ),
                payloadHash = SigV4.EMPTY_PAYLOAD_HASH,
                date = exampleDate,
            ),
            credentials = credentials, region = "us-east-1",
        )

        assertEquals("20130524T000000Z", headers["x-amz-date"])
        assertEquals(
            "f0e8bdb87c964420e857bd35b5d6ed310bd44f0170aba48dd91039c6036bdb41",
            signature(headers),
        )
    }

    @Test
    fun putObjectExample() {
        val payloadHash = SigV4.hexHash("Welcome to Amazon S3.")
        assertEquals(
            "44ce7dd67c959e0d3524ffac1771dfbba87d2b6b4b4e99e42034a8b803f8b072",
            payloadHash,
        )

        val headers = SigV4.sign(
            SigV4.Request(
                method = "PUT",
                path = "/test\$file.text",
                headers = mapOf(
                    "date" to "Fri, 24 May 2013 00:00:00 GMT",
                    "host" to "examplebucket.s3.amazonaws.com",
                    "x-amz-content-sha256" to payloadHash,
                    "x-amz-storage-class" to "REDUCED_REDUNDANCY",
                ),
                payloadHash = payloadHash,
                date = exampleDate,
            ),
            credentials = credentials, region = "us-east-1",
        )

        assertEquals(
            "98ad721746da40c64f1a55b78f14c238d841ea1380cd77a1b5971af0ece108bd",
            signature(headers),
        )
    }

    @Test
    fun listObjectsExample() {
        val headers = SigV4.sign(
            SigV4.Request(
                method = "GET",
                path = "/",
                queryItems = listOf("max-keys" to "2", "prefix" to "J"),
                headers = mapOf(
                    "host" to "examplebucket.s3.amazonaws.com",
                    "x-amz-content-sha256" to SigV4.EMPTY_PAYLOAD_HASH,
                ),
                payloadHash = SigV4.EMPTY_PAYLOAD_HASH,
                date = exampleDate,
            ),
            credentials = credentials, region = "us-east-1",
        )

        assertEquals(
            "34b48302e7b5fa45bde8084f4b7868a86f0a534bc59db6670ed5711ef69dc6f7",
            signature(headers),
        )
    }

    @Test
    fun encodingRules() {
        assertEquals("notes/Grocery%20List.md", SigV4.encode("notes/Grocery List.md", encodeSlash = false))
        assertEquals("a%2Bb%3Dc%26d", SigV4.encode("a+b=c&d"))
        assertEquals("h%C3%A9llo", SigV4.encode("héllo"))
        assertEquals("safe-._~chars", SigV4.encode("safe-._~chars"))
    }
}
