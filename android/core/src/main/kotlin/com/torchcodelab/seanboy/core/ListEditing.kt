package com.torchcodelab.seanboy.core

/**
 * List-editing rules for the editor (GNote `NoteBuffer` behavior over plain
 * Markdown): Enter continues a list, Enter on an empty item ends it, Tab and
 * Shift-Tab change depth, Backspace after the marker removes it, and Home
 * stops at the start of the item's text. Each rule returns the single edit to
 * make, or null to fall back to normal text editing.
 *
 * Kotlin port of `mac/Sources/SeanboyCore/ListEditing.swift`. Both run
 * `shared/fixtures/list-editing.json`. Offsets are UTF-16, like the Mac's.
 */
object ListEditing {
    /** Replace [range] with [replacement], then put the selection at [selection]. */
    data class Edit(val range: SpanRange, val replacement: String, val selection: SpanRange)

    /** The list item on one line, from [MarkdownSpans]. */
    private class Item(
        val line: SpanRange, // line content, no terminator
        val indent: SpanRange, // leading whitespace
        val marker: SpanRange, // "- ", "3. ", "- [x] "
        val content: SpanRange, // text after the marker
        val span: MarkdownSpan,
    )

    // MARK: - Enter

    fun enter(text: String, selection: SpanRange): Edit? {
        val item = item(text, selection.location) ?: return null
        if (selection.location < item.content.location || selection.end > item.line.end) return null

        if (item.content.length == 0 || isBlank(text.slice(item.content))) {
            // Empty item: outdent if nested, else end the list.
            if (item.indent.length > 0) return outdent(text, item)
            return Edit(item.line, "", SpanRange(item.line.location, 0))
        }

        val insertion = "\n" + text.slice(item.indent) + nextMarker(text, item)
        return Edit(selection, insertion, SpanRange(selection.location + insertion.length, 0))
    }

    private fun nextMarker(text: String, item: Item): String {
        val marker = text.slice(item.marker)
        return when (item.span.kind) {
            MarkdownSpan.Kind.OrderedItem -> {
                val digits = marker.takeWhile { it.isDigit() }
                val delimiter = marker.getOrNull(digits.length) ?: '.'
                "${(digits.toIntOrNull() ?: 0) + 1}$delimiter "
            }
            // New tasks start unchecked, with the same bullet character.
            MarkdownSpan.Kind.Task -> "${marker.firstOrNull() ?: '-'} [ ] "
            else -> "${marker.firstOrNull() ?: '-'} "
        }
    }

    // MARK: - Tab / Shift-Tab

    /**
     * Indents (or outdents) every list item the selection touches. Returns
     * null when the selection touches no list items, so Tab inserts a tab.
     */
    fun indent(text: String, selection: SpanRange, outdent: Boolean): Edit? {
        val lines = MarkdownSpans.lineRange(text, selection)
        val unit = indentUnit(text)
        val result = StringBuilder()
        var delta = 0
        var startDelta = 0
        var touchedItem = false
        var next = lines.location
        while (next < lines.end) {
            val lineStart = next
            val (_, enclosingEnd) = lineAt(text, lineStart, lines.end)
            var lineText = text.substring(lineStart, enclosingEnd)
            if (item(text, lineStart) != null) {
                touchedItem = true
                val before = lineText.length
                lineText = if (outdent) removingOneLevel(lineText, unit) else unit + lineText
                val change = lineText.length - before
                if (lineStart <= selection.location) startDelta = change
                delta += change
            }
            result.append(lineText)
            next = enclosingEnd
        }
        if (!touchedItem) return null
        if (result.toString() == text.slice(lines)) return noOp(selection)
        val start = maxOf(lines.location, selection.location + startDelta)
        val newSelection = if (selection.length == 0) {
            SpanRange(start, 0)
        } else {
            SpanRange(start, maxOf(0, selection.length + delta - startDelta))
        }
        return Edit(lines, result.toString(), newSelection)
    }

    /** Shift-Tab on an item that can't outdent further: swallow the key. */
    private fun noOp(selection: SpanRange) = Edit(SpanRange(selection.location, 0), "", selection)

    /** Outdents an item one level, caret at the end of its line. */
    private fun outdent(text: String, item: Item): Edit {
        val indent = text.slice(item.indent)
        val newIndent = removingOneLevel(indent, indentUnit(text))
        val removed = indent.length - newIndent.length
        return Edit(item.indent, newIndent, SpanRange(item.line.end - removed, 0))
    }

    private fun removingOneLevel(line: String, unit: String): String {
        if (line.startsWith("\t")) return line.substring(1)
        val spaces = line.takeWhile { it == ' ' }.length
        val width = if (unit == "\t") 4 else unit.length
        return line.substring(minOf(spaces, width))
    }

