# Seanboy for Android v1 — Native Kotlin, Local-First, Sideloaded

**One-liner:** A native Kotlin + Jetpack Compose app in `android/` that reaches
full feature parity with the Mac — local-first Markdown files, instant search,
`[[Wiki Links]]` and backlinks, and on-demand R2 sync — packaged as a
debug-signed APK you install directly on your own devices.

## Problem & Audience

Seanboy is a single-user, local-first Markdown notes app. The user runs two
Macs and **two Android devices** and owns a Synology NAS (see
[`PRD-sync-v2.md`](PRD-sync-v2.md)). Today the phone is a second-class citizen:
notes sync to an R2 bucket that the Macs read and write, but there is no native
way to read, search, or edit those notes on Android. The whole point of the
plain-files-in-a-bucket design — chosen over database sync specifically so a
mobile build would be straightforward — is unrealized until an Android app
exists.

This is not a new product; it is a **second native client over the same data
model**. The bucket format, the frontmatter `id` identity, the three-way merge,
tombstones, and `.versions/` history are all fixed by the Mac app and the sync
design. Android's job is to honor them exactly so notes round-trip cleanly
between every device.

The monorepo already anticipates this: `PRD-sync-v2.md` names "Kotlin app in
`android/`" as the explicit fast-follow, and `PRD-files-v3.md` notes that
"Android comes later; it will use its own private folder and the same sync
engine."

## Decisions locked in

- **Native Kotlin + Jetpack Compose.** Matches the "one native app per platform"
  thesis and yields the smallest, most idiomatic APK. The Swift `SeanboyCore`
  engine is **reimplemented in Kotlin**, not shared — there is no code reuse
  path from Swift; this is a clean-room port validated against the same
  behavior and, where they exist, the same test vectors.
- **Local-first cache in app-private storage.** A full local mirror of the
  (text-only, tiny) Markdown corpus lives in the app's private files directory.
  On-demand sync is a layer on top, exactly as on the Mac. This is what makes
  offline reads, instant search, and backlinks possible — all three require the
  whole corpus on device, and R2 offers no server-side search.
- **Cloud attachments are a later, staged concern.** v1 is text-only (parity
  with the Mac, per `PRD-sync-v2.md`). When images/attachments arrive, *those*
  binaries can be fetched lazily from R2 rather than mirrored — the only place
  cloud-first thinking earns its keep, since text does not pressure phone
  storage.
- **Full feature parity for v1.** Read/edit, search, wiki links, backlinks, R2
  sync with three-way merge, and version history.
- **Debug-signed APK, sideloaded.** Personal devices, direct install
  (`adb install` or download). Release signing, F-Droid, and OTA updates are
  out of scope for now.

## Core Features (ranked)

1. **Local-first Markdown store (Kotlin port of `NoteStore`/`NoteDocument`).**
   Notes are plain `.md` files in an app-private folder, mirroring the bucket
   1:1 (`notes/<relative/path>.md`). Frontmatter carries the minimal managed
   header (`id`, `created`, `modified` — never `title`); all other keys (tags,
   aliases, Obsidian fields) round-trip byte-faithfully. Filename is the title;
   relative path is the location. Editing a title renames the file.
2. **On-demand R2 sync (Kotlin port of the SigV4 `S3Client` + `SyncPlanner`).**
   The same three-way merge: local hash/mtime vs. saved per-note ETag vs.
   remote ETag, ETag-conditional (`If-Match`) uploads, rename-as-key-move
   matched by frontmatter `id`, tombstones under `.tombstones/`, and
   copy-on-overwrite versions under `.versions/`. Sync state is per-device in
   app-private storage. Triggers: on app open, after edits (debounced), and via
   an explicit "Sync now" action.
3. **Instant search-as-you-type.** Flat, ranked, across the whole tree — the
   Tomboy soul. Clearing the search browses the folder tree.
