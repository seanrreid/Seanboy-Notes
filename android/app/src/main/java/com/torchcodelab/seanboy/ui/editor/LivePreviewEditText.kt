package com.torchcodelab.seanboy.ui.editor

import android.annotation.SuppressLint
import android.content.ActivityNotFoundException
import android.content.Context
import android.content.Intent
import android.graphics.Rect
import android.net.Uri
import android.text.Editable
import android.text.InputType
import android.text.Selection
import android.text.TextWatcher
import android.view.Gravity
import android.view.KeyEvent
import android.view.MotionEvent
import android.view.inputmethod.InputMethodManager
import android.widget.EditText
import com.torchcodelab.seanboy.core.AutoLinks
import com.torchcodelab.seanboy.core.ListEditing
import com.torchcodelab.seanboy.core.LivePreview
import com.torchcodelab.seanboy.core.MarkdownSpans
import com.torchcodelab.seanboy.core.SpanRange

/**
 * The note body with Obsidian-style Live Preview: Markdown is styled in place
 * with spans, and syntax markers are hidden except on the cursor lines, where
 * they show faded. The text is always the note's Markdown, untouched.
 *
 * Styling is incremental, like the Mac editor: an edit restyles only the
 * edited lines (to the end of the note when a code fence changes), and moving
 * the cursor restyles just the old and new cursor lines.
 *
 * List editing follows the Mac (`ListEditing` in :core): Enter continues a
 * list or ends it on an empty item, Backspace right after a marker removes it,
 * and a hardware keyboard's Tab/Shift-Tab change depth and Home stops at the
 * item's text. Soft keyboards send Enter and Backspace as text changes, not
 * key events, so those rules run on the change itself.
 *
 * Taps on a rendered checkbox toggle it; taps on a rendered link open it
 * (a note for `[[wiki links]]` and auto-linked titles, the browser for URLs). On the cursor line a
 * tap just places the cursor, so links there stay editable.
 */
@SuppressLint("AppCompatCustomView", "ViewConstructor")
class LivePreviewEditText(context: Context) : EditText(context) {
    var onMarkdownChange: ((String) -> Unit)? = null
    var onOpenWikiLink: ((String) -> Unit)? = null

    var colors: LivePreviewColors? = null
        set(value) {
            if (value == field) return
            field = value
            styleAll()
        }

    /** Other notes' titles to underline in the text, or null when auto-links are off. */
    var autoLinks: AutoLinks? = null
        set(value) {
            if (value === field) return
            field = value
            styleAll()
        }

    private val density = resources.displayMetrics.density
    private var ready = false
    private var applyingText = false
    private var editing = false
    private var pendingEdit: SpanRange? = null

    /** The change in flight, to recognize a typed Enter or Backspace: what was replaced, and the selection before. */
    private var replaced = ""
    private var selectionBefore = SpanRange(0, 0)
    private var applyingRule = false
    private var fenceLineCount = 0

    /** Lines whose markers show: the cursor/selection lines while focused, else null. */
    private var revealedLines: SpanRange? = null

    init {
        background = null
        gravity = Gravity.TOP or Gravity.START
        inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_FLAG_MULTI_LINE or
            InputType.TYPE_TEXT_FLAG_CAP_SENTENCES or InputType.TYPE_TEXT_FLAG_AUTO_CORRECT
        isVerticalScrollBarEnabled = true
        setLineSpacing(0f, 1.15f)
        addTextChangedListener(object : TextWatcher {
            override fun beforeTextChanged(s: CharSequence?, start: Int, count: Int, after: Int) {
                editing = true
                if (s == null || applyingRule) return
                replaced = s.subSequence(start, start + count).toString()
                val selStart = Selection.getSelectionStart(s)
                val selEnd = Selection.getSelectionEnd(s)
                selectionBefore = SpanRange(minOf(selStart, selEnd), kotlin.math.abs(selEnd - selStart))
            }

            override fun onTextChanged(s: CharSequence?, start: Int, before: Int, count: Int) {
                val previous = pendingEdit
                pendingEdit = if (previous == null) {
                    SpanRange(start, count)
                } else {
                    val from = minOf(previous.location, start)
                    SpanRange(from, maxOf(previous.end, start + count) - from)
                }
            }

            override fun afterTextChanged(s: Editable) {
                editing = false
                val edit = pendingEdit ?: return
                pendingEdit = null
                if (applyingText || applyingRule) return
                if (applyListRule(s, edit)) return
                restyleEdit(s, edit)
                onMarkdownChange?.invoke(s.toString())
            }
        })
        ready = true
    }

    /** Replaces the whole text (a different note) and styles it. */
    fun setMarkdown(markdown: String) {
        applyingText = true
        setText(markdown)
        applyingText = false
        styleAll()
    }

    /** Focus with the cursor at the very start and the keyboard up (Enter from the title). */
    fun focusAtStart() {
        requestFocus()
        setSelection(0)
        context.getSystemService(InputMethodManager::class.java)?.showSoftInput(this, 0)
    }

    // MARK: - List editing