    /**
     * The note's own nesting style: tabs if any list item is tab-indented,
     * else the smallest space indent used (2–4), else a tab (Obsidian's default).
     */
    internal fun indentUnit(text: String): String {
        var smallest = Int.MAX_VALUE
        var next = 0
        while (next < text.length) {
            val (lineEnd, enclosingEnd) = lineAt(text, next, text.length)
            val line = text.substring(next, lineEnd)
            next = enclosingEnd
            val first = line.firstOrNull() ?: continue
            if (first != ' ' && first != '\t') continue
            val marker = line.trimStart(' ', '\t').firstOrNull() ?: continue
            if (marker !in "-*+" && !marker.isDigit()) continue
            if (first == '\t') return "\t"
            smallest = minOf(smallest, line.takeWhile { it == ' ' }.length)
        }
        if (smallest == Int.MAX_VALUE) return "\t"
        return " ".repeat(smallest.coerceIn(2, 4))
    }

    // MARK: - Backspace

    /**
     * Backspace right after an item's marker removes the marker (outdenting
     * first when nested), keeping the text.
     */
    fun backspace(text: String, selection: SpanRange): Edit? {
        if (selection.length != 0) return null
        val item = item(text, selection.location) ?: return null
        if (selection.location != item.content.location) return null
        if (item.indent.length > 0) {
            val indent = text.slice(item.indent)
            val newIndent = removingOneLevel(indent, indentUnit(text))
            val removed = indent.length - newIndent.length
            return Edit(item.indent, newIndent, SpanRange(selection.location - removed, 0))
        }
        return Edit(item.marker, "", SpanRange(item.marker.location, 0))
    }

    // MARK: - Home

    /**
     * Home inside a list item goes to the start of its text; from there (or
     * from inside the marker) it goes to the start of the line.
     */
    fun lineStart(text: String, caret: Int): Int? {
        val item = item(text, caret) ?: return null
        return if (caret > item.content.location) item.content.location else item.line.location
    }

    // MARK: - Checkboxes

    /** Toggles the `[ ]`/`[x]` of the task on the line containing [location]. */
    fun toggleTask(text: String, location: Int): Edit? {
        val item = item(text, location) ?: return null
        if (item.span.kind != MarkdownSpan.Kind.Task) return null
        val bracket = text.slice(item.marker).indexOf('[')
        if (bracket < 0) return null
        val box = SpanRange(item.marker.location + bracket + 1, 1)
        return Edit(box, if (item.span.checked) " " else "x", SpanRange(location, 0))
    }

    // MARK: - Helpers

    private val listKinds = setOf(MarkdownSpan.Kind.Bullet, MarkdownSpan.Kind.OrderedItem, MarkdownSpan.Kind.Task)

    private fun item(text: String, location: Int): Item? {
        val clamped = location.coerceIn(0, text.length)
        val enclosing = MarkdownSpans.lineRange(text, SpanRange(clamped, 0))
        var contentEnd = enclosing.end
        while (contentEnd > enclosing.location && isNewline(text[contentEnd - 1])) contentEnd--
        val line = SpanRange(enclosing.location, contentEnd - enclosing.location)
        val (spans, _) = MarkdownSpans.parse(text, line)
        // List spans start at the marker, after any indent, on this line.
        val span = spans.firstOrNull {
            it.kind in listKinds && it.range.location >= line.location && it.range.location <= line.end
        } ?: return null
        val marker = span.markers.firstOrNull() ?: return null
        return Item(
            line = line,
            indent = SpanRange(line.location, marker.location - line.location),
            marker = marker,
            content = span.content,
            span = span,
        )
    }

    /** Foundation's `CharacterSet.newlines`. */
    private fun isNewline(c: Char) = c in '\u000A'..'\u000D' || c == '\u0085' || c == '\u2028' || c == '\u2029'

    private fun isBlank(s: String) = s.all { it == ' ' || it == '\t' }

    private fun String.slice(range: SpanRange) = substring(range.location, range.end)

    /** The line starting at [start] (within [limit]): its end, and its end with the terminator. */
    private fun lineAt(text: String, start: Int, limit: Int): Pair<Int, Int> {
        var end = start
        while (end < limit && !isLineTerminator(text[end])) end++
        var enclosingEnd = end
        if (end < limit) {
            enclosingEnd = if (text[end] == '\r' && end + 1 < limit && text[end + 1] == '\n') end + 2 else end + 1
        }
        return end to enclosingEnd
    }

    /** NSString `.byLines` terminators. */
    private fun isLineTerminator(c: Char) = c == '\n' || c == '\r' || c == '\u0085' || c == '\u2028' || c == '\u2029'
}
