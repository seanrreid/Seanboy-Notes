package com.torchcodelab.seanboy.core

/**
 * Simple in-memory full-text search: every whitespace-separated query term must
 * appear in the title or body (case-insensitive). Title hits and prefix matches
 * rank higher; ties fall back to recency.
 *
 * Faithful Kotlin port of `mac/Sources/SeanboyCore/SearchService.swift`.
 */
object SearchService {
    fun search(query: String, notes: List<Note>): List<Note> {
        val terms = query.lowercase().split(Regex("\\s+")).filter { it.isNotEmpty() }
        if (terms.isEmpty()) {
            return notes.sortedByDescending { it.modifiedAt }
        }

        return notes
            .mapNotNull { note -> score(note, terms)?.let { note to it } }
            .sortedWith(
                compareByDescending<Pair<Note, Int>> { it.second }
                    .thenByDescending { it.first.modifiedAt },
            )
            .map { it.first }
    }

    private fun score(note: Note, terms: List<String>): Int? {
        val title = note.title.lowercase()
        val body = note.body.lowercase()
        var total = 0
        for (term in terms) {
            when {
                title.startsWith(term) -> total += 100
                title.contains(term) -> total += 50
                body.contains(term) -> total += 10
                else -> return null // every term must match somewhere
            }
        }
        return total
    }
}
