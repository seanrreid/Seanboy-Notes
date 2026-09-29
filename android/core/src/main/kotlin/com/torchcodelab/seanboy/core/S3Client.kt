package com.torchcodelab.seanboy.core

import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import java.io.ByteArrayInputStream
import java.net.URI
import java.time.Instant
import javax.xml.parsers.SAXParserFactory
import org.xml.sax.Attributes
import org.xml.sax.helpers.DefaultHandler

/**
 * Connection details for an S3-compatible bucket. Built for Cloudflare R2
 * (`https://<account>.r2.cloudflarestorage.com`, region `auto`) but works
 * against any S3 host, including MinIO on a NAS.
 */
data class S3Config(
    val endpoint: String,
    val bucket: String,
    val region: String = "auto",
    val accessKeyID: String,
    val secretAccessKey: String,
)

data class S3Object(val key: String, val etag: String)

/** Result of a GET: the body bytes and the object's ETag. */
data class S3Get(val data: ByteArray, val etag: String)

sealed class S3Error(message: String) : Exception(message) {
    /**
     * A conditional write failed — the object changed under us (or already
     * exists for If-None-Match). The next sync re-merges and heals this.
     */
    data class PreconditionFailed(val key: String) :
        S3Error("$key changed on the server — will re-merge on next sync")

    data class NotFound(val key: String) : S3Error("$key does not exist in the bucket")
    data class Http(val status: Int, val body: String) :
        S3Error(if (body.isEmpty()) "Server returned HTTP $status" else body)

    data object BadResponse : S3Error("Unexpected response from the server")
}

/**
 * Minimal blocking S3 client: list / get / put / delete / copy, with
 * conditional writes. Bucket-in-path style so a single endpoint URL is all the
 * configuration a provider needs. Callers run it off the main thread.
 *
 * Kotlin port of `mac/Sources/SeanboyCore/S3/S3Client.swift` (URLSession/async
 * becomes OkHttp/blocking; Foundation XMLParser becomes SAX).
 */
class S3Client(
    val config: S3Config,
    private val client: OkHttpClient = OkHttpClient(),
) {
    private val host: String =
        URI(config.endpoint).host ?: throw S3Error.BadResponse

    // MARK: - Operations

    /** Lists every object under [prefix], following continuation tokens. */
    fun list(prefix: String): List<S3Object> {
        val objects = mutableListOf<S3Object>()
        var continuation: String? = null
        do {
            val query = mutableListOf("list-type" to "2", "prefix" to prefix)
            continuation?.let { query.add("continuation-token" to it) }
            val (data, _) = send("GET", key = null, query = query, body = null)
            val page = ListResultParser.parse(data)
            objects.addAll(page.objects)
            continuation = page.nextContinuationToken
        } while (continuation != null)
        return objects
    }

    fun get(key: String): S3Get {
        val (data, response) = send("GET", key = key, query = emptyList(), body = null)
        return S3Get(data, etagOf(response))
    }

    /**
     * Uploads an object. [ifMatch] makes the write conditional on the current
     * ETag; [ifNoneMatch] requires the key to not exist yet. Either failing
     * throws [S3Error.PreconditionFailed].
     */
    fun put(
        key: String,
        data: ByteArray,
        contentType: String = "text/markdown",
        ifMatch: String? = null,
        ifNoneMatch: Boolean = false,
    ): String {
        val extra = mutableMapOf("content-type" to contentType)
        if (ifMatch != null) extra["if-match"] = "\"$ifMatch\""
        if (ifNoneMatch) extra["if-none-match"] = "*"
        val (_, response) = send("PUT", key = key, query = emptyList(), body = data, extraHeaders = extra)
        return etagOf(response)
    }

    /** Idempotent — deleting a missing key succeeds. */
    fun delete(key: String) {
        send("DELETE", key = key, query = emptyList(), body = null)
    }

    fun copy(fromKey: String, toKey: String) {
        val source = "/" + SigV4.encode(config.bucket + "/" + fromKey, encodeSlash = false)
        send("PUT", key = toKey, query = emptyList(), body = null, extraHeaders = mapOf("x-amz-copy-source" to source))
    }

    // MARK: - Request plumbing

    private class Resp(val code: Int, val etag: String)

    private fun send(
        method: String,
        key: String?,
        query: List<Pair<String, String>>,
        body: ByteArray?,
        extraHeaders: Map<String, String> = emptyMap(),
    ): Pair<ByteArray, Resp> {
        var path = "/" + config.bucket
        if (key != null) path += "/" + key

        val payloadHash = SigV4.hexHash(body ?: ByteArray(0))
        val headers = extraHeaders.toMutableMap()
        headers["host"] = host
        headers["x-amz-content-sha256"] = payloadHash

        val signed = SigV4.sign(
            SigV4.Request(
                method = method, path = path, queryItems = query,
                headers = headers, payloadHash = payloadHash, date = Instant.now(),
            ),
            credentials = SigV4.Credentials(config.accessKeyID, config.secretAccessKey),
            region = config.region,
        )
        headers.putAll(signed)
        headers.remove("host") // OkHttp sets Host itself

        var urlString = config.endpoint.trimEnd('/')
        urlString += SigV4.encode(path, encodeSlash = false)
        val queryString = SigV4.canonicalQuery(query)
        if (queryString.isNotEmpty()) urlString += "?$queryString"

        val requestBody = when (method) {
            "PUT", "POST" -> (body ?: ByteArray(0)).toRequestBody()
            else -> null
        }
        val builder = Request.Builder().url(urlString).method(method, requestBody)
        for ((name, value) in headers) builder.header(name, value)

        client.newCall(builder.build()).execute().use { response ->
            val bytes = response.body?.bytes() ?: ByteArray(0)
            val resp = Resp(response.code, response.header("ETag").orEmpty().trim('"'))
            return when {
                response.code in 200..299 -> bytes to resp
                response.code == 412 -> throw S3Error.PreconditionFailed(key ?: path)
                response.code == 404 && method == "DELETE" -> bytes to resp
                response.code == 404 -> throw S3Error.NotFound(key ?: path)
                else -> throw S3Error.Http(response.code, ErrorResultParser.message(bytes))
            }
        }
    }

    private fun etagOf(resp: Resp): String = resp.etag
}

