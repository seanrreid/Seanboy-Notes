package com.torchcodelab.seanboy.core

import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/**
 * Runs the platform-neutral fixtures in `shared/fixtures/markdown-spans.json`
 * (the Mac's `MarkdownSpansTests.swift` runs the same file), plus the Mac's
 * incremental-parse checks.
 */
class MarkdownSpansTest {
    @Serializable
    private data class Fixtures(val cases: List<Case>)

    @Serializable
    private data class Case(val name: String, val input: String, val spans: List<Expected>)

    @Serializable
    private data class Expected(
        val kind: String,
        val text: String,
        val content: String,
        val markers: List<String>,
        val level: Int? = null,
        val checked: Boolean? = null,
        val target: String? = null,
        val start: Int? = null,
    )

    private val fixtureFile: File =
        File(System.getProperty("seanboy.fixtures") ?: "../../shared/fixtures", "markdown-spans.json")

    private fun describe(span: MarkdownSpan, input: String, withStart: Boolean) = Expected(
        kind = span.kind.key,
        text = input.substring(span.range.location, span.range.end),
        content = input.substring(span.content.location, span.content.end),
        markers = span.markers.map { input.substring(it.location, it.end) },
        level = span.level.takeIf { it != 0 },
        checked = span.checked.takeIf { it },
        target = span.target,
        start = if (withStart) span.range.location else null,
    )

    @Test
    fun sharedFixtures() {
        val fixtures = Json { ignoreUnknownKeys = true }.decodeFromString<Fixtures>(fixtureFile.readText())
        assertFalse(fixtures.cases.isEmpty())
        val failures = mutableListOf<String>()
        for (fixture in fixtures.cases) {
            val spans = MarkdownSpans.parse(fixture.input)
            val actual = spans.zip(fixture.spans) { span, expected ->
                describe(span, fixture.input, withStart = expected.start != null)
            }
            if (spans.size != fixture.spans.size || actual != fixture.spans) {
                failures += "${fixture.name}:\n  expected ${fixture.spans}\n  got      " +
                    spans.map { describe(it, fixture.input, withStart = true) }
            }
        }
        assertTrue(failures.joinToString("\n"), failures.isEmpty())
    }

    private val mixedNote = """
        # Title with **bold**
        - item [[Link]]
          - [ ] nested task
        ```swift
        let x = **not bold**
        ```
        > quote with ==mark==

        ~~~
        unclosed? no, closed:
        ~~~
        1. last `code`
        ```
        trailing open fence
    """.trimIndent()

    /**
     * Every incremental parse agrees with the full parse over the range it
     * claims to cover, and covers the lines it was asked about.
     */
    @Test
    fun incrementalMatchesFullParse() {
        val text = mixedNote
        val full = MarkdownSpans.parse(text)
        for (location in 0..text.length) {
            val (spans, covered) = MarkdownSpans.parse(text, SpanRange(location, 0))
            val asked = MarkdownSpans.lineRange(text, SpanRange(location, 0))
            assertTrue(
                "covered $covered misses line $asked at $location",
                covered.location <= asked.location && covered.end >= asked.end,
            )
            val expected = full.filter { it.range.location >= covered.location && it.range.end <= covered.end }
            assertEquals("at $location", expected, spans)
        }
    }

    @Test
    fun incrementalInsideCodeBlockCoversWholeBlock() {
        val text = "a\n```\nx\ny\n```\nb"
        val (spans, covered) = MarkdownSpans.parse(text, SpanRange(8, 0))
        assertEquals("```\nx\ny\n```\n", text.substring(covered.location, covered.end))
        assertEquals(listOf(MarkdownSpan.Kind.CodeBlock), spans.map { it.kind })
    }

    @Test
    fun fenceLineCount() {
        assertEquals(3, MarkdownSpans.fenceLineCount("```\nx\n```\n   ~~~\n    ```"))
    }

    @Test
    fun emptyInput() {
        assertEquals(emptyList<MarkdownSpan>(), MarkdownSpans.parse(""))
    }

    @Test
    fun lineRangeMatchesNSStringSemantics() {
        val text = "ab\r\ncd\n"
        assertEquals(SpanRange(0, 4), MarkdownSpans.lineRange(text, SpanRange(1, 0)))
        assertEquals(SpanRange(0, 4), MarkdownSpans.lineRange(text, SpanRange(3, 0))) // between \r and \n
        assertEquals(SpanRange(4, 3), MarkdownSpans.lineRange(text, SpanRange(4, 0)))
        assertEquals(SpanRange(7, 0), MarkdownSpans.lineRange(text, SpanRange(7, 0))) // after the final newline
        assertEquals(SpanRange(0, 7), MarkdownSpans.lineRange(text, SpanRange(1, 4)))
    }

    /** Guards the per-keystroke budget: an incremental parse of a big note stays small. */
    @Test
    fun incrementalParseOfLargeNoteOnlyCoversTheEditedLine() {
        val note = "- item with [[Link]] and **bold** text\n".repeat(6_000)
        val middle = SpanRange(note.length / 2, 0)
        val (spans, covered) = MarkdownSpans.parse(note, middle)
        assertEquals(MarkdownSpans.lineRange(note, middle), covered)
        assertEquals(3, spans.size) // bullet, wiki link, bold
    }
}
