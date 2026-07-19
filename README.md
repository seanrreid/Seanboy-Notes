# Seanboy Notes[^1]

A modern reimagining of [Tomboy Notes](https://github.com/tomboy-notes) —
local-first Markdown notes with `[[Wiki Links]]`, instant search, and optional
sync via your own R2 bucket. Built as a monorepo, with one native app per
platform.

## Platforms

| Directory | Platform | Status |
|---|---|---|
| [`mac/`](mac/) | macOS 14+ (Swift + SwiftUI) | ✅ v1 |
| [`android/`](android/) | Android (Kotlin + Jetpack Compose) | 🚧 v1 in progress — engine + UI, sideload APK ([PRD](docs/PRD-android-v1.md)) |

Each platform directory is self-contained with its own build system and README.
See [`mac/README.md`](mac/README.md) for the macOS app's build instructions,
keyboard shortcuts, and sync setup.

## Shared concepts

All platform builds share the same data model so notes sync cleanly between them:

- **Local-first storage**: every note is a plain Markdown file with a small
  frontmatter header. Apps work fully offline; sync is a layer on top.
- **Tomboy soul**: search-as-you-type, `[[Wiki Links]]` between notes (linking
  to a missing note creates it), backlinks, lightweight editing.
- **Sync**: on-demand file sync to a Cloudflare R2 bucket over the S3 API —
  human-readable object keys (`notes/<Title>.md`), ETag-conditional writes,
  tombstoned deletes, and copy-on-overwrite version history. No server
  processes, no accounts; each device holds a per-device access key. See
  [`docs/PRD-sync-v2.md`](docs/PRD-sync-v2.md) for the design and
  [`mac/README.md`](mac/README.md) for setup (including an optional Synology
  Cloud Sync mirror of the bucket).

## License

LGPL, in the spirit of the original Tomboy.

[^1]: I'm Sean, Hi! 👋 This is my vibe coded fork of *Tomboy*, hence "Seanboy."
    BUT "Seanboy" is also what my Grandma Aggie called me my whole life. So, this is
    my way of carrying that on in my own geeky way.
