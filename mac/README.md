# Seanboy for macOS

> This is the macOS build of [Seanboy Notes](../README.md); other platform
> builds live in sibling directories of the monorepo.

A modern macOS port of the old [`tomboy.osx`](https://github.com/tomboy-notes)
project — the long-dead MonoMac/Cocoa# port of [Tomboy Notes](https://github.com/tomboy-notes).
Seanboy rebuilds that idea from scratch in Swift + SwiftUI, with local-first
Markdown storage and optional sync between your machines via an R2 bucket.

Where the original `tomboy.osx` wrapped the C#/Mono Tomboy engine in a native
shell, Seanboy is a clean-room reimplementation: no Mono runtime, no XML note
format — just a native app, plain Markdown files, and the same Tomboy soul.

- **Your folder, your files**: notes are plain Markdown files with human
  filenames (`Journal/2026/July.md`) in a folder you choose (default
  `~/Documents/Seanboy Notes`), subfolders included. Point Seanboy at an
  existing folder — Obsidian exports, anything — and it adopts the files in
  place, preserving their frontmatter. Edit with any app; an FSEvents watcher
  picks up external changes, renames, and deletions live. Deleting a note
  moves it to the macOS Trash. The app works fully offline; sync is a layer
  on top.
- **Tomboy soul**: instant search-as-you-type across the whole tree (clear
  the search to browse folders), `[[Wiki Links]]` between notes (clicking a
  link to a missing note creates it; `[[folder/Title]]` pins a location),
  backlinks, lightweight editor.
- **Modern extras**: dark mode, Spotlight indexing, global quick-capture hotkey
  (⌃⌥⌘N), live Markdown styling.
- **Sync**: on-demand file sync to a Cloudflare R2 bucket (any S3-compatible
  host works) — plain Markdown objects with human-readable names, conditional
  writes instead of clock comparison, and copy-on-overwrite version history.
  No accounts, no server processes, no background daemons.

Requires macOS 14+.

## Build & run

All commands run from this directory (`mac/`):

```sh
swift test                # unit tests (storage, links, search, sync merge)
scripts/make-app.sh       # → dist/Seanboy.app (ad-hoc signed)
open "dist/Seanboy.app"
```

For development: `swift run Seanboy`.

## Keyboard shortcuts

| Shortcut | Action |
|---|---|
| ⌘N | New note |
| ⌘B / ⌘I | Bold / italic |
| ⇧⌘H | ==Highlight== |
| ⇧⌘K | Insert `[[wiki link]]` |
| ⇧⌘S | Sync now |
| ⌃⌥⌘N | Quick capture (system-wide) |

## Setting up sync (one-time, ~5 minutes)

1. In the [Cloudflare dashboard](https://dash.cloudflare.com), open **R2** and
   create a bucket (e.g. `seanboy-notes`). The free tier is far more than
   enough for a lifetime of text.
2. Under **R2 → Manage API Tokens**, create a token scoped to that bucket
   with **Object Read & Write**. Note the **Access Key ID**, **Secret Access
   Key**, and the account endpoint
   (`https://<account-id>.r2.cloudflarestorage.com`).
3. In Seanboy, open **Settings → Sync** (⌘,), paste endpoint, bucket, and
   both keys, then click *Save & Test*. They are stored in
   `~/Library/Application Support/Seanboy/sync.json` — never in the repo.
4. Repeat step 3 on your other machines with the same credentials.

Sync is strictly on-demand: at launch, a few seconds after you stop editing,
and on ⇧⌘S. Nothing runs while the app is closed, and nothing polls — which
also makes future mobile builds battery-friendly by construction.

Any S3-compatible host works (MinIO on a NAS, Backblaze B2, AWS): set the
endpoint accordingly and add a `"region"` field to `sync.json` if the
provider needs one (R2 uses `auto`, the default).

### How sync works

The bucket mirrors your notes folder 1:1: `Journal/2026/July.md` on disk is
`notes/Journal/2026/July.md` in the bucket (human-readable — the bucket makes
sense without the app), deletions are tombstones under `.tombstones/`, and
history lives under `.versions/`. Each device
keeps a small `syncstate.json` recording the ETag it last saw per note, which
turns sync into a true three-way merge: local edits and remote edits are
detected independently, uploads are ETag-conditional (`If-Match`), and
timestamps only break ties when both sides changed — a wrong clock can no
longer eat an edit. Before any overwrite or delete, the old object is copied
to `.versions/<name>/<timestamp>.md` (10 kept per note), so even a lost
conflict is never lost data.

### Synology mirror (optional but recommended)

If you have a Synology NAS, install **Cloud Sync**, add an **S3 Storage**
connection with your R2 endpoint/keys/bucket, and set it to download-only.
The NAS then keeps a continuous on-prem plain-file mirror of the bucket —
a second backup on hardware you own, on wall power, with zero involvement
from your Macs or phone.

## Layout

- `Sources/SeanboyCore` — UI-free engine: `Note`, Obsidian-preserving
  frontmatter storage (`NoteStore`/`NoteDocument`), the FSEvents
  `FolderWatcher`, `TombstoneStore`, `WikiLinkParser`, `SearchService`, the
  pure three-way `SyncPlanner` + `SyncState`, and a minimal `S3Client` with
  its own SigV4 signer (no AWS SDK).
- `Sources/Seanboy` — the SwiftUI app: sidebar/editor UI, live Markdown
  styling (`MarkdownEditor`), Spotlight indexer, Carbon global hotkey, quick
  capture panel, and the `SyncService` that executes sync plans against R2.
- `Tests/SeanboyCoreTests` — unit tests for storage round-trips, link parsing,
  backlinks, search ranking, SigV4 signing (against the documented AWS test
  vectors), and sync planning (conflicts, renames, tombstones, clock skew).

## License

LGPL, in the spirit of the original Tomboy.

The app icon is the original Tomboy icon, from
[tomboy-notes/tomboy](https://github.com/tomboy-notes/tomboy)
(`data/icons/`), used under the LGPL
(`Resources/AppIcon.icns` is assembled from the upstream PNGs).
