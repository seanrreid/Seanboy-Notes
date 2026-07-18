# Seanboy Sync v2 — R2 Object Storage

**One-liner:** Replace Supabase database sync with on-demand file sync to a
Cloudflare R2 bucket, so Seanboy's plain-Markdown philosophy extends all the
way through the sync layer — files on disk, files in the cloud, files on the
NAS mirror.

## Problem & Audience

Seanboy is a single-user, local-first Markdown notes app for someone who finds
Notion/Obsidian too heavy, Apple Notes too locked-in, and Joplin too opaque
(database-ID filenames). The current Supabase sync contradicts the product's
own philosophy: files on disk become rows in someone else's Postgres. It also
carries real operational risk (free-tier projects pause after inactivity),
requires an auth flow (email OTP) that a single-user system doesn't need, and
resolves conflicts by comparing wall-clock mtimes across machines — silently
losing edits when a clock is skewed.

The user runs two Macs and two Android devices, owns a Synology NAS, and
explicitly wants **on-demand** sync — no background daemons, no battery cost.

## Core Features (ranked)

1. **S3-protocol sync client** — Push/pull Markdown files to an R2 bucket over
   the S3 API. Object keys mirror filenames (`Notes/Grocery List.md`) so the
   bucket is human-browsable and outlives the app.
2. **ETag-conditional writes** — `If-Match` on every upload replaces
   mtime-based last-writer-wins for conflict *detection*. Clock skew can no
   longer eat an edit. On a detected conflict, the existing `SyncMerge`
   planner decides the outcome.
3. **On-demand sync triggers** — Sync on app open, after save (debounced), and
   on ⇧⌘S. No timers required to be running when the app is closed; the 5-minute
   background interval while the app is open is optional and off by default on
   battery-powered devices (future Android).
4. **Copy-on-overwrite versioning** — Before overwriting a remote object, copy
   it to `.versions/<name>/<ISO-timestamp>.md`, capped at N versions per note
   (default 10). Restore is "download an old version"; no UI required for v1
   beyond maybe a menu item.
5. **Per-device credential config** — Bucket endpoint + access key stored in
   local config (same pattern as today's `supabase.json`). No sign-in flow, no
   OTP, no accounts.
6. **Synology mirror (zero client code)** — Documented setup: Synology Cloud
   Sync pulls the R2 bucket continuously on wall power, giving an on-prem
   plain-file mirror and second backup. This is configuration, not code — but
   it's part of the product story and belongs in the README.

## Non-Goals

- **Multi-user / sharing.** Single human, multiple devices. Ever adding
  sharing would reopen the auth question; not now.
- **Real-time sync.** On-demand is the feature, not the compromise. No
  websockets, no push, no file watchers on the phone.
- **End-to-end encryption (v1).** The bucket is private and single-user;
  client-side encryption is a clean later addition because the sync unit is a
  whole file.
- **Server-side anything.** No Workers, no API, no database. If a feature
  needs a server process, it's out of scope or wrongly designed.
- **Android app (v1).** Kotlin app in `android/` is the explicit fast-follow
  once the Swift version is solid. The monorepo layout and the
  bucket-of-plain-files design exist to make that build straightforward.

## Technical Considerations

- **Storage:** Cloudflare R2. Free tier is ample for text; zero egress fees;
  S3-compatible so the client code ports to any S3 host (including MinIO on
  the Synology itself, if third-party storage ever itches).
- **Client:** Swift. Prefer signing S3 requests directly (SigV4) over pulling
  in the full AWS SDK — the needed surface is tiny: LIST, GET, PUT
  (+`If-Match`/`If-None-Match`), DELETE, COPY.
- **Sync algorithm:** Keep a local sync-state file mapping note → last-seen
  ETag. Three-way comparison (local mtime/hash vs. saved state vs. remote
  ETag) feeds the existing `SyncMerge` planner; tombstones carry over from the
  current design.
- **Identity:** Frontmatter ID remains note identity; filename is display. A
  rename is COPY + DELETE remotely, matched by ID, not treated as
  delete + create.
- **Attachments:** Not in v1 (notes are text-only today), but the
  bucket-of-files design means images later are just more objects — this was
  a deciding factor against database sync.
- **Retired:** `SyncService` (Supabase client), `SupabaseConfig`,
  `SyncSettingsView`'s OTP flow, and `supabase/schema.sql`. Delete, don't
  deprecate.

## Milestones

1. **S3 client + manual round-trip** — Minimal SigV4 client; push and pull
   the whole notes folder to R2 from a debug menu item. Prove keys, TLS, and
   ETags work end-to-end.
2. **Merge integration** — Wire the sync-state file and ETag comparison into
   `SyncMerge`; handle create/edit/delete/rename in both directions; port the
   tombstone logic. This is the correctness milestone — grow the existing
   sync-merge test suite to cover ETag conflicts and clock skew.
3. **Versioning + triggers** — Copy-on-overwrite versions with cap; sync on
   open/save/⇧⌘S; settings UI reduced to endpoint + keys.
4. **Retire Supabase & document** — Delete the old sync stack, update
   `mac/README.md` with R2 setup and the Synology Cloud Sync mirror guide.

## Open Questions

- **One bucket or one prefix per device-set?** Lean: one bucket, notes at the
  root prefix — simplest, and the Synology mirror maps 1:1.
- **Version pruning location:** client prunes on write (simple) vs. R2
  lifecycle rules on the `.versions/` prefix (zero client code). Lean:
  lifecycle rule if R2's rules can target a prefix; client-side otherwise.
- **Conflict UX:** when `SyncMerge` picks a winner, does the loser land in
  `.versions/` silently, or does the app surface a "conflicted copy" note?
  Lean: silent + version history for v1; revisit after real-world use.
- **Credential distribution:** typing an access key on 4 devices is fine
  once, but decide whether the Android app should support a QR-code handoff
  from the Mac later.