    /**
     * A soft keyboard's Enter arrives as an inserted "\n" and its Backspace
     * as one deleted character before the caret. When a list rule applies to
     * the text as it was, undo the change and make the rule's edit instead.
     */
    private fun applyListRule(text: Editable, edit: SpanRange): Boolean {
        val start = edit.location
        val insertedNewline = edit.length == 1 && text[start] == '\n'
        val deletedBeforeCaret = edit.length == 0 && replaced.length == 1 &&
            selectionBefore.length == 0 && selectionBefore.location == start + 1
        if (!insertedNewline && !deletedBeforeCaret) return false

        val before = text.substring(0, start) + replaced + text.substring(start + edit.length)
        val rule = if (insertedNewline) {
            ListEditing.enter(before, SpanRange(start, replaced.length))
        } else {
            ListEditing.backspace(before, SpanRange(start + 1, 0))
        } ?: return false

        applyingRule = true
        text.replace(start, start + edit.length, replaced) // back to the text before the key
        text.replace(rule.range.location, rule.range.end, rule.replacement)
        applyingRule = false
        finishRule(rule)
        return true
    }

    /** Applies a list rule's edit from a hardware key (Tab, Shift-Tab). */
    private fun perform(rule: ListEditing.Edit?): Boolean {
        val text = editableText ?: return false
        rule ?: return false
        if (rule.range.length > 0 || rule.replacement.isNotEmpty()) {
            applyingRule = true
            text.replace(rule.range.location, rule.range.end, rule.replacement)
            applyingRule = false
        }
        finishRule(rule)
        return true
    }

    private fun finishRule(rule: ListEditing.Edit) {
        val text = editableText ?: return
        val length = text.length
        val start = rule.selection.location.coerceIn(0, length)
        setSelection(start, (start + rule.selection.length).coerceIn(start, length))
        styleAll()
        onMarkdownChange?.invoke(text.toString())
    }

    override fun onKeyDown(keyCode: Int, event: KeyEvent): Boolean {
        val markdown = text?.toString() ?: return super.onKeyDown(keyCode, event)
        val selection = SpanRange(minOf(selectionStart, selectionEnd), kotlin.math.abs(selectionEnd - selectionStart))
        val handled = when (keyCode) {
            KeyEvent.KEYCODE_TAB -> when {
                event.isShiftPressed -> perform(ListEditing.indent(markdown, selection, outdent = true))
                event.hasNoModifiers() -> perform(ListEditing.indent(markdown, selection, outdent = false)) ||
                    insertTab()
                else -> false
            }
            KeyEvent.KEYCODE_MOVE_HOME -> event.hasNoModifiers() && selection.length == 0 &&
                ListEditing.lineStart(markdown, selection.location)?.let { setSelection(it); true } == true
            else -> false
        }
        return handled || super.onKeyDown(keyCode, event)
    }

    /** Tab outside a list types a tab, as on the Mac, instead of moving focus. */
    private fun insertTab(): Boolean {
        val text = editableText ?: return false
        text.replace(minOf(selectionStart, selectionEnd), maxOf(selectionStart, selectionEnd), "\t")
        return true
    }

    // MARK: - Styling

    private fun styleAll() {
        val text = editableText ?: return
        fenceLineCount = MarkdownSpans.fenceLineCount(text.toString())
        revealedLines = currentRevealedLines()
        restyle(text, SpanRange(0, text.length))
    }

    /** Restyles the lines touching [range] (widened to whole code blocks). */
    private fun restyle(text: Editable, range: SpanRange) {
        val colors = colors ?: return
        val markdown = text.toString()
        val clamped = SpanRange(
            minOf(range.location, markdown.length),
            minOf(range.length, markdown.length - minOf(range.location, markdown.length)),
        )
        val (spans, covered) = MarkdownSpans.parse(markdown, clamped)
        val links = autoLinks?.find(markdown, spans, covered).orEmpty()
        LivePreviewSpans.clear(text, covered)
        LivePreviewSpans.apply(text, LivePreview.styles(markdown, spans, revealedLines, links), colors, density, ::getLayout)
    }

    /**
     * Restyles only the edited lines. Adding, removing, or changing a code
     * fence can restyle everything below it, so that restyles to the end.
     */
    private fun restyleEdit(text: Editable, edit: SpanRange) {
        val markdown = text.toString()
        val old = revealedLines
        revealedLines = currentRevealedLines()
        val editedLines = MarkdownSpans.lineRange(markdown, clampTo(edit, markdown.length))
        val lines = markdown.substring(editedLines.location, editedLines.end)
        val fences = MarkdownSpans.fenceLineCount(markdown)
        if (fences != fenceLineCount || "```" in lines || "~~~" in lines) {
            fenceLineCount = fences
            restyle(text, SpanRange(edit.location, markdown.length - minOf(edit.location, markdown.length)))
        } else {
            restyle(text, edit)
        }
        // An edit can move the cursor to another line (paste, Enter): restyle the line it left.
        if (old != null && old != revealedLines) restyle(text, clampTo(old, markdown.length))
    }

