package com.torchcodelab.seanboy.core

/** A UTF-16 range in a note body: `location` plus `length` (like `NSRange`). */
data class SpanRange(val location: Int, val length: Int) {
    val end: Int get() = location + length
}

/**
 * One piece of Markdown syntax found in a note body, for Live Preview
 * rendering. Ranges are UTF-16 offsets into the body, the units both Kotlin
 * strings and the Mac's `NSString` use, so both ports agree.
 *
 * - [range]: everything the syntax covers, markers included.
 * - [content]: the part that stays visible when the line is rendered.
 * - [markers]: the parts hidden when rendered and shown faded on the cursor
 *   line (`**`, `# `, `[[`, `- `, fence lines, …).
 */
data class MarkdownSpan(
    val kind: Kind,
    val range: SpanRange,
    val content: SpanRange,
    val markers: List<SpanRange>,
    /** Heading level (1–6), or leading indent in columns for list items (a tab counts as 4). */
    val level: Int = 0,
    /** `- [x]` tasks. */
    val checked: Boolean = false,
    /** Wiki-link title, link URL, or bare URL. */
    val target: String? = null,
) {
    /** [key] is the name the Mac port and the shared fixtures use. */
    enum class Kind(val key: String) {
        // Line-level
        Heading("heading"), Quote("quote"), Rule("rule"), Bullet("bullet"),
        OrderedItem("orderedItem"), Task("task"), CodeBlock("codeBlock"),

        // Inline
        Bold("bold"), Italic("italic"), Strikethrough("strikethrough"), Highlight("highlight"),
        Code("code"), WikiLink("wikiLink"), Link("link"), Url("url"),
    }
}

/**
 * Line-oriented Markdown scanner for Live Preview. It never changes text; it
 * only reports where syntax is. Supports the subset in `docs/PRD-editor-v4.md`;
 * everything else is plain text.
 *
 * Kotlin port of `mac/Sources/SeanboyCore/MarkdownSpans.swift`. Both run
 * `shared/fixtures/markdown-spans.json`. The regexes spell out Unicode classes
 * (instead of `\w`, `\s`, `\d`) so they match the Mac's ICU regexes on the JVM
 * too, where those shorthands are ASCII-only.
 */
object MarkdownSpans {

    /** The spans of a parse plus the exact range they describe. */
    data class Parsed(val spans: List<MarkdownSpan>, val covered: SpanRange)

    fun parse(text: String): List<MarkdownSpan> = parse(text, SpanRange(0, text.length)).spans

    /**
     * Incremental parse for the editor: the spans of every line touching
     * [range], widened so a code block is always parsed whole. `covered` is
     * the exact range those spans describe — restyle that, nothing more.
     *
     * Only a cheap fence scan runs before [range], so the cost is
     * proportional to the edited lines, not the note.
     */
    fun parse(text: String, range: SpanRange): Parsed {
        val length = text.length
        val location = minOf(range.location, length)
        val clamped = SpanRange(location, minOf(range.length, length - location))
        val lines = lineRange(text, clamped)

        // If the edit is inside a code block, start at its opening fence.
        val start = openFenceStart(text, before = lines.location) ?: lines.location

        val spans = mutableListOf<MarkdownSpan>()
        var openFence: OpenFence? = null
        var previousLineEnd = start
        var coveredEnd = length

        var next = start
        while (next < length) {
            val line = lineAt(text, next, length)
            if (line.start >= lines.end && line.start > clamped.location && openFence == null) {
                coveredEnd = line.start
                break
            }
            val lineRange = SpanRange(line.start, line.end - line.start)
            val lineText = text.substring(line.start, line.end)
            val fence = openFence
            if (fence != null) {
                // Code fences: everything between is one opaque block.
                if (isFence(lineText, closing = fence.marker)) {
                    spans += MarkdownSpan(
                        kind = MarkdownSpan.Kind.CodeBlock,
                        range = SpanRange(fence.line.location, line.end - fence.line.location),
                        content = SpanRange(fence.bodyStart, maxOf(0, previousLineEnd - fence.bodyStart)),
                        markers = listOf(fence.line, lineRange),
                    )
                    openFence = null
                }
            } else {
                val marker = openingFence(lineText)
                if (marker != null) {
                    openFence = OpenFence(lineRange, marker, bodyStart = line.enclosingEnd)
                } else {
                    val inlineRange = lineSpans(lineText, lineRange, spans)
                    inlineSpans(text, inlineRange, spans)
                }
            }
            previousLineEnd = line.end
            next = line.enclosingEnd
        }

        // An unclosed fence runs to the end of the note.
        openFence?.let { fence ->
            val bodyStart = minOf(fence.bodyStart, length)
            spans += MarkdownSpan(
                kind = MarkdownSpan.Kind.CodeBlock,
                range = SpanRange(fence.line.location, length - fence.line.location),
                content = SpanRange(bodyStart, length - bodyStart),
                markers = listOf(fence.line),
            )
        }

        spans.sortWith(compareBy<MarkdownSpan> { it.range.location }.thenByDescending { it.range.length })
        return Parsed(spans, SpanRange(start, coveredEnd - start))
    }

