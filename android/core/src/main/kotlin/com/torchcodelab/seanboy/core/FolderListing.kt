package com.torchcodelab.seanboy.core

/**
 * One level of the notes folder tree, for drill-down browsing on a phone:
 * the subfolders directly inside [folder] and the notes filed there.
 * Same ordering as the Mac sidebar tree (`SidebarNode`): folders first,
 * then notes, each sorted case-insensitively by name.
 */
data class FolderListing(
    /** Folder path relative to the notes root; "" is the root. */
    val folder: String,
    val subfolders: List<Subfolder>,
    val notes: List<Note>,
) {
    data class Subfolder(
        val name: String,
        val path: String,
        /** Notes anywhere inside, including nested folders. */
        val noteCount: Int,
    )

    /** A breadcrumb segment: the root ("" path) is named [rootName]. */
    data class Crumb(val name: String, val path: String)

    companion object {
        private val byName = String.CASE_INSENSITIVE_ORDER

        fun of(notes: List<Note>, folder: String): FolderListing {
            val live = notes.filter { !it.isDeleted }
            val prefix = if (folder.isEmpty()) "" else "$folder/"
            val counts = sortedMapOf<String, Int>(byName)
            val here = mutableListOf<Note>()
            for (note in live) {
                val noteFolder = note.folder
                when {
                    noteFolder == folder -> here += note
                    noteFolder.startsWith(prefix) -> {
                        val child = noteFolder.removePrefix(prefix).substringBefore('/')
                        counts[child] = (counts[child] ?: 0) + 1
                    }
                }
            }
            return FolderListing(
                folder = folder,
                subfolders = counts.map { (name, count) -> Subfolder(name, prefix + name, count) },
                notes = here.sortedWith(compareBy(byName) { it.title }),
            )
        }

        /**
         * [folder] if it still contains notes, else its nearest ancestor that
         * does (or the root) — folders vanish when their last note is deleted
         * or synced away, since only notes exist on disk and in the bucket.
         */
        fun nearestExisting(notes: List<Note>, folder: String): String {
            var candidate = folder
            while (candidate.isNotEmpty()) {
                val prefix = "$candidate/"
                if (notes.any { !it.isDeleted && (it.folder == candidate || it.folder.startsWith(prefix)) }) {
                    return candidate
                }
                candidate = parent(candidate)
            }
            return ""
        }

        /**
         * Every folder, depth-first in sidebar order: each folder is followed
         * by its own subfolders before its next sibling. For the side drawer.
         */
        fun tree(notes: List<Note>): List<Subfolder> {
            val out = mutableListOf<Subfolder>()
            fun walk(folder: String) {
                for (sub in of(notes, folder).subfolders) {
                    out += sub
                    walk(sub.path)
                }
            }
            walk("")
            return out
        }

        /** 0 for top-level folders, 1 for "Journal/2026", and so on. */
        fun depth(folder: String): Int = folder.count { it == '/' }

        /** "Journal/2026" → "Journal"; top-level folders → "". */
        fun parent(folder: String): String = folder.substringBeforeLast('/', missingDelimiterValue = "")

        fun breadcrumbs(folder: String, rootName: String): List<Crumb> {
            val crumbs = mutableListOf(Crumb(rootName, ""))
            if (folder.isEmpty()) return crumbs
            var path = ""
            for (part in folder.split('/')) {
                path = if (path.isEmpty()) part else "$path/$part"
                crumbs += Crumb(part, path)
            }
            return crumbs
        }
    }
}
