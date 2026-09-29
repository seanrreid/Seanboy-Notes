package com.torchcodelab.seanboy.core

/**
 * A one-line plain-text preview of a note body for list rows: frontmatter,
 * image embeds, and Markdown markers are dropped so the row shows prose.
 * Display-only; the file on disk is untouched.
 */
object NotePreview {
    private val frontmatter = Regex("""\A\s*---\r?\n.*?\r?\n---[ \t]*(\r?\n|\z)""", RegexOption.DOT_MATCHES_ALL)
    private val imageEmbed = Regex("""!\[\[[^\]]*]]|!\[[^\]]*]\([^)]*\)""")
    private val wikiLink = Regex("""\[\[([^\]|]*)(?:\|([^\]]*))?]]""")
    private val mdLink = Regex("""\[([^\]]*)]\([^)]*\)""")
    private val lineMarker = Regex("""^\s*(?:#{1,6}\s+|>\s?|[-*+]\s+(?:\[[ xX]]\s+)?|\d+[.)]\s+)""", RegexOption.MULTILINE)
    private val emphasis = Regex("""\*\*|__|~~|`|(?<![\w*])\*(?!\s)|(?<!\S)_(?!\s)|(?<=\S)[*_](?![\w*])""")
    private val whitespace = Regex("""\s+""")

    fun of(body: String, maxLength: Int = 140): String {
        var text = frontmatter.replace(body, "")
        text = imageEmbed.replace(text, " ")
        text = wikiLink.replace(text) { m -> m.groupValues[2].ifEmpty { m.groupValues[1] } }
        text = mdLink.replace(text) { it.groupValues[1] }
        text = lineMarker.replace(text, "")
        text = emphasis.replace(text, "")
        text = whitespace.replace(text, " ").trim()
        return if (text.length <= maxLength) text else text.take(maxLength).trimEnd() + "…"
    }
}
