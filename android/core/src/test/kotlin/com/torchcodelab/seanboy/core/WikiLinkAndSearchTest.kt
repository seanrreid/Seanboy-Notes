package com.torchcodelab.seanboy.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.time.Instant

/** Ported from `mac/Tests/SeanboyCoreTests/WikiLinkAndSearchTests.swift`. */
class WikiLinkParserTest {
    @Test
    fun findsLinks() {
        val text = "See [[Recipes]] and [[Shopping List]] for details."
        val links = WikiLinkParser.links(text)
        assertEquals(listOf("Recipes", "Shopping List"), links.map { it.title })
        assertEquals("[[Recipes]]", text.substring(links[0].range.first, links[0].range.last + 1))
    }

    @Test
    fun trimsAndSkipsEmpty() {
        val links = WikiLinkParser.links("[[  Padded  ]] [[   ]] [[]]")
        assertEquals(listOf("Padded"), links.map { it.title })
    }

    @Test
    fun noNestingOrNewlines() {
        assertTrue(WikiLinkParser.links("[[a\nb]]").isEmpty())
        assertEquals(listOf("Extra"), WikiLinkParser.links("[[[Extra]]").map { it.title })
    }

    @Test
    fun linkedTitlesDedupesCaseInsensitively() {
        val titles = WikiLinkParser.linkedTitles("[[Ideas]] then [[ideas]] then [[Other]]")
        assertEquals(listOf("Ideas", "Other"), titles)
    }

    @Test
    fun backlinks() {
        val a = Note.fromTitle(title = "A", body = "links to [[B]]")
        val b = Note.fromTitle(title = "B", body = "no links")
        val c = Note.fromTitle(title = "C", body = "also [[b]] here")
        val d = Note.fromTitle(title = "D", body = "[[B]] but deleted").copy(isDeleted = true)
        val backs = WikiLinkParser.backlinks("B", listOf(a, b, c, d))
        assertEquals(listOf("A", "C"), backs.map { it.title })
    }
}

class SearchServiceTest {
    private val notes = listOf(
        Note.fromTitle(
            title = "Swift Concurrency", body = "actors and tasks",
            modifiedAt = Instant.ofEpochSecond(300),
        ),
        Note.fromTitle(
            title = "Groceries", body = "milk, eggs, swift delivery",
            modifiedAt = Instant.ofEpochSecond(200),
        ),
        Note.fromTitle(
            title = "Old Ideas", body = "nothing relevant",
            modifiedAt = Instant.ofEpochSecond(100),
        ),
    )

    @Test
    fun emptyQueryReturnsAllByRecency() {
        val results = SearchService.search("  ", notes)
        assertEquals(listOf("Swift Concurrency", "Groceries", "Old Ideas"), results.map { it.title })
    }

    @Test
    fun titleMatchOutranksBodyMatch() {
        val results = SearchService.search("swift", notes)
        assertEquals(listOf("Swift Concurrency", "Groceries"), results.map { it.title })
    }

    @Test
    fun allTermsMustMatch() {
        val results = SearchService.search("swift milk", notes)
        assertEquals(listOf("Groceries"), results.map { it.title })
    }

    @Test
    fun noMatches() {
        assertTrue(SearchService.search("zzz", notes).isEmpty())
    }
}
