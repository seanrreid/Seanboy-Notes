# Seanboy for Android

> This is the Android build of [Seanboy Notes](../README.md); other platform
> builds live in sibling directories of the monorepo. See
> [`docs/PRD-android-v1.md`](../docs/PRD-android-v1.md) for the full design.

A native **Kotlin + Jetpack Compose** port of Seanboy. Local-first Markdown
notes with `[[Wiki Links]]`, instant search, and on-demand sync to your own R2
bucket — the same data model and bucket format as the macOS app, so notes
round-trip cleanly between every device.

**Status: engine complete + functional UI.** The `:core` engine — note
document format, local `NoteStore`, tombstones, `[[wiki links]]`, search, SigV4
signing, the three-way `SyncPlanner`, the S3 client, and the `SyncEngine`
orchestrator — is fully ported from the Mac and covered by **67 passing JVM
tests** (`./gradlew :core:test`). The app module wires it into a Compose UI
(searchable notes list, editor with backlinks and wiki-link navigation,
encrypted sync settings) and builds to an installable debug APK
(`./gradlew :app:assembleDebug`). See [`docs/PRD-android-v1.md`](../docs/PRD-android-v1.md)
for the full milestone plan.

## Requirements

- **JDK 17+** (Android Gradle Plugin 8.5 requires it). The `java` on your `PATH`
  may be older — point Gradle at a 17+ JDK via `org.gradle.java.home` in
  `gradle.properties`, `JAVA_HOME`, or Android Studio's bundled JBR.
- **Android SDK** with `compileSdk` **34** (API 34) and build-tools installed.
  Create `local.properties` in this directory pointing at your SDK:
  ```properties
  sdk.dir=/Users/<you>/Library/Android/sdk
  ```
  (`local.properties` is git-ignored — it is machine-specific.)
- A device (or emulator) running **Android 8.0+** (`minSdk 26`, a placeholder —
  see the PRD open question on the floor for the two target devices).

## Build & install (sideload)

All commands run from this directory (`android/`):

```sh
./gradlew assembleDebug          # → app/build/outputs/apk/debug/app-debug.apk
./gradlew installDebug           # build + install to the connected device
```

Or install a built APK directly:

```sh
adb install -r app/build/outputs/apk/debug/app-debug.apk
```

To sideload without `adb`, copy `app-debug.apk` to the phone and open it; you'll
need to allow **Install unknown apps** for whichever app opens it (Files,
browser, etc.) in **Settings → Apps → Special access**.

> Debug builds use the `.debug` application-id suffix
> (`com.torchcodelab.seanboy.debug`), so they can coexist with a future release
> build. There is **no release signing in v1** — sideload uses the debug APK
> (see the PRD Non-Goals).

Run the unit tests (once there are any beyond the skeleton):

```sh
./gradlew test
```

## Layout

- `app/` — the Compose application module: `MainActivity` (single-Activity
  host), the Material3 theme, `NotesViewModel`, the `SeanboyApp` UI (list +
  search, editor with backlinks, sync settings), and `CredentialStore`
  (EncryptedSharedPreferences).
- `core/` — a pure-Kotlin, Android-free engine module mirroring
  `mac/Sources/SeanboyCore`: `NoteDocument`/`Note`, `NoteStore`,
  `TombstoneStore`, `WikiLinkParser`, `SearchService`, `SigV4`, `S3Client`,
  the three-way `SyncPlanner` + `SyncState`, and the `SyncEngine` orchestrator.
  JVM-unit-tested (67 tests, incl. AWS SigV4 vectors and MockWebServer sync
  round-trips).
- `gradle/libs.versions.toml` — the version catalog (AGP, Kotlin, Compose BOM,
  OkHttp, kotlinx.serialization).

## What's not done yet

The Mac's richer touches are follow-ups: a collapsible folder **tree** in the
sidebar (the list is flat + search for now), live Markdown **styling** in the
editor (plain text field today), inline tap-to-follow wiki links (shown as a
Links/Backlinks button row instead), debounced-after-edit sync tuning, and a
QR credential handoff. None change the data model or bucket format.

## License

LGPL, in the spirit of the original Tomboy.