4. **`[[Wiki Links]]` + backlinks.** `[[Title]]` resolves by filename across the
   tree; ambiguity resolves to the most recently modified match;
   `[[folder/Title]]` pins a location. Tapping a link to a missing note creates
   it at the tree root. Backlinks pane per note.
5. **Compose editor with live Markdown styling.** Lightweight editing with the
   same affordances that make sense on a touch device: bold/italic, highlight,
   insert-wiki-link, and a heading/format bar. Read and edit modes.
6. **Sidebar/tree navigation adapted for mobile.** Collapsible folder tree when
   search is empty; flat ranked results when typing. Navigation drawer or a
   list→detail flow rather than the Mac's split view.
7. **Per-device credential config.** Endpoint, bucket, and access keys entered
   once and stored in Android's encrypted credential storage (see Technical
   Considerations). No accounts, no sign-in, no OTP — same as the Mac.

## Non-Goals

- **Release signing / Play Store / F-Droid / OTA updates.** Debug APK only for
  v1. Revisit distribution once the app is proven on-device.
- **Storage Access Framework / user-chosen vault folder.** The Mac's "point at
  your Obsidian folder" story is a desktop feature (`PRD-files-v3.md` non-goal).
  Android v1 owns a private folder; the bucket is how notes get in and out.
- **Attachments/images.** Text-only in v1, matching the Mac and the sync design.
- **Background/real-time sync.** On-demand only — no daemons, no push, no file
  watchers, no periodic wake-ups. Battery-friendly by construction, as the sync
  design intends for mobile.
- **Folder management UI.** No create/move/delete-folder inside the app; new
  notes land at the root (parity with `PRD-files-v3.md`).
- **iOS.** Native Kotlin is Android-only by choice; an iOS build, if ever, is a
  separate app, not this codebase.
- **Widgets, quick-capture tile, share-target.** Desirable later; not v1.

## Technical Considerations

- **Language/UI:** Kotlin, Jetpack Compose, single-Activity architecture. Target
  a recent `minSdk` that still covers the user's two devices (decide during
  Milestone 0); `compileSdk`/`targetSdk` at current stable.
- **Engine port:** `SeanboyCore` becomes a pure-Kotlin module with no Android
  dependencies where possible, so it is unit-testable on the JVM:
  - `NoteDocument` — lenient YAML-frontmatter parse with verbatim
    raw-block preservation of unknown lines (not a YAML library), managed keys
    serialized last. Drop `title`; tolerate but never write one.
  - `NoteStore` — recursive scan of the private folder, filename-as-title,
    rename-on-title-edit (mind case-insensitive collisions), id + path indexes.
  - `WikiLinkParser`, `SearchService` — ported with their ranking rules.
  - `SyncPlanner` + `SyncState` — pure three-way planner; the correctness core.
- **S3/SigV4 client:** Reimplement the minimal signer in Kotlin (LIST, GET, PUT
  with `If-Match`/`If-None-Match`, DELETE, COPY) using OkHttp + `javax.crypto`
  HMAC-SHA256. **Validate against the documented AWS SigV4 test vectors**, the
  same vectors the Swift `SeanboyCoreTests` use — this is the highest-risk port
  and must be test-first. No AWS SDK.
- **Local files:** App-private storage (`context.filesDir`), a plain directory
  tree of `.md` files. No SAF, no `MediaStore`, no runtime storage permissions.
- **Credentials:** Endpoint + keys stored via Jetpack Security
  (`EncryptedSharedPreferences`) or DataStore backed by the Android Keystore —
  never in plaintext, never in the repo. Mirrors the Mac's `sync.json` role.
- **No watcher.** Unlike the Mac's FSEvents watcher, Android owns its private
  folder exclusively — no external editors touch it — so there is no
  file-watching requirement. In-app edits are the only local mutation source.
- **Concurrency:** Coroutines + `Flow`; sync runs off the main thread and is
  cancelable. Search indexing incremental over the in-memory note index.
