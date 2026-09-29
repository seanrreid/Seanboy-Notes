package com.torchcodelab.seanboy.core

import org.junit.Assert.assertEquals
import org.junit.Test

class NotePreviewTest {
    @Test
    fun dropsFrontmatter() {
        val body = "---\ntags:\n  - Keep/Archived\n---\nJen and I are collectors."
        assertEquals("Jen and I are collectors.", NotePreview.of(body))
    }

    @Test
    fun dropsImageEmbedsOfBothKinds() {
        assertEquals("Kitchen tile", NotePreview.of("![[1859.a5cd.jpg]]\n![alt](img/x.png)\nKitchen tile"))
    }

    @Test
    fun keepsLinkTextNotSyntax() {
        assertEquals("See Plans and the site", NotePreview.of("See [[Plans]] and [the site](https://x.com)"))
        assertEquals("Ask Aggie", NotePreview.of("Ask [[Grandma|Aggie]]"))
    }

    @Test
    fun stripsLineMarkersAndEmphasis() {
        val body = "# Groceries\n- [ ] **milk**\n- [x] _eggs_\n1. `bread`\n> ~~cake~~"
        assertEquals("Groceries milk eggs bread cake", NotePreview.of(body))
    }

    @Test
    fun leavesSnakeCaseAndMathAlone() {
        assertEquals("rename my_file_name to 2 * 3", NotePreview.of("rename my_file_name to 2 * 3"))
    }

    @Test
    fun truncatesWithEllipsis() {
        assertEquals("abc…", NotePreview.of("abcdef", maxLength = 3))
        assertEquals("", NotePreview.of("---\ntitle: x\n---\n"))
    }
}
