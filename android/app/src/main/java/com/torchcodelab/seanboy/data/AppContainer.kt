package com.torchcodelab.seanboy.data

import android.content.Context
import com.torchcodelab.seanboy.core.NoteStore
import com.torchcodelab.seanboy.core.S3Client
import com.torchcodelab.seanboy.core.SyncEngine
import java.io.File

/**
 * Manual dependency wiring. Notes live local-first in the app-private files
 * directory; sync-state and tombstones sit alongside (never inside the notes
 * folder). A [SyncEngine] is built on demand only when credentials exist.
 */
class AppContainer(context: Context) {
    private val filesDir: File = context.filesDir

    val store: NoteStore = NoteStore(
        directory = File(filesDir, "Notes"),
        tombstoneFile = File(filesDir, "tombstones.json"),
    )

    val credentials: CredentialStore = CredentialStore(context)

    private val stateFile: File = File(filesDir, "syncstate.json")

    val isSyncConfigured: Boolean get() = credentials.load() != null

    /** A fresh sync engine bound to the current store + credentials, or null. */
    fun syncEngine(): SyncEngine? {
        val config = credentials.load() ?: return null
        return SyncEngine(store, S3Client(config), stateFile)
    }
}