- **Sync triggers on mobile:** app open (`onResume`), debounced-after-edit, and
  an explicit toolbar "Sync now." No `WorkManager` background job in v1 (keeps
  it battery-free and avoids Doze complications).
- **Bucket compatibility is non-negotiable:** the app must produce and consume
  the *exact* key layout, tombstone, and `.versions/` conventions the Mac uses,
  so a note created on the phone appears correctly on the Macs and the Synology
  mirror, and vice versa. Round-trip tests against a real (or MinIO) bucket
  gate the merge milestone.
- **Build/distribution:** Gradle in `android/`, `assembleDebug` →
  `app-debug.apk`, install via `adb install` or direct download. Document the
  "Install unknown apps" toggle step in `android/README.md`.

## Milestones

Order mirrors the Mac's discipline — each lands with tests before the next
starts, engine before UI, correctness before polish.

0. **Project skeleton** — `android/` Gradle project, Compose single-Activity
   shell, `minSdk` decided against the two target devices, `assembleDebug`
   produces an installable APK ("hello notes" screen). Establishes the CI/build
   loop early.
1. **NoteDocument (Kotlin)** — frontmatter round-trip with byte-faithful
   preservation of unmanaged keys; adoption injects `id` and touches nothing
   else. Ported from the Swift tests, including real Obsidian-style samples.
2. **Local NoteStore** — recursive scan of the private folder, filename-as-title,
   rename-on-title-edit, id/path indexes, create/delete. JVM unit tests over
   temp dirs with nested structure.
3. **SigV4 S3 client** — the signer validated against AWS test vectors; LIST/
   GET/PUT/DELETE/COPY with conditional headers; a manual round-trip that
   pushes and pulls the whole folder to R2 from a debug screen.
4. **Sync merge integration** — wire `SyncState` + ETag comparison into the
   `SyncPlanner`; create/edit/delete/rename both directions; tombstones and
   `.versions/`. Grow the ported planner test suite to cover ETag conflicts,
   renames, and clock skew. **Live cross-device round-trip with a Mac** gates
   this milestone.
5. **Search, wiki links, backlinks** — instant ranked search, `[[link]]`
   resolution rules, backlinks pane; the read/browse feature core.
6. **Compose editor + navigation** — live Markdown styling, edit/read modes,
   format bar, tree/search navigation adapted for touch; debounced-after-edit
   sync.
7. **Settings + credentials + docs** — encrypted credential storage, "Sync now"
   and settings UI, and `android/README.md` (build, sideload steps, sync setup)
   plus a row added to the root `README.md` Platforms table.

## Open Questions

- **`minSdk` floor:** what Android versions do the two target devices run? This
  sets the API surface for Compose, Keystore, and coroutines. Lean: the lowest
  version the two devices share.
- **Editor component:** hand-rolled Compose `BasicTextField` with live styling
  (full control, matches the Mac's custom `MarkdownEditor`) vs. an existing
  Compose Markdown editor library (faster, less control). Lean: hand-rolled for
  parity, given styling is core to the feel.
- **Credential handoff:** typing an access key on two more devices is fine once,
  but `PRD-sync-v2.md` floated a **QR-code handoff from the Mac**. Worth it for
  v1, or type-it-in now and add QR later? Lean: type-it-in for v1.
- **Conflict UX on mobile:** the Mac leans "silent loser → `.versions/`, revisit
  after real use." Does the phone need any surfaced indicator when a merge picks
  a winner, or inherit the silent-plus-history behavior? Lean: inherit it.
- **Sync-on-open cost:** a LIST on every `onResume` is cheap but not free on a
  metered connection. Add a "Wi-Fi only auto-sync" preference, or always sync on
  open and rely on manual for the rest? Lean: sync on open, add the preference if
  it annoys in practice.
- **Case-insensitive collisions:** Android's filesystem is case-sensitive but
  notes may arrive from case-sensitive *and* insensitive sources; reuse the
  Mac's suffix-on-materialize rule (`PRD-files-v3.md`). Confirm the rule ports
  verbatim.
