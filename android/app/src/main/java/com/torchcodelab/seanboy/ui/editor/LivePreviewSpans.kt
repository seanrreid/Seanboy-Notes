package com.torchcodelab.seanboy.ui.editor

import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.RectF
import android.graphics.Typeface
import android.text.Layout
import android.text.Spannable
import android.text.Spanned
import android.text.TextPaint
import android.text.style.CharacterStyle
import android.text.style.LeadingMarginSpan
import android.text.style.LineBackgroundSpan
import android.text.style.MetricAffectingSpan
import android.text.style.ReplacementSpan
import android.text.style.UpdateAppearance
import com.torchcodelab.seanboy.core.LivePreview
import com.torchcodelab.seanboy.core.LivePreview.Style
import com.torchcodelab.seanboy.core.SpanRange

/** Colors for Live Preview, resolved from the Material theme (ARGB ints). */
data class LivePreviewColors(
    val accent: Int,
    val secondary: Int,
    val faded: Int,
    val codeText: Int,
    val codeBackground: Int,
    val highlight: Int,
    val rule: Int,
    val autoLink: Int,
)

/**
 * Every span the Live Preview styler sets implements this, so a restyle
 * removes exactly its own spans and never the IME's composing or selection spans.
 */
interface LivePreviewSpan

/**
 * Maps [LivePreview] styles onto Android text spans. Like the Mac's
 * `MarkdownStyler`, it only sets spans; the characters stay the note's Markdown.
 */
object LivePreviewSpans {
    private val headingScale = floatArrayOf(1.6f, 1.33f, 1.13f, 1f, 1f, 1f)

    /** Removes this styler's spans that lie inside [range]. */
    fun clear(text: Spannable, range: SpanRange) {
        for (span in text.getSpans(range.location, range.end, LivePreviewSpan::class.java)) {
            if (text.getSpanStart(span) >= range.location && text.getSpanEnd(span) <= range.end) {
                text.removeSpan(span)
            }
        }
    }

