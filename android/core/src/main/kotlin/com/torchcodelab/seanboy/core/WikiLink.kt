package com.torchcodelab.seanboy.core

/** A `[[Note Title]]` occurrence inside a note body. */
data class WikiLink(
    /** The linked note's title, trimmed. */
    val title: String,
    /** Range of the whole `[[...]]` token in the source string (inclusive start, exclusive end). */
    val range: IntRange,
)

/** Faithful Kotlin port of `mac/Sources/SeanboyCore/WikiLink.swift`. */
object WikiLinkParser {
    // [[ anything that isn't ]] or a newline ]]
    private val regex = Regex("""\[\[([^\[\]\n]+)]]""")

    /** All wiki links in [text], in document order. */
    fun links(text: String): List<WikiLink> =
        regex.findAll(text).mapNotNull { match ->
            val title = match.groupValues[1].trim()
            if (title.isEmpty()) null
            else WikiLink(title = title, range = match.range)
        }.toList()

    /** Distinct linked titles (case-insensitively deduped, original casing kept). */
    fun linkedTitles(text: String): List<String> {
        val seen = HashSet<String>()
        val titles = mutableListOf<String>()
        for (link in links(text)) {
            if (seen.add(link.title.lowercase())) titles.add(link.title)
        }
        return titles
    }

    /** Notes among [notes] whose bodies link to [title] (the backlinks pane). */
    fun backlinks(title: String, notes: List<Note>): List<Note> {
        val needle = title.trim().lowercase()
        if (needle.isEmpty()) return emptyList()
        return notes.filter { note ->
            !note.isDeleted && linkedTitles(note.body).any { it.lowercase() == needle }
        }
    }
}
