package com.torchcodelab.seanboy.data

import android.content.Context
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKey
import com.torchcodelab.seanboy.core.S3Config

/**
 * Stores the R2/S3 bucket credentials in Android's encrypted storage (backed by
 * the Keystore) — never in plaintext, never in the repo. Mirrors the Mac's
 * `sync.json` role. The file is `credentials.xml`, excluded from cloud backup
 * (see res/xml/backup_rules.xml).
 */
class CredentialStore(context: Context) {
    private val prefs = EncryptedSharedPreferences.create(
        context,
        "credentials",
        MasterKey.Builder(context).setKeyScheme(MasterKey.KeyScheme.AES256_GCM).build(),
        EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV,
        EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM,
    )

    /** The stored config, or null if sync has not been set up. */
    fun load(): S3Config? {
        val endpoint = prefs.getString(KEY_ENDPOINT, null) ?: return null
        val bucket = prefs.getString(KEY_BUCKET, null) ?: return null
        val accessKey = prefs.getString(KEY_ACCESS, null) ?: return null
        val secret = prefs.getString(KEY_SECRET, null) ?: return null
        if (endpoint.isBlank() || bucket.isBlank() || accessKey.isBlank() || secret.isBlank()) return null
        return S3Config(
            endpoint = endpoint,
            bucket = bucket,
            region = prefs.getString(KEY_REGION, null)?.ifBlank { "auto" } ?: "auto",
            accessKeyID = accessKey,
            secretAccessKey = secret,
        )
    }

    fun save(config: S3Config) {
        prefs.edit()
            .putString(KEY_ENDPOINT, config.endpoint.trim())
            .putString(KEY_BUCKET, config.bucket.trim())
            .putString(KEY_REGION, config.region.trim())
            .putString(KEY_ACCESS, config.accessKeyID.trim())
            .putString(KEY_SECRET, config.secretAccessKey.trim())
            .apply()
    }

    fun clear() = prefs.edit().clear().apply()

    private companion object {
        const val KEY_ENDPOINT = "endpoint"
        const val KEY_BUCKET = "bucket"
        const val KEY_REGION = "region"
        const val KEY_ACCESS = "accessKeyID"
        const val KEY_SECRET = "secretAccessKey"
    }
}