    /** [layout] is the editor's current layout, for spans that draw by position. */
    fun apply(
        text: Spannable,
        styles: List<LivePreview.Styled>,
        colors: LivePreviewColors,
        density: Float,
        layout: () -> Layout?,
    ) {
        for ((style, range) in styles) {
            for (span in spansFor(style, colors, density, layout)) {
                text.setSpan(span, range.location, range.end, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
            }
        }
    }

    private fun spansFor(style: Style, colors: LivePreviewColors, density: Float, layout: () -> Layout?): List<Any> =
        when (style) {
            is Style.Heading -> listOf(
                Scale(headingScale[(style.level - 1).coerceIn(0, 5)]), Bold(), Color(colors.accent),
            )
            Style.Bold -> listOf(Bold())
            Style.Italic -> listOf(Italic())
            Style.Strikethrough -> listOf(Strike())
            Style.Highlight -> listOf(Background(colors.highlight))
            Style.Monospace -> listOf(Monospace())
            Style.InlineCode -> listOf(Color(colors.codeText), Background(colors.codeBackground))
            Style.CodeBlock -> listOf(CodeBlockSpan(colors.codeBackground, density))
            is Style.Link -> listOf(LinkSpan(style.target, style.isWikiLink, colors.accent))
            is Style.Quote -> listOf(QuoteSpan(colors.accent, style.markerShown, density))
            Style.QuoteText -> listOf(Color(colors.secondary))
            Style.Rule -> listOf(RuleSpan(colors.rule, density))
            Style.Hidden -> listOf(HiddenSpan())
            Style.Faded -> listOf(Color(colors.faded))
            Style.Tinted -> listOf(Color(colors.accent))
            Style.Bullet -> listOf(BulletGlyphSpan(colors.accent))
            is Style.Checkbox -> listOf(CheckboxSpan(style.checked, colors.accent, density))
            Style.DoneTask -> listOf(Strike(), Color(colors.secondary))
            is Style.AutoLink -> listOf(AutoLinkSpan(style.title, colors.autoLink, density, layout))
        }

    // MARK: - Character styles

    private class Color(private val color: Int) : CharacterStyle(), UpdateAppearance, LivePreviewSpan {
        override fun updateDrawState(tp: TextPaint) { tp.color = color }
    }

    private class Background(private val color: Int) : CharacterStyle(), UpdateAppearance, LivePreviewSpan {
        override fun updateDrawState(tp: TextPaint) { tp.bgColor = color }
    }

    private class Strike : CharacterStyle(), UpdateAppearance, LivePreviewSpan {
        override fun updateDrawState(tp: TextPaint) { tp.isStrikeThruText = true }
    }

    /** Adds a typeface style on top of the current one, so bold inside a heading stays heading-sized. */
    private open class StyleFlag(private val flag: Int) : MetricAffectingSpan(), LivePreviewSpan {
        override fun updateDrawState(tp: TextPaint) = apply(tp)
        override fun updateMeasureState(tp: TextPaint) = apply(tp)
        private fun apply(tp: TextPaint) {
            val old = tp.typeface ?: Typeface.DEFAULT
            val wanted = old.style or flag
            val typeface = Typeface.create(old, wanted)
            val missing = wanted and typeface.style.inv()
            if (missing and Typeface.BOLD != 0) tp.isFakeBoldText = true
            if (missing and Typeface.ITALIC != 0) tp.textSkewX = -0.25f
            tp.typeface = typeface
        }
    }

    private class Bold : StyleFlag(Typeface.BOLD)
    private class Italic : StyleFlag(Typeface.ITALIC)

    private class Scale(private val factor: Float) : MetricAffectingSpan(), LivePreviewSpan {
        override fun updateDrawState(tp: TextPaint) { tp.textSize *= factor }
        override fun updateMeasureState(tp: TextPaint) { tp.textSize *= factor }
    }

    /** Monospace at 90%, like the Mac's smaller code font. */
    private class Monospace : MetricAffectingSpan(), LivePreviewSpan {
        override fun updateDrawState(tp: TextPaint) = apply(tp)
        override fun updateMeasureState(tp: TextPaint) = apply(tp)
        private fun apply(tp: TextPaint) {
            tp.typeface = Typeface.create(Typeface.MONOSPACE, tp.typeface?.style ?: Typeface.NORMAL)
            tp.textSize *= 0.9f
        }
    }

    /** A tappable link. The editor handles the tap (see `LivePreviewEditText`). */
    class LinkSpan(val target: String, val isWikiLink: Boolean, private val color: Int) :
        CharacterStyle(), UpdateAppearance, LivePreviewSpan {
        override fun updateDrawState(tp: TextPaint) {
            tp.color = color
            tp.isUnderlineText = true
        }
    }

    // MARK: - Replacements

    /** Markers not drawn at all. Keeps the line's height so a hidden-only line doesn't collapse. */
    private class HiddenSpan : ReplacementSpan(), LivePreviewSpan {
        override fun getSize(paint: Paint, text: CharSequence?, start: Int, end: Int, fm: Paint.FontMetricsInt?): Int {
            if (fm != null) paint.getFontMetricsInt(fm)
            return 0
        }

        override fun draw(
            canvas: Canvas, text: CharSequence?, start: Int, end: Int,
            x: Float, top: Int, y: Int, bottom: Int, paint: Paint,
        ) = Unit
    }

    /** A list marker drawn as `•`. */
    private class BulletGlyphSpan(private val color: Int) : ReplacementSpan(), LivePreviewSpan {
        override fun getSize(paint: Paint, text: CharSequence?, start: Int, end: Int, fm: Paint.FontMetricsInt?): Int {
            if (fm != null) paint.getFontMetricsInt(fm)
            return paint.measureText(BULLET).toInt()
        }

        override fun draw(
            canvas: Canvas, text: CharSequence?, start: Int, end: Int,
            x: Float, top: Int, y: Int, bottom: Int, paint: Paint,
        ) {
            val old = paint.color
            paint.color = color
            canvas.drawText(BULLET, x, y.toFloat(), paint)
            paint.color = old
        }

        private companion object { const val BULLET = "•" }
    }

    /** A task's box character drawn as a checkbox. Tapping it toggles `[ ]`/`[x]`. */
    class CheckboxSpan(val checked: Boolean, private val color: Int, private val density: Float) :
        ReplacementSpan(), LivePreviewSpan {
        /** Where the box was last drawn, in layout coordinates, for hit-testing taps. */
        var box: RectF? = null
            private set

        private fun side(paint: Paint) = paint.textSize * 0.95f

        override fun getSize(paint: Paint, text: CharSequence?, start: Int, end: Int, fm: Paint.FontMetricsInt?): Int {
            if (fm != null) paint.getFontMetricsInt(fm)
            return (side(paint) + 2 * density).toInt()
        }

        override fun draw(
            canvas: Canvas, text: CharSequence?, start: Int, end: Int,
            x: Float, top: Int, y: Int, bottom: Int, paint: Paint,
        ) {
            val side = side(paint)
            val fm = paint.fontMetrics
            val centerY = y + (fm.ascent + fm.descent) / 2
            val rect = RectF(x, centerY - side / 2, x + side, centerY + side / 2)
            box = RectF(rect)
            val oldStyle = paint.style
            val oldColor = paint.color
            val oldWidth = paint.strokeWidth
            val radius = 3 * density
            paint.color = color
            if (checked) {
                paint.style = Paint.Style.FILL
                canvas.drawRoundRect(rect, radius, radius, paint)
                paint.color = android.graphics.Color.WHITE
                paint.style = Paint.Style.STROKE
                paint.strokeWidth = 2 * density
                paint.strokeCap = Paint.Cap.ROUND
                val l = rect.left; val t = rect.top; val s = side
                canvas.drawLine(l + s * 0.24f, t + s * 0.52f, l + s * 0.42f, t + s * 0.70f, paint)
                canvas.drawLine(l + s * 0.42f, t + s * 0.70f, l + s * 0.76f, t + s * 0.32f, paint)
            } else {
                paint.style = Paint.Style.STROKE
                paint.strokeWidth = 1.5f * density
                canvas.drawRoundRect(rect, radius, radius, paint)
            }
            paint.style = oldStyle
            paint.color = oldColor
            paint.strokeWidth = oldWidth
        }
    }

    // MARK: - Line decorations

    /**
     * An auto-link: a dotted underline under text that matches another note's
     * title. Drawn as a line background (Android has no dotted underline), using
     * the layout's selection path so it follows wrapped lines and styled text.
     */
    class AutoLinkSpan(
        val title: String,
        private val color: Int,
        private val density: Float,
        private val layout: () -> Layout?,
    ) : LineBackgroundSpan, LivePreviewSpan {
        private val path = android.graphics.Path()
        private val bounds = RectF()

        override fun drawBackground(
            canvas: Canvas, paint: Paint, left: Int, right: Int, top: Int, baseline: Int, bottom: Int,
            text: CharSequence, start: Int, end: Int, lineNumber: Int,
        ) {
            val spanned = text as? Spanned ?: return
            val layout = layout() ?: return
            val from = maxOf(spanned.getSpanStart(this), start)
            val to = minOf(spanned.getSpanEnd(this), end)
            if (from >= to) return
            path.reset()
            layout.getSelectionPath(from, to, path)
            path.computeBounds(bounds, true)
            if (bounds.width() <= 0) return
            val oldColor = paint.color
            val oldStyle = paint.style
            paint.color = color
            paint.style = Paint.Style.FILL
            val y = baseline + 2.5f * density
            val radius = 0.9f * density
            var x = bounds.left + radius
            while (x <= bounds.right - radius) {
                canvas.drawCircle(x, y, radius, paint)
                x += 3.5f * density
            }
            paint.color = oldColor
            paint.style = oldStyle
        }
    }

    /** Code block background and indent. */
    private class CodeBlockSpan(private val color: Int, private val density: Float) :
        LineBackgroundSpan, LeadingMarginSpan, LivePreviewSpan {
        override fun getLeadingMargin(first: Boolean) = (10 * density).toInt()

        override fun drawLeadingMargin(
            c: Canvas, p: Paint, x: Int, dir: Int, top: Int, baseline: Int, bottom: Int,
            text: CharSequence?, start: Int, end: Int, first: Boolean, layout: Layout?,
        ) = Unit

        override fun drawBackground(
            canvas: Canvas, paint: Paint, left: Int, right: Int, top: Int, baseline: Int, bottom: Int,
            text: CharSequence, start: Int, end: Int, lineNumber: Int,
        ) {
            val old = paint.color
            paint.color = color
            canvas.drawRect(left.toFloat(), top.toFloat(), right.toFloat(), bottom.toFloat(), paint)
            paint.color = old
        }
    }

    /** Quote bar and indent. The first line isn't indented while its `> ` shows. */
    private class QuoteSpan(private val color: Int, private val markerShown: Boolean, private val density: Float) :
        LeadingMarginSpan, LivePreviewSpan {
        override fun getLeadingMargin(first: Boolean) = if (first && markerShown) 0 else (16 * density).toInt()

        override fun drawLeadingMargin(
            c: Canvas, p: Paint, x: Int, dir: Int, top: Int, baseline: Int, bottom: Int,
            text: CharSequence?, start: Int, end: Int, first: Boolean, layout: Layout?,
        ) {
            val oldColor = p.color
            val oldStyle = p.style
            p.color = color
            p.style = Paint.Style.FILL
            c.drawRect(x.toFloat(), top.toFloat(), x + 3 * density * dir, bottom.toFloat(), p)
            p.color = oldColor
            p.style = oldStyle
        }
    }

    /** A horizontal rule drawn across a rendered `---` line. */
    private class RuleSpan(private val color: Int, private val density: Float) : LineBackgroundSpan, LivePreviewSpan {
        override fun drawBackground(
            canvas: Canvas, paint: Paint, left: Int, right: Int, top: Int, baseline: Int, bottom: Int,
            text: CharSequence, start: Int, end: Int, lineNumber: Int,
        ) {
            val old = paint.color
            paint.color = color
            val mid = (top + bottom) / 2f
            canvas.drawRect(left.toFloat(), mid - density / 2, right.toFloat(), mid + density / 2, paint)
            paint.color = old
        }
    }
}
