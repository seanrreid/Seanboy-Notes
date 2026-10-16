package com.torchcodelab.seanboy.ui.editor

import android.graphics.drawable.GradientDrawable
import android.os.Build
import android.util.TypedValue
import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.toArgb
import androidx.compose.ui.viewinterop.AndroidView
import com.torchcodelab.seanboy.core.AutoLinks

/**
 * The Live Preview body editor for one note. Key it by note id at the call
 * site so each note gets a fresh view. [initialMarkdown] is read once;
 * after that the view owns the text and reports edits through [onChange].
 */
@Composable
fun LivePreviewEditor(
    initialMarkdown: String,
    onChange: (String) -> Unit,
    onOpenWikiLink: (String) -> Unit,
    onReady: (LivePreviewEditText) -> Unit,
    autoLinks: AutoLinks?,
    modifier: Modifier = Modifier,
) {
    val scheme = MaterialTheme.colorScheme
    val colors = LivePreviewColors(
        accent = scheme.primary.toArgb(),
        secondary = scheme.onSurfaceVariant.toArgb(),
        faded = scheme.onSurfaceVariant.copy(alpha = 0.55f).toArgb(),
        codeText = scheme.tertiary.toArgb(),
        codeBackground = scheme.surfaceContainerHigh.toArgb(),
        highlight = Color(0xFFFFD60A).copy(alpha = 0.35f).toArgb(),
        rule = scheme.outlineVariant.toArgb(),
        autoLink = scheme.primary.copy(alpha = 0.7f).toArgb(),
    )
    val textColor = scheme.onSurface.toArgb()
    val hintColor = scheme.onSurfaceVariant.toArgb()
    val selectionColor = scheme.primary.copy(alpha = 0.3f).toArgb()
    val cursorColor = scheme.primary.toArgb()
    val textSizeSp = MaterialTheme.typography.bodyLarge.fontSize.value

    AndroidView(
        modifier = modifier,
        factory = { context ->
            LivePreviewEditText(context).apply {
                val density = resources.displayMetrics.density
                setPadding((16 * density).toInt(), (8 * density).toInt(), (16 * density).toInt(), (16 * density).toInt())
                hint = "Start writing…"
                this.colors = colors
                setMarkdown(initialMarkdown)
                onReady(this)
            }
        },
        update = { view ->
            view.onMarkdownChange = onChange
            view.onOpenWikiLink = onOpenWikiLink
            view.colors = colors
            view.autoLinks = autoLinks
            view.setTextColor(textColor)
            view.setHintTextColor(hintColor)
            view.highlightColor = selectionColor
            view.setTextSize(TypedValue.COMPLEX_UNIT_SP, textSizeSp)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                view.textCursorDrawable = GradientDrawable().apply {
                    setColor(cursorColor)
                    setSize((2 * view.resources.displayMetrics.density).toInt(), 0)
                }
            }
        },
    )
}
