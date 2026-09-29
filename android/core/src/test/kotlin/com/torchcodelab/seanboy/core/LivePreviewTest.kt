package com.torchcodelab.seanboy.core

import com.torchcodelab.seanboy.core.LivePreview.Style
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class LivePreviewTest {
    /** Each style as (style, the text it covers), for readable assertions. */
    private fun styled(text: String, revealed: SpanRange? = null): List<Pair<Style, String>> =
        LivePreview.styles(text, MarkdownSpans.parse(text), revealed)
            .map { it.style to text.substring(it.range.location, it.range.end) }

    private fun lineOf(text: String, at: Int) = MarkdownSpans.lineRange(text, SpanRange(at, 0))

    @Test
    fun renderedLinesHideMarkers() {
        assertEquals(
            listOf(Style.Bold to "**big**", Style.Hidden to "**", Style.Hidden to "**"),
            styled("a **big** b"),
        )
    }

    @Test
    fun cursorLineFadesMarkersInstead() {
        val text = "a **big** b"
        assertEquals(
            listOf(Style.Bold to "**big**", Style.Faded to "**", Style.Faded to "**"),
            styled(text, revealed = lineOf(text, 0)),
        )
    }

    @Test
    fun onlyTheCursorLineIsRevealed() {
        val text = "# One\n# Two"
        val styles = styled(text, revealed = lineOf(text, 8))
        assertTrue(Style.Hidden to "# " in styles)
        assertTrue(Style.Faded to "# " in styles)
        assertEquals(listOf(Style.Heading(1), Style.Heading(1)), styles.map { it.first }.filterIsInstance<Style.Heading>())
    }

    @Test
    fun wikiLinkIsTappableAndShowsOnlyItsText() {
        assertEquals(
            listOf(
                Style.Link("Projects/Seanboy", isWikiLink = true) to "[[Projects/Seanboy|the app]]",
                Style.Hidden to "[[Projects/Seanboy|",
                Style.Hidden to "]]",
            ),
            styled("[[Projects/Seanboy|the app]]"),
        )
    }

    @Test
    fun markdownLinkTapsOnItsLabel() {
        assertEquals(Style.Link("https://x.com", isWikiLink = false) to "docs", styled("[docs](https://x.com)").first())
    }

    @Test
    fun renderedTaskCollapsesToACheckbox() {
        assertEquals(
            listOf(
                Style.Hidden to "- [",
                Style.Hidden to "]",
                Style.Checkbox(checked = true) to "x",
                Style.DoneTask to "call mom",
            ),
            styled("- [x] call mom"),
        )
    }

    @Test
    fun taskOnCursorLineShowsItsMarkerTinted() {
        val text = "- [ ] buy milk"
        assertEquals(listOf(Style.Tinted to "- [ ] "), styled(text, revealed = lineOf(text, 0)))
    }

    @Test
    fun bulletsAlwaysRenderAsDots() {
        val text = "- one"
        val expected = listOf(Style.Tinted to "- ", Style.Bullet to "-")
        assertEquals(expected, styled(text))
        assertEquals(expected, styled(text, revealed = lineOf(text, 0)))
    }

    @Test
    fun ruleDrawsALineOnlyWhenRendered() {
        assertEquals(listOf(Style.Hidden to "---", Style.Rule to "---"), styled("---"))
        assertEquals(listOf(Style.Faded to "---"), styled("---", revealed = SpanRange(0, 3)))
    }

    @Test
    fun quoteHidesItsMarkerUntilRevealed() {
        val text = "> wise"
        assertEquals(
            listOf(Style.Quote(markerShown = false) to "> wise", Style.QuoteText to "wise", Style.Hidden to "> "),
            styled(text),
        )
        assertEquals(Style.Tinted to "> ", styled(text, revealed = lineOf(text, 0)).last())
    }

    @Test
    fun codeBlockRevealsFencesFromAnyLineInside() {
        val text = "```\nlet x\n```\nafter"
        val inside = lineOf(text, 5)
        assertTrue(styled(text, revealed = inside).count { it.first == Style.Faded } == 2)
        assertTrue(styled(text).count { it.first == Style.Hidden } == 2)
    }

    @Test
    fun revealedRangeEndingAtASpanDoesNotRevealIt() {
        val span = MarkdownSpans.parse("a\n**b**")[0]
        assertFalse(LivePreview.isRevealed(span, SpanRange(0, 2))) // line "a\n" ends where "**b**" starts
        assertTrue(LivePreview.isRevealed(span, SpanRange(2, 0))) // cursor at the start of the line
        assertFalse(LivePreview.isRevealed(span, null))
    }

    @Test
    fun emptyRangesAreDropped() {
        // An empty task has no content, so no DoneTask style over zero characters.
        assertEquals(
            listOf(Style.Hidden to "- [", Style.Hidden to "]", Style.Checkbox(checked = true) to "x"),
            styled("- [x]"),
        )
    }
}