    /**
     * Number of lines that open or close a code fence. When it changes, an
     * edit may have restyled everything below it.
     */
    fun fenceLineCount(text: String): Int {
        var count = 0
        forEachLine(text, 0, text.length) { start, end, _ ->
            val line = text.substring(start, end)
            if (looksLikeFence(line) && openingFence(line) != null) count++
            true
        }
        return count
    }

    // MARK: - Lines (NSString `.byLines` semantics: \n, \r, \r\n, U+0085, U+2028, U+2029)

    private class LineBounds(val start: Int, val end: Int, val enclosingEnd: Int)

    private class OpenFence(val line: SpanRange, val marker: String, val bodyStart: Int)

    private fun terminatorLength(text: String, i: Int): Int = when (text[i]) {
        '\r' -> if (i + 1 < text.length && text[i + 1] == '\n') 2 else 1
        '\n', '\u0085', ' ', ' ' -> 1
        else -> 0
    }

    /** The line starting at [start], within text up to [limit]. */
    private fun lineAt(text: String, start: Int, limit: Int): LineBounds {
        var end = start
        while (end < limit && terminatorLength(text, end) == 0) end++
        val enclosingEnd = if (end < limit) minOf(end + terminatorLength(text, end), limit) else end
        return LineBounds(start, end, enclosingEnd)
    }

    /** Calls [body] with each line's start, end, and end-with-terminator until it returns false. */
    private inline fun forEachLine(text: String, from: Int, to: Int, body: (Int, Int, Int) -> Boolean) {
        var next = from
        while (next < to) {
            val line = lineAt(text, next, to)
            if (!body(line.start, line.end, line.enclosingEnd)) return
            next = line.enclosingEnd
        }
    }

    /** The whole lines (terminators included) touching [range], like `NSString.lineRange(for:)`. */
    internal fun lineRange(text: String, range: SpanRange): SpanRange {
        var start = range.location
        while (start > 0) {
            val c = text[start - 1]
            val insideCrLf = c == '\r' && start < text.length && text[start] == '\n'
            if (!insideCrLf && terminatorLength(text, start - 1) > 0) break
            start--
        }
        val last = if (range.length > 0) range.end - 1 else range.location
        val end = if (last >= text.length) text.length else lineAt(text, last, text.length).enclosingEnd
        return SpanRange(start, end - start)
    }

    /** Start of the code block that's still open at [before], if any. */
    private fun openFenceStart(text: String, before: Int): Int? {
        var openStart: Int? = null
        var openMarker = ""
        forEachLine(text, 0, before) { start, end, _ ->
            val line = text.substring(start, end)
            if (looksLikeFence(line)) {
                if (openStart != null) {
                    if (isFence(line, closing = openMarker)) openStart = null
                } else {
                    openingFence(line)?.let { openStart = start; openMarker = it }
                }
            }
            true
        }
        return openStart
    }

    /** Cheap pre-check before any regex: fences start with ``` or ~~~ after at most three spaces. */
    private fun looksLikeFence(line: String): Boolean {
        for ((i, c) in line.withIndex()) {
            if (c == ' ' && i < 3) continue
            return c == '`' || c == '~'
        }
        return false
    }

    // MARK: - Unicode classes (ICU's \w and \s, spelled out for the JVM)

    private const val WORD = """\p{L}\p{M}\p{Nd}\p{Pc}"""
    private const val SPACE = """\s\u0085   -     　"""

    // MARK: - Code fences

    private val fenceRx = Regex("""^ {0,3}(`{3,}|~{3,})""")

    private fun openingFence(line: String): String? {
        val match = fenceRx.find(line) ?: return null
        val marker = match.groupValues[1]
        // Backtick fences can't have backticks in the info string.
        if (marker.startsWith("`") && line.substring(match.range.last + 1).contains('`')) return null
        return marker
    }

