# Seanboy Files v3 — Your Folder, Human Filenames

**One-liner:** The notes directory becomes a user-chosen folder of
human-named Markdown files (`Journal/2026/July.md`), scanned recursively,
watched for external changes, and mirrored 1:1 into the R2 bucket — Seanboy
becomes a view over *your* files instead of an app-owned store.

## Problem

Today notes live as `<uuid>.md` inside Application Support: invisible,
unbrowsable, and hostile to external tools — the exact Joplin failure this
project exists to avoid. A folder of Obsidian-exported Markdown dropped into
the notes directory is ignored (no recursion, frontmatter required), and
external edits are unsafe (no watcher; in-memory state can clobber files).
Human-readable files are not a nice-to-have; they are the thesis.

## Core Features (ranked)

1. **Filename is the title; path is the location.** `<Title>.md` files in
   subfolders, scanned recursively (`.md` only, hidden directories skipped).
   Editing a title renames the file. Local tree and bucket keys are the same
   namespace: `notes/<relative/path>.md`.
2. **Frontmatter round-trip that respects Obsidian.** Notes carry a minimal
   managed header (`id`, `created`, `modified` — never `title`). All other
   frontmatter keys (`tags`, `aliases`, Obsidian's own fields) are preserved
   byte-faithfully through every load/save and through sync. Adoption of a
   foreign file injects `id` into the existing YAML block (or creates one)
   and touches nothing else.
3. **FSEvents watcher.** External edits update the app; external renames are
   matched by frontmatter `id`; external deletes tombstone; new files are
   adopted. Debounced diff by path + mtime + content hash. External changes
   trigger the same debounced sync as in-app edits. This is what makes the
   folder safely shared with vim/Obsidian/anything.
4. **Deletes use the macOS Trash.** No tombstone files in the user's folder,
   ever. Delete = move to Trash + per-device tombstone record in Application
   Support + `.tombstones/<id>.md` in the bucket (unchanged remote model).
5. **Folder picker + migration.** Settings → Notes Folder (NSOpenPanel);
   default for new installs `~/Documents/Seanboy Notes`. One-time migration
   renames existing `<uuid>.md` files to `<Title>.md` (collision-suffixed)
   in the chosen folder.
6. **Sidebar: search and tree.** Search-as-you-type stays primary and global
   (flat, ranked, the Tomboy soul). A collapsible folder tree view shows the
   real structure; empty search shows the tree, typing shows flat results.
7. **Wiki links across folders.** `[[Title]]` resolves by filename across the
   whole tree; ambiguity resolves to the most recently modified match;
   `[[folder/Title]]` is supported for precision. Creating via a dead link
   places the note at the tree root. Stretch: resolve Obsidian `aliases`.

## Non-Goals

- **Mobile.** Android comes later; it will use its own private folder and
  the same sync engine. Folder-picking is a desktop feature.
- **Folder management UI.** No create/move/delete-folder inside the app for
  v1 — Finder does that, the watcher notices. New notes land at the root.
- **Frontmatter editing UI.** Tags/aliases render as text; managing them is
  the editor's job (or Obsidian's).
- **Rewriting wiki links on rename.** Links are resolved at click time by
  name; a rename may orphan links (dead links create — classic Tomboy).

## Technical Considerations

- **NoteDocument v2**: parse the YAML frontmatter block leniently; retain
  unknown lines verbatim (raw-block preservation, not a YAML library);
  serialize as original-unknown-lines + managed keys. `title` field is
  dropped from the format (filename owns it); tolerate and preserve one if
  present, but never write ours.
- **Note identity**: `id` stays a UUID in frontmatter — it is what
  distinguishes a rename from delete+create, locally (watcher) and remotely
  (sync planner). `Note` gains `relativePath`; `title` derives from the
  filename.
- **NoteStore v2**: recursive enumeration; write-through by path; title
  edits rename files (case-insensitive filesystem caveat: same-name
  case-only renames need a two-step move). In-memory index by id and by
  path.
- **Watcher**: FSEvents on the folder root, ~1 s debounce, reconcile via
  scan-diff (not event interpretation — events are only a dirty signal).
  Guard against reacting to the app's own writes (compare content hash).
- **SyncPlanner v2.1**: key assignment becomes `notes/` + relativePath.
  Everything else (ETag conditional writes, rename-as-key-move, tombstones,
  `.versions/`, conflict displacement) already works on keys and stays.
  Existing flat bucket keys are already valid tree paths — no bucket
  migration needed. Sync state remains per-device in Application Support.
- **Config**: notes folder path joins `sync.json`-style local config (not
  synced). App is unsandboxed; a stored path suffices.
- **Order of work matters**: document format → store → watcher → picker/
  migration → planner → UI. Each lands with tests before the next starts.

## Milestones

1. **NoteDocument v2** — frontmatter preservation + adoption. Tests include
   real Obsidian-style frontmatter samples (tags, aliases, dates, no id)
   proving byte-faithful round-trip of unmanaged keys.
2. **Path-based NoteStore** — recursive scan, filename-as-title, rename on
   title edit, Trash deletes + tombstone records, id/path indexes. The
   store's tests all move to temp-dir folders with nested structure.
3. **FSEvents watcher** — external create/edit/rename/delete reconciliation,
   self-write suppression, sync triggering. Testable via temp dirs.
4. **Folder picker + migration** — settings UI, default folder, one-time
   uuid→title migration, welcome-note copy updates.
5. **Sync integration** — path-based keys in the planner, tombstone-record
   plumbing, full planner test suite updated, live round-trip against R2.
6. **Sidebar tree + search** — collapsible tree (empty search) / flat ranked
   results (typing), wiki-link resolution rules, Spotlight re-pointed at new
   paths.

## Open Questions

- Should `modified` in frontmatter be authoritative over fs mtime when they
  disagree (external editors won't update frontmatter)? Lean: mtime wins on
  read; app rewrites frontmatter on save.
- Case-insensitive title collisions in one folder (`ideas.md` vs `Ideas.md`
  arriving via sync from a case-sensitive source): suffix on materialize.
- Does the tree view show note counts / empty folders? Lean: hide empty
  folders (they can't sync anyway — the bucket has no folder objects).
