package com.torchcodelab.seanboy.core

/** Text in a note that matches another note's title: [range] opens [title]. */
data class AutoLink(val range: SpanRange, val title: String)

/**
 * Auto-links to existing notes (PRD editor v4, core feature 5; GNote's
 * `NoteLinkWatcher`): text that matches another note's title, as a whole word
 * and ignoring case, is shown as a link. Display-only: nothing is written to
 * the file.
 *
 * The longest title wins where titles overlap, matches never overlap, titles
 * shorter than [MIN_TITLE_LENGTH] are ignored, the open note ([current]) never
 * links to itself, and nothing inside code, code blocks, wiki links, links, or
 * URLs is matched.
 *
 * Build one per set of titles (compiling the pattern is the costly part) and
 * call [find] per restyle. Kotlin port shared with the Mac's `AutoLinks`; both
 * run `shared/fixtures/auto-links.json`.
 */
class AutoLinks(titles: Collection<String>, current: String? = null) {
    private val titleByKey: Map<String, String>
    private val pattern: Regex?

    init {
        val usable = titles
            .filter { it.trim().length >= MIN_TITLE_LENGTH && !it.equals(current, ignoreCase = true) }
            .distinctBy { it.lowercase() }
            .sortedByDescending { it.length } // longest first: alternation takes the first that matches
        titleByKey = usable.associateBy { it.lowercase() }
        pattern = if (usable.isEmpty()) {
            null
        } else {
            Regex(
                "(?<![$WORD])(?:" + usable.joinToString("|") { Regex.escape(it) } + ")(?![$WORD])",
                RegexOption.IGNORE_CASE,
            )
        }
    }

    /**
     * Auto-links in the lines of [text] covered by [range], given that text's
     * [spans] (from [MarkdownSpans.parse], at least over [range]).
     */
    fun find(text: String, spans: List<MarkdownSpan>, range: SpanRange = SpanRange(0, text.length)): List<AutoLink> {
        val pattern = pattern ?: return emptyList()
        if (range.length <= 0) return emptyList()
        // Mask what can't hold an auto-link, so matches can't start, end, or run through it.
        val chars = text.substring(range.location, range.end).toCharArray()
        for (span in spans) {
            if (span.kind !in excludedKinds) continue
            val from = maxOf(span.range.location, range.location) - range.location
            val to = minOf(span.range.end, range.end) - range.location
            for (i in from until to) chars[i] = MASK
        }
        return pattern.findAll(String(chars)).map { m ->
            val location = range.location + m.range.first
            val matched = text.substring(location, location + m.value.length)
            AutoLink(SpanRange(location, matched.length), titleByKey[matched.lowercase()] ?: canonical(matched))
        }.toList()
    }

    /** The title a match stands for, when lowercasing isn't enough to find it (rare Unicode cases). */
    private fun canonical(matched: String): String =
        titleByKey.values.firstOrNull { it.equals(matched, ignoreCase = true) } ?: matched

    companion object {
        const val MIN_TITLE_LENGTH = 3

        private const val WORD = """\p{L}\p{M}\p{Nd}\p{Pc}"""
        private const val MASK = '\u0001'

        private val excludedKinds = setOf(
            MarkdownSpan.Kind.Code, MarkdownSpan.Kind.CodeBlock,
            MarkdownSpan.Kind.WikiLink, MarkdownSpan.Kind.Link, MarkdownSpan.Kind.Url,
        )
    }
}