    private fun isFence(line: String, closing: String): Boolean {
        val trimmed = line.trim { it == '\t' || Character.getType(it) == Character.SPACE_SEPARATOR.toInt() }
        val first = closing.firstOrNull() ?: return false
        if (trimmed.length < closing.length) return false
        return trimmed.all { it == first }
    }

    // MARK: - Line-level syntax

    private val headingRx = Regex("""^(#{1,6})[ \t]+""")
    private val ruleRx = Regex("""^ {0,3}([-*_])(?:[ \t]*\1){2,}[ \t]*$""")
    private val quoteRx = Regex("""^ {0,3}>[ \t]?""")
    private val taskRx = Regex("""^([ \t]*)[-*+][ \t]+\[([ xX])\](?:[ \t]+|$)""")
    private val bulletRx = Regex("""^([ \t]*)[-*+][ \t]+""")
    private val orderedRx = Regex("""^([ \t]*)\p{Nd}{1,9}[.)][ \t]+""")

    private val listKinds = listOf(
        taskRx to MarkdownSpan.Kind.Task,
        bulletRx to MarkdownSpan.Kind.Bullet,
        orderedRx to MarkdownSpan.Kind.OrderedItem,
    )

    /**
     * Records the line's block syntax and returns the range left for inline
     * parsing (absolute offsets).
     */
    private fun lineSpans(line: String, lineRange: SpanRange, spans: MutableList<MarkdownSpan>): SpanRange {
        val base = lineRange.location
        fun abs(r: SpanRange) = SpanRange(r.location + base, r.length)
        fun rest(afterEnd: Int) = SpanRange(afterEnd, line.length - afterEnd)

        if (ruleRx.containsMatchIn(line)) {
            spans += MarkdownSpan(
                MarkdownSpan.Kind.Rule, lineRange,
                content = SpanRange(lineRange.end, 0), markers = listOf(lineRange),
            )
            return SpanRange(lineRange.end, 0)
        }
        headingRx.find(line)?.let { m ->
            val content = rest(m.range.last + 1)
            spans += MarkdownSpan(
                MarkdownSpan.Kind.Heading, lineRange, abs(content),
                markers = listOf(abs(m.range.toSpan())), level = m.groupValues[1].length,
            )
            return abs(content)
        }
        quoteRx.find(line)?.let { m ->
            val content = rest(m.range.last + 1)
            spans += MarkdownSpan(MarkdownSpan.Kind.Quote, lineRange, abs(content), markers = listOf(abs(m.range.toSpan())))
            return abs(content)
        }
        for ((regex, kind) in listKinds) {
            val m = regex.find(line) ?: continue
            val indent = m.groups[1]!!.value
            val markerStart = indent.length
            val matchEnd = m.range.last + 1
            val marker = SpanRange(markerStart, matchEnd - markerStart)
            val content = rest(matchEnd)
            val columns = indent.fold(0) { sum, c -> sum + if (c == '\t') 4 else 1 }
            val checked = kind == MarkdownSpan.Kind.Task && m.groupValues[2] != " "
            spans += MarkdownSpan(
                kind,
                range = SpanRange(base + markerStart, line.length - markerStart),
                content = abs(content), markers = listOf(abs(marker)),
                level = columns, checked = checked,
            )
            return abs(content)
        }
        return lineRange
    }

    // MARK: - Inline syntax

    private val codeRx = Regex("""`([^`\n]+)`""")
    private val wikiRx = Regex("""\[\[([^\[\]\n|]+)(?:\|([^\[\]\n]+))?\]\]""")
    private val linkRx = Regex("""\[([^\[\]\n]+)\]\(([^()$SPACE]+)\)""")
    private val urlRx = Regex("""(?<![$WORD/(\[])https?://[^$SPACE<>()\[\]]+""")
    private val boldRx = Regex("""\*\*(?=[^$SPACE])(.+?)(?<=[^$SPACE])\*\*""")
    private val strikeRx = Regex("""~~(?=[^$SPACE])(.+?)(?<=[^$SPACE])~~""")
    private val highlightRx = Regex("""==(?=[^$SPACE])(.+?)(?<=[^$SPACE])==""")
    private val italicStarRx = Regex("""(?<![*$WORD\\])\*(?=[^*$SPACE])([^*\n]+?)(?<=[^*$SPACE])\*(?![*$WORD])""")
    private val italicUnderscoreRx = Regex("""(?<![${WORD}_])_(?=[^_$SPACE])([^_\n]+?)(?<=[^_$SPACE])_(?![${WORD}_])""")
    private val escapeRx = Regex("""\\[\\`*_=~\[\]()#>|-]""")

