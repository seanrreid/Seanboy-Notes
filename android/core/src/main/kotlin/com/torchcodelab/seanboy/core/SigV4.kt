package com.torchcodelab.seanboy.core

import java.security.MessageDigest
import java.time.Instant
import java.time.ZoneOffset
import java.time.format.DateTimeFormatter
import javax.crypto.Mac
import javax.crypto.spec.SecretKeySpec

/**
 * AWS Signature Version 4 request signing — the tiny slice of it S3 needs.
 * Pure functions over strings so it can be verified against the documented AWS
 * test vectors.
 *
 * Faithful Kotlin port of `mac/Sources/SeanboyCore/S3/SigV4.swift`. The PRD
 * flags this as the highest-risk port: it MUST match the AWS worked examples
 * byte-for-byte (see SigV4Test).
 */
object SigV4 {

    data class Credentials(val accessKeyID: String, val secretAccessKey: String)

    /**
     * The pieces of an HTTP request that participate in signing. [headers] must
     * contain every header that will be sent and signed (including `host` and
     * `x-amz-content-sha256`); `x-amz-date` is derived from [date].
     */
    data class Request(
        val method: String,
        val path: String,
        val queryItems: List<Pair<String, String>> = emptyList(),
        val headers: Map<String, String>,
        val payloadHash: String,
        val date: Instant,
    )

    const val UNSIGNED_PAYLOAD = "UNSIGNED-PAYLOAD"

    /** SHA-256 of an empty body — the payload hash for GET/DELETE requests. */
    const val EMPTY_PAYLOAD_HASH =
        "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"

    /**
     * Returns the headers to add to the request: `Authorization` and
     * `x-amz-date` (the latter is also included in the signature).
     */
    fun sign(
        request: Request,
        credentials: Credentials,
        region: String,
        service: String = "s3",
    ): Map<String, String> {
        val amzDate = timestamp(request.date)
        val dateStamp = amzDate.take(8)

        val headers = request.headers.toMutableMap()
        headers["x-amz-date"] = amzDate

        val sortedHeaders = headers
            .map { it.key.lowercase() to it.value.trim() }
            .sortedBy { it.first }
        val canonicalHeaders = sortedHeaders.joinToString("") { "${it.first}:${it.second}\n" }
        val signedHeaders = sortedHeaders.joinToString(";") { it.first }

        val canonicalRequest = listOf(
            request.method,
            canonicalURI(request.path),
            canonicalQuery(request.queryItems),
            canonicalHeaders,
            signedHeaders,
            request.payloadHash,
        ).joinToString("\n")

        val scope = "$dateStamp/$region/$service/aws4_request"
        val stringToSign = listOf(
            "AWS4-HMAC-SHA256",
            amzDate,
            scope,
            hexHash(canonicalRequest),
        ).joinToString("\n")

        var key = hmac(("AWS4" + credentials.secretAccessKey).toByteArray(Charsets.UTF_8), dateStamp)
        key = hmac(key, region)
        key = hmac(key, service)
        key = hmac(key, "aws4_request")
        val signature = hex(hmac(key, stringToSign))

        val authorization = "AWS4-HMAC-SHA256 " +
            "Credential=${credentials.accessKeyID}/$scope, " +
            "SignedHeaders=$signedHeaders, " +
            "Signature=$signature"

        return mapOf("Authorization" to authorization, "x-amz-date" to amzDate)
    }

    // MARK: - Canonical pieces

    /** RFC 3986 unreserved characters — everything else gets percent-encoded. */
    private val unreserved: Set<Char> =
        ("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789" + "-._~").toHashSet()

    /**
     * Percent-encodes a string for SigV4. S3 canonical URIs are encoded once,
     * with `/` left intact in paths ([encodeSlash] = false).
     */
    fun encode(string: String, encodeSlash: Boolean = true): String {
        val out = StringBuilder()
        for (byte in string.toByteArray(Charsets.UTF_8)) {
            val value = byte.toInt() and 0xFF
            val char = value.toChar()
            if (char in unreserved || (!encodeSlash && char == '/')) {
                out.append(char)
            } else {
                out.append('%').append("%02X".format(value))
            }
        }
        return out.toString()
    }

    fun canonicalURI(path: String): String =
        if (path.isEmpty()) "/" else encode(path, encodeSlash = false)

    fun canonicalQuery(items: List<Pair<String, String>>): String =
        items
            .map { encode(it.first) to encode(it.second) }
            .sortedWith(compareBy({ it.first }, { it.second }))
            .joinToString("&") { "${it.first}=${it.second}" }

    // MARK: - Crypto helpers

    fun hexHash(string: String): String = hexHash(string.toByteArray(Charsets.UTF_8))

    fun hexHash(data: ByteArray): String =
        hex(MessageDigest.getInstance("SHA-256").digest(data))

    private fun hmac(key: ByteArray, message: String): ByteArray {
        val mac = Mac.getInstance("HmacSHA256")
        mac.init(SecretKeySpec(key, "HmacSHA256"))
        return mac.doFinal(message.toByteArray(Charsets.UTF_8))
    }

    private fun hex(data: ByteArray): String =
        data.joinToString("") { "%02x".format(it.toInt() and 0xFF) }

    private val timestampFormatter: DateTimeFormatter =
        DateTimeFormatter.ofPattern("yyyyMMdd'T'HHmmss'Z'").withZone(ZoneOffset.UTC)

    fun timestamp(date: Instant): String = timestampFormatter.format(date)
}