    private fun currentRevealedLines(): SpanRange? {
        if (!hasFocus()) return null
        val text = editableText?.toString() ?: return null
        val start = selectionStart.coerceIn(0, text.length)
        val end = selectionEnd.coerceIn(start, text.length)
        return MarkdownSpans.lineRange(text, SpanRange(start, end - start))
    }

    /** Moving the cursor to another line (or focus in/out) swaps which lines show markers. */
    private fun updateRevealedLines() {
        if (!ready || editing || applyingText) return
        val text = editableText ?: return
        val new = currentRevealedLines()
        if (new == revealedLines) return
        val old = revealedLines
        revealedLines = new
        for (lines in listOfNotNull(old, new)) restyle(text, clampTo(lines, text.length))
    }

    override fun onSelectionChanged(selStart: Int, selEnd: Int) {
        super.onSelectionChanged(selStart, selEnd)
        updateRevealedLines()
    }

    override fun onFocusChanged(focused: Boolean, direction: Int, previouslyFocusedRect: Rect?) {
        super.onFocusChanged(focused, direction, previouslyFocusedRect)
        updateRevealedLines()
    }

    private fun clampTo(range: SpanRange, length: Int): SpanRange {
        val location = minOf(range.location, length)
        return SpanRange(location, minOf(range.length, length - location))
    }

    // MARK: - Taps on checkboxes and links

    private var pressed: Any? = null

    @SuppressLint("ClickableViewAccessibility")
    override fun onTouchEvent(event: MotionEvent): Boolean {
        when (event.actionMasked) {
            MotionEvent.ACTION_DOWN -> {
                pressed = targetAt(event.x, event.y)
                if (pressed != null) return true
            }
            MotionEvent.ACTION_MOVE -> if (pressed != null) return true
            MotionEvent.ACTION_UP -> {
                val target = pressed ?: return super.onTouchEvent(event)
                pressed = null
                if (target == targetAt(event.x, event.y)) activate(target)
                return true
            }
            MotionEvent.ACTION_CANCEL -> if (pressed != null) {
                pressed = null
                return true
            }
        }
        return super.onTouchEvent(event)
    }

    /** The rendered checkbox or link under a touch, or null to edit normally. */
    private fun targetAt(x: Float, y: Float): Any? {
        val text = editableText ?: return null
        val layout = layout ?: return null
        val layoutX = x - totalPaddingLeft + scrollX
        val layoutY = y - totalPaddingTop + scrollY
        val line = layout.getLineForVertical(layoutY.toInt())
        val lineStart = layout.getLineStart(line)
        val lineEnd = layout.getLineEnd(line)

        val slop = 8 * density
        for (box in text.getSpans(lineStart, lineEnd, LivePreviewSpans.CheckboxSpan::class.java)) {
            val rect = box.box ?: continue
            if (layoutX in rect.left - slop..rect.right + slop && layoutY in rect.top - slop..rect.bottom + slop) {
                return box
            }
        }

        if (layoutX < layout.getLineLeft(line) || layoutX > layout.getLineRight(line)) return null
        // The nearest boundary; step back one if the finger is on the character before it.
        val boundary = layout.getOffsetForHorizontal(line, layoutX)
        val offset = if (boundary > lineStart && layoutX < layout.getPrimaryHorizontal(boundary)) boundary - 1 else boundary
        val revealed = revealedLines
        // Links on the cursor lines are for editing; tapping there places the cursor.
        fun tappable(span: Any): Boolean {
            val start = text.getSpanStart(span)
            val end = text.getSpanEnd(span)
            return offset in start until end && (revealed == null || start > revealed.end || end < revealed.location)
        }
        return text.getSpans(offset, offset + 1, LivePreviewSpans.LinkSpan::class.java).firstOrNull(::tappable)
            ?: text.getSpans(offset, offset + 1, LivePreviewSpans.AutoLinkSpan::class.java).firstOrNull(::tappable)
    }

    private fun activate(target: Any) {
        val text = editableText ?: return
        when (target) {
            is LivePreviewSpans.CheckboxSpan -> {
                val box = text.getSpanStart(target)
                if (box < 0) return
                // Toggle `[ ]` ↔ `[x]` in the Markdown without moving the cursor.
                val start = selectionStart
                val end = selectionEnd
                text.replace(box, box + 1, if (target.checked) " " else "x")
                if (hasFocus()) setSelection(start.coerceAtMost(text.length), end.coerceAtMost(text.length))
            }
            is LivePreviewSpans.AutoLinkSpan -> onOpenWikiLink?.invoke(target.title)
            is LivePreviewSpans.LinkSpan -> if (target.isWikiLink) {
                onOpenWikiLink?.invoke(target.target)
            } else {
                openUrl(target.target)
            }
        }
    }

    private fun openUrl(target: String) {
        val uri = Uri.parse(target)
        if (uri.scheme.isNullOrEmpty()) return // a relative path, not something to open
        try {
            context.startActivity(Intent(Intent.ACTION_VIEW, uri))
        } catch (_: ActivityNotFoundException) {
            // Nothing on the device handles this kind of link.
        }
    }
}
