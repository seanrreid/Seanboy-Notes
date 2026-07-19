# Seanboy for Android

> This is the Android build of [Seanboy Notes](../README.md); other platform
> builds live in sibling directories of the monorepo. See
> [`docs/PRD-android-v1.md`](../docs/PRD-android-v1.md) for the full design.

A native **Kotlin + Jetpack Compose** port of Seanboy. Local-first Markdown
notes with `[[Wiki Links]]`, instant search, and on-demand sync to your own R2
bucket — the same data model and bucket format as the macOS app, so notes
round-trip cleanly between every device.

**Status: Milestone 0 (project skeleton).** The app currently builds to an
installable debug APK showing a placeholder screen. The local store, sync
engine, search, and editor land in the milestones that follow (see the PRD).

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
  host), the Material3 theme, and (in later milestones) the UI for the sidebar
  tree, search, editor, backlinks, and settings.
- `:core` (Milestone 1) — a pure-Kotlin, Android-free engine module: the
  `NoteDocument`/`NoteStore` port, `WikiLinkParser`, `SearchService`, the SigV4
  `S3Client`, and the three-way `SyncPlanner` + `SyncState`. JVM-unit-testable,
  mirroring `mac/Sources/SeanboyCore`.
- `gradle/libs.versions.toml` — the version catalog (AGP, Kotlin, Compose BOM).

## License

LGPL, in the spirit of the original Tomboy.
