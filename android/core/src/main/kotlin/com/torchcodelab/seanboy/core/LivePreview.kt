package com.torchcodelab.seanboy.core

/**
 * Decides how [MarkdownSpans] render in Obsidian-style Live Preview: syntax
 * markers are hidden except on the revealed (cursor) lines, where they show
 * faded. Platform-neutral so it's testable on the JVM; the Android editor maps
 * each [Styled] onto a text span. Mirrors `MarkdownStyler.apply` on the Mac.
 * Display-only: the note's Markdown is never changed.
 */
object LivePreview {

    sealed interface Style {
        /** Bigger, bold, accent-colored heading text (level 1–6). */
        data class Heading(val level: Int) : Style
        data object Bold : Style
        data object Italic : Style
        data object Strikethrough : Style
        data object Highlight : Style
        /** Monospace text (inline code and code blocks). */
        data object Monospace : Style
        /** Inline code's colored text on a tinted background. */
        data object InlineCode : Style
        /** Code block background and indent, over the whole block. */
        data object CodeBlock : Style
        /** Tappable link: a note title (`isWikiLink`) or a URL. */
        data class Link(val target: String, val isWikiLink: Boolean) : Style
        /** Quote bar and indent; the first line isn't indented while its `> ` shows. */
        data class Quote(val markerShown: Boolean) : Style
        /** Quote text, in the secondary color. */
        data object QuoteText : Style
        /** A horizontal line drawn across a rendered `---`. */
        data object Rule : Style
        /** Markers not drawn at all (zero width). */
        data object Hidden : Style
        /** Markers shown faded (cursor lines). */
        data object Faded : Style
        /** List markers in the accent color. */
        data object Tinted : Style
        /** A list marker character drawn as `•` (the file keeps `-`, `*`, or `+`). */
        data object Bullet : Style
        /** A task's box character, drawn as a tappable checkbox. */
        data class Checkbox(val checked: Boolean) : Style
        /** A done task's text: struck through and secondary. */
        data object DoneTask : Style
    }

    data class Styled(val style: Style, val range: SpanRange)

    /**
     * The styles for [spans] (from [MarkdownSpans.parse] over [text]), in the
     * order to apply them: later styles win where they overlap. [revealed] is
     * the range of lines whose markers stay visible, or null to render all.
     */
    fun styles(text: String, spans: List<MarkdownSpan>, revealed: SpanRange?): List<Styled> {
        val out = mutableListOf<Styled>()
        fun add(style: Style, range: SpanRange) { out += Styled(style, range) }
        for (span in spans) {
            val shown = isRevealed(span, revealed)
            fun markers() = span.markers.forEach { add(if (shown) Style.Faded else Style.Hidden, it) }

            when (span.kind) {
                MarkdownSpan.Kind.Heading -> {
                    add(Style.Heading(span.level), span.range)
                    markers()
                }
                MarkdownSpan.Kind.Bold -> { add(Style.Bold, span.range); markers() }
                MarkdownSpan.Kind.Italic -> { add(Style.Italic, span.range); markers() }
                MarkdownSpan.Kind.Strikethrough -> { add(Style.Strikethrough, span.content); markers() }
                MarkdownSpan.Kind.Highlight -> { add(Style.Highlight, span.content); markers() }
                MarkdownSpan.Kind.Code -> {
                    add(Style.Monospace, span.range)
                    add(Style.InlineCode, span.content)
                    markers()
                }
                MarkdownSpan.Kind.CodeBlock -> {
                    add(Style.Monospace, span.range)
                    add(Style.CodeBlock, span.range)
                    markers()
                }
                // The whole `[[…]]` is tappable; it opens or creates the note.
                MarkdownSpan.Kind.WikiLink -> {
                    span.target?.let { add(Style.Link(it, isWikiLink = true), span.range) }
                    markers()
                }
                MarkdownSpan.Kind.Link -> {
                    span.target?.let { add(Style.Link(it, isWikiLink = false), span.content) }
                    markers()
                }
                MarkdownSpan.Kind.Url -> span.target?.let { add(Style.Link(it, isWikiLink = false), span.range) }
                MarkdownSpan.Kind.Quote -> {
                    add(Style.Quote(markerShown = shown), span.range)
                    add(Style.QuoteText, span.content)
                    span.markers.forEach { add(if (shown) Style.Tinted else Style.Hidden, it) }
                }
                MarkdownSpan.Kind.Rule -> {
                    if (shown) {
                        span.markers.forEach { add(Style.Faded, it) }
                    } else {
                        span.markers.forEach { add(Style.Hidden, it) }
                        add(Style.Rule, span.range)
                    }
                }
                // Bullets always render as •; the file keeps its marker.
                MarkdownSpan.Kind.Bullet -> {
                    span.markers.forEach { add(Style.Tinted, it) }
                    span.markers.firstOrNull()?.let { add(Style.Bullet, SpanRange(it.location, 1)) }
                }
                MarkdownSpan.Kind.OrderedItem -> span.markers.forEach { add(Style.Tinted, it) }
                MarkdownSpan.Kind.Task -> {
                    val marker = span.markers.firstOrNull()
                    val bracket = marker?.let { text.substring(it.location, it.end).indexOf('[') } ?: -1
                    if (shown || marker == null || bracket < 0) {
                        span.markers.forEach { add(Style.Tinted, it) }
                    } else {
                        // Rendered: `- [ ] ` collapses to one checkbox. Hide `- [`
                        // and `]`; the trailing space stays as the gap.
                        val box = marker.location + bracket + 1
                        add(Style.Hidden, SpanRange(marker.location, box - marker.location))
                        add(Style.Hidden, SpanRange(box + 1, 1))
                        add(Style.Checkbox(span.checked), SpanRange(box, 1))
                    }
                    if (span.checked) add(Style.DoneTask, span.content)
                }
            }
        }
        return out.filter { it.range.length > 0 }
    }

    /**
     * A span's markers show when the cursor lines touch it. Line spans and
     * inline spans never cross lines, so touching the span is touching its
     * line; a code block reveals its fences when the cursor is anywhere in it.
     */
    fun isRevealed(span: MarkdownSpan, revealed: SpanRange?): Boolean {
        revealed ?: return false
        val start = revealed.location
        val end = revealed.end
        return span.range.location <= end && span.range.end >= start &&
            !(revealed.length > 0 && span.range.location == end)
    }
}
