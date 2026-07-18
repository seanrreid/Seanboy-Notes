# Seanboy

A modern macOS port of the old [`tomboy.osx`](https://github.com/tomboy-notes)
project — the long-dead MonoMac/Cocoa# port of [Tomboy Notes](https://github.com/tomboy-notes).
Seanboy rebuilds that idea from scratch in Swift + SwiftUI, with local-first
Markdown storage and optional Supabase sync between your Macs.

Where the original `tomboy.osx` wrapped the C#/Mono Tomboy engine in a native
shell, Seanboy is a clean-room reimplementation: no Mono runtime, no XML note
format — just a native app, plain Markdown files, and the same Tomboy soul.

- **Local-first**: every note is a plain Markdown file (with a small frontmatter
  header) in `~/Library/Application Support/Seanboy/Notes`. The app works fully
  offline; sync is a layer on top.
- **Tomboy soul**: instant search-as-you-type, `[[Wiki Links]]` between notes
  (clicking a link to a missing note creates it), backlinks, lightweight editor.
- **Modern extras**: dark mode, Spotlight indexing, global quick-capture hotkey
  (⌃⌥⌘N), live Markdown styling.
- **Sync**: Supabase Postgres with last-writer-wins conflict resolution and
  email-OTP sign-in, so your Mac Mini and MacBook share one account.

Requires macOS 14+.

## Build & run

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

1. Create a free project at [supabase.com](https://supabase.com) (Neon-style
   hosted Postgres with auth built in).
2. In the project dashboard, open **SQL Editor**, paste the contents of
   [`supabase/schema.sql`](supabase/schema.sql), and run it. This creates the
   `notes` table with row-level security so only your account can read your notes.
3. In **Project Settings → API**, copy the **Project URL** and the **anon public
   key**.
4. In Seanboy, open **Settings → Sync** (⌘,), paste both values, and click
   *Save Credentials*. They are stored in
   `~/Library/Application Support/Seanboy/supabase.json` — never in the repo.
5. Enter your email and click *Send Login Code*; type the 6-digit code from the
   email. Syncing starts immediately and repeats every 5 minutes (or on ⇧⌘S).
6. Repeat steps 4–5 on your other Mac with the same email.

Conflict handling is last-writer-wins per note, compared by modification time.
Deletes are tombstoned locally so they propagate to your other machines.

## Layout

- `Sources/SeanboyCore` — UI-free engine: `Note`, Markdown+frontmatter storage
  (`NoteStore`/`NoteDocument`), `WikiLinkParser`, `SearchService`, and the pure
  `SyncMerge` planner.
- `Sources/Seanboy` — the SwiftUI app: sidebar/editor UI, live Markdown
  styling (`MarkdownEditor`), Spotlight indexer, Carbon global hotkey, quick
  capture panel, and the Supabase `SyncService`.
- `Tests/SeanboyCoreTests` — unit tests for storage round-trips, link parsing,
  backlinks, search ranking, and sync merge planning.
- `supabase/schema.sql` — one-shot database schema + RLS policies.

## License

LGPL, in the spirit of the original Tomboy.