    private val emphasisKinds = listOf(
        boldRx to MarkdownSpan.Kind.Bold,
        strikeRx to MarkdownSpan.Kind.Strikethrough,
        highlightRx to MarkdownSpan.Kind.Highlight,
    )

    /**
     * Character that masks consumed or escaped text so later passes can't
     * match inside it. Same UTF-16 length as what it replaces.
     */
    private const val MASK = '\u0001'

    private val trailingUrlPunctuation = ".,;:!?'\""

    private fun IntRange.toSpan() = SpanRange(first, last - first + 1)

    private fun inlineSpans(text: String, range: SpanRange, spans: MutableList<MarkdownSpan>) {
        if (range.length <= 0) return
        val base = range.location
        val chars = text.substring(range.location, range.end).toCharArray()
        fun masked() = String(chars)
        fun maskOut(r: SpanRange) { for (i in r.location until r.end) chars[i] = MASK }
        fun abs(r: SpanRange) = SpanRange(r.location + base, r.length)
        fun source(r: SpanRange) = text.substring(r.location + base, r.end + base)
        fun matches(regex: Regex) = regex.findAll(masked()).toList()

        // Escapes (`\*`) are literal: hide nothing, match nothing.
        for (m in matches(escapeRx)) maskOut(m.range.toSpan())

        // Atomic spans first — nothing else matches inside them.
        for (m in matches(codeRx)) {
            spans += delimited(MarkdownSpan.Kind.Code, m, open = 1, close = 1, ::abs)
            maskOut(m.range.toSpan())
        }
        for (m in matches(wikiRx)) {
            val whole = m.range.toSpan()
            val titleRange = m.groups[1]!!.range.toSpan()
            val aliasRange = m.groups[2]?.range?.toSpan()
            val title = source(titleRange).trim { it == '\t' || Character.getType(it) == Character.SPACE_SEPARATOR.toInt() }
            val open: SpanRange
            val content: SpanRange
            if (aliasRange != null) {
                open = SpanRange(whole.location, aliasRange.location - whole.location)
                content = aliasRange
            } else {
                open = SpanRange(whole.location, 2)
                content = titleRange
            }
            val close = SpanRange(whole.end - 2, 2)
            spans += MarkdownSpan(
                MarkdownSpan.Kind.WikiLink, abs(whole), abs(content),
                markers = listOf(abs(open), abs(close)), target = title,
            )
            maskOut(whole)
        }
        for (m in matches(linkRx)) {
            val whole = m.range.toSpan()
            val label = m.groups[1]!!.range.toSpan()
            val open = SpanRange(whole.location, 1)
            val close = SpanRange(label.end, whole.end - label.end)
            spans += MarkdownSpan(
                MarkdownSpan.Kind.Link, abs(whole), abs(label),
                markers = listOf(abs(open), abs(close)), target = source(m.groups[2]!!.range.toSpan()),
            )
            maskOut(whole)
        }
        for (m in matches(urlRx)) {
            var r = m.range.toSpan()
            // Sentence punctuation after a URL isn't part of it.
            while (r.length > 0 && source(r).last() in trailingUrlPunctuation) r = r.copy(length = r.length - 1)
            if (r.length == 0) continue
            spans += MarkdownSpan(MarkdownSpan.Kind.Url, abs(r), abs(r), markers = emptyList(), target = source(r))
            maskOut(r)
        }

        // Emphasis may wrap atomic spans (`**see [[Note]]**`) and each other.
        for ((regex, kind) in emphasisKinds) {
            for (m in matches(regex)) {
                val span = delimited(kind, m, open = 2, close = 2, ::abs)
                spans += span
                for (marker in span.markers) maskOut(SpanRange(marker.location - base, marker.length))
            }
        }
        for (regex in listOf(italicStarRx, italicUnderscoreRx)) {
            for (m in matches(regex)) spans += delimited(MarkdownSpan.Kind.Italic, m, open = 1, close = 1, ::abs)
        }
    }

    private fun delimited(
        kind: MarkdownSpan.Kind,
        m: MatchResult,
        open: Int,
        close: Int,
        abs: (SpanRange) -> SpanRange,
    ): MarkdownSpan {
        val r = m.range.toSpan()
        return MarkdownSpan(
            kind, abs(r),
            content = abs(SpanRange(r.location + open, r.length - open - close)),
            markers = listOf(abs(SpanRange(r.location, open)), abs(SpanRange(r.end - close, close))),
        )
    }
}