// MARK: - XML parsing

/** Parses a ListObjectsV2 result page. */
internal object ListResultParser {
    class Page {
        val objects = mutableListOf<S3Object>()
        var nextContinuationToken: String? = null
    }

    fun parse(data: ByteArray): Page {
        val page = Page()
        val handler = object : DefaultHandler() {
            private val text = StringBuilder()
            private var inContents = false
            private var key = ""
            private var etag = ""

            override fun startElement(uri: String?, localName: String?, qName: String, attrs: Attributes?) {
                text.setLength(0)
                if (qName == "Contents") {
                    inContents = true; key = ""; etag = ""
                }
            }

            override fun characters(ch: CharArray, start: Int, length: Int) {
                text.appendRange(ch, start, start + length)
            }

            override fun endElement(uri: String?, localName: String?, qName: String) {
                val value = text.toString().trim()
                when (qName) {
                    "Key" -> if (inContents) key = value
                    "ETag" -> if (inContents) etag = value.trim('"')
                    "Contents" -> { inContents = false; page.objects.add(S3Object(key, etag)) }
                    "NextContinuationToken" -> page.nextContinuationToken = value
                }
                text.setLength(0)
            }
        }
        runCatching {
            SAXParserFactory.newInstance().newSAXParser()
                .parse(ByteArrayInputStream(data), handler)
        }
        return page
    }
}

/** Pulls the human-readable message out of an S3 error body. */
internal object ErrorResultParser {
    fun message(data: ByteArray): String {
        var message = ""
        var code = ""
        val handler = object : DefaultHandler() {
            private val text = StringBuilder()
            override fun startElement(uri: String?, localName: String?, qName: String, attrs: Attributes?) {
                text.setLength(0)
            }

            override fun characters(ch: CharArray, start: Int, length: Int) {
                text.appendRange(ch, start, start + length)
            }

            override fun endElement(uri: String?, localName: String?, qName: String) {
                val value = text.toString().trim()
                if (qName == "Message") message = value
                if (qName == "Code") code = value
                text.setLength(0)
            }
        }
        runCatching {
            SAXParserFactory.newInstance().newSAXParser()
                .parse(ByteArrayInputStream(data), handler)
        }
        return message.ifEmpty { code }
    }
}
