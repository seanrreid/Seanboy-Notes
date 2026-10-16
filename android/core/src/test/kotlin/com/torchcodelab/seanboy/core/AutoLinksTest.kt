package com.torchcodelab.seanboy.core

import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/** Runs `shared/fixtures/auto-links.json` (the Mac's `AutoLinksTests.swift` runs it too). */
class AutoLinksTest {
    @Serializable
    private data class Fixtures(val cases: List<Case>)

    @Serializable
    private data class Case(
        val name: String,
        val titles: List<String>,
        val current: String? = null,
        val input: String,
        val links: List<Expected>,
    )

    @Serializable
    private data class Expected(val text: String, val title: String, val start: Int? = null)

    private val fixtureFile =
        File(System.getProperty("seanboy.fixtures") ?: "../../shared/fixtures", "auto-links.json")

    @Test
    fun sharedFixtures() {
        val fixtures = Json { ignoreUnknownKeys = true }.decodeFromString<Fixtures>(fixtureFile.readText())
        assertFalse(fixtures.cases.isEmpty())
        val failures = fixtures.cases.mapNotNull { fixture ->
            val found = AutoLinks(fixture.titles, fixture.current)
                .find(fixture.input, MarkdownSpans.parse(fixture.input))
            val actual = found.zip(fixture.links) { link, expected ->
                Expected(
                    fixture.input.substring(link.range.location, link.range.end),
                    link.title,
                    if (expected.start != null) link.range.location else null,
                )
            }
            if (found.size == fixture.links.size && actual == fixture.links) {
                null
            } else {
                "${fixture.name}: expected ${fixture.links}, got " +
                    found.map { Expected(fixture.input.substring(it.range.location, it.range.end), it.title, it.range.location) }
            }
        }
        assertTrue(failures.joinToString("\n"), failures.isEmpty())
    }

    @Test
    fun findWithinARangeMatchesTheFullSearch() {
        val text = "Recipes here\n`Recipes`\nmore Recipes and Journal"
        val links = AutoLinks(listOf("Recipes", "Journal"))
        val spans = MarkdownSpans.parse(text)
        val full = links.find(text, spans)
        val thirdLine = MarkdownSpans.lineRange(text, SpanRange(text.length - 1, 0))
        assertEquals(full.filter { it.range.location >= thirdLine.location }, links.find(text, spans, thirdLine))
        assertEquals(3, full.size)
    }
}
