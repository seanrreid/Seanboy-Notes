package com.torchcodelab.seanboy.core

import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/** Runs `shared/fixtures/list-editing.json` (the Mac's `ListEditingTests.swift` runs it too). */
class ListEditingTest {
    @Serializable
    private data class Fixtures(val cases: List<Case>)

    @Serializable
    private data class Case(val name: String, val action: String, val before: String, val after: String?)

    private val fixtureFile =
        File(System.getProperty("seanboy.fixtures") ?: "../../shared/fixtures", "list-editing.json")

    /** "a|b" → ("ab", caret 1); "«ab»" → ("ab", selection 0..2). */
    private fun decode(marked: String): Pair<String, SpanRange> {
        val text = StringBuilder()
        var start = 0
        var end: Int? = null
        for (c in marked) {
            when (c) {
                '|', '«' -> start = text.length
                '»' -> end = text.length
                else -> text.append(c)
            }
        }
        return text.toString() to SpanRange(start, (end ?: start) - start)
    }

    private fun encode(text: String, selection: SpanRange): String {
        val head = text.substring(0, selection.location)
        if (selection.length == 0) return head + "|" + text.substring(selection.location)
        return head + "«" + text.substring(selection.location, selection.end) + "»" + text.substring(selection.end)
    }

    private fun run(action: String, text: String, selection: SpanRange): Pair<String, SpanRange>? {
        val edit = when (action) {
            "enter" -> ListEditing.enter(text, selection)
            "tab" -> ListEditing.indent(text, selection, outdent = false)
            "shiftTab" -> ListEditing.indent(text, selection, outdent = true)
            "backspace" -> ListEditing.backspace(text, selection)
            "toggle" -> ListEditing.toggleTask(text, selection.location)
            "home" -> return ListEditing.lineStart(text, selection.location)?.let { text to SpanRange(it, 0) }
            else -> error("unknown action $action")
        } ?: return null
        val result = text.substring(0, edit.range.location) + edit.replacement + text.substring(edit.range.end)
        return result to edit.selection
    }

    @Test
    fun sharedFixtures() {
        val fixtures = Json { ignoreUnknownKeys = true }.decodeFromString<Fixtures>(fixtureFile.readText())
        assertFalse(fixtures.cases.isEmpty())
        val failures = fixtures.cases.mapNotNull { fixture ->
            val (text, selection) = decode(fixture.before)
            val result = run(fixture.action, text, selection)?.let { (t, s) -> encode(t, s) }
            if (result == fixture.after) null else "${fixture.name}: expected ${fixture.after}, got $result"
        }
        assertTrue(failures.joinToString("\n"), failures.isEmpty())
    }

    @Test
    fun indentUnitFollowsTheNote() {
        assertEquals("\t", ListEditing.indentUnit("- a\n- b"))
        assertEquals("\t", ListEditing.indentUnit("- a\n\t- b\n  - c"))
        assertEquals("  ", ListEditing.indentUnit("- a\n    - b\n  - c"))
        assertEquals("  ", ListEditing.indentUnit("- a\n - b")) // at least 2
        assertEquals("    ", ListEditing.indentUnit("- a\n        - b")) // at most 4
        assertEquals("\t", ListEditing.indentUnit("  plain indented text"))
    }
}
