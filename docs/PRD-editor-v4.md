# Seanboy Editor v4 — Live Preview and an Inline Title

**One-liner:** The editor follows Obsidian's Live Preview. Markdown is styled
where you type it, and the syntax markers only appear on the line the cursor
is on. The title becomes an inline heading at the top of the note, bound to
the filename and saved reliably. The file on disk stays plain Markdown,
exactly as before.

## Problem

- **Titles get lost.** A new note keeps the filename "New Note" unless the
  user presses Enter (Mac, `onSubmit`) or the keyboard's Done key (Android)
  in the title field. Clicking into the body, going back, or quitting
  discards the typed title, and body saves then write the note under the old
  name. The title is a separate form field that behaves differently from the
  body.
- **The editor is too plain.** On Mac, regex coloring shows every `**`, `==`,
  and `#` all the time. On Android the body is an unstyled
  `OutlinedTextField`. Nothing looks like a formatted note, and lists do
  nothing on Enter or Tab. GNote and Obsidian both show that a note editor
  can feel rich while the file stays plain text.
- **Performance ceiling.** The Mac styler resets attributes on the whole note
  and re-runs every regex on every keystroke. That's fine for short notes,
  but it won't hold up once per-line marker hiding is added.

## Core Features (ranked)

1. **Inline title (Obsidian model).** A large heading-styled title sits above
   the body as part of the same scrolling page. It shows the filename and is
   never stored in the file text (the filename still owns the title; see
   `PRD-files-v3.md`). The title commits when either of these happens:
   - typing pauses for about 750 ms (debounced rename), or
   - focus leaves the title, the note switches, the window closes, or the app
     quits or goes to the background.

   Enter in the title moves the cursor to the start of the body. A new note
   opens with an empty title that shows an "Untitled" placeholder, and the
   title has focus. If the title is left empty when committing, the note
   keeps `Untitled.md` (made unique as `Untitled 2`, and so on). A name that
   clashes with an existing note shows an inline warning and doesn't rename
   (GNote's `NoteRenameWatcher` behavior), instead of silently adding a
   suffix.
2. **Live Preview rendering.** On every line except the one with the cursor,
   the syntax markers are hidden and the text is shown formatted. On the
   cursor line the markers show, faded. If there's a selection, every line it
   touches counts as the cursor line. Covered syntax:
   - `#`–`###` headings (the `#`s are hidden; the heading scale uses the
     accent color)
   - `**bold**`, `*italic*`, `~~strike~~`, `==highlight==`
   - `` `inline code` ``, plus fenced code blocks shown as a tinted
     monospaced block (the fences show only when the cursor is in the block)
   - `[[Wiki Link]]` and `[[Target|Alias]]` (the brackets are hidden and the
     alias shows)
   - `[label](url)` and bare `https://…` URLs, clickable
   - `> quote`, shown with a left bar
   - `---`, shown as a horizontal rule
3. **Lists that behave (GNote `NoteBuffer` model).**
   - `-`, `*`, and `+` bullets show as a `•`, drawn at display time only. The
     file keeps the dash.
   - Enter continues the list with the same marker and indent. Numbered
     lists increment.
   - Enter on an empty item ends the list.
   - Tab and Shift-Tab indent and outdent the item.
   - Backspace right after the marker removes the marker, not the text.
   - Home or ⌘← moves to the start of the text, after the marker.
4. **Checkboxes.** `- [ ]` and `- [x]` show as a checkbox you can click or
   tap, which toggles the character in the file. Checked items are shown
   struck through and faded.
5. **Auto-links to existing notes (stretch; GNote `NoteLinkWatcher`).** Text
   that exactly matches another note's title gets a subtle dotted underline,
   and ⌘-click (Mac) or tap (Android) opens that note. This is display only:
   no `[[ ]]` is written. It can be turned off in Settings.

## Non-Goals

- **A WYSIWYG document model.** The editor buffer *is* the Markdown text.
  Rendering is attributes, spans, and glyph substitution only. What's saved
  is exactly what was typed. There's no HTML, no AST round-trip, and nothing
  that could rewrite a user's file.
- **Reading mode or a separate preview pane.**
- **Tables, images, embeds (`![[…]]`), math, and footnotes.** These show as
  plain text for now. Images are the most likely follow-up.
- **A formatting toolbar.** Keyboard shortcuts stay (⌘B, ⌘I, ⇧⌘H, ⇧⌘K). An
  Android shortcut bar above the keyboard is an open question.
- **Syntax-highlighting code block contents.**

## Technical Considerations

- **A shared, platform-neutral span parser in the core.** A
  `MarkdownSpans.parse(text) -> [Span]` function returns each span's
  `kind`, its `contentRange`, and its `markerRanges` (the parts to hide or
  fade). It's line-oriented, with block state carried only for code fences.
  It lives in `SeanboyCore` (Swift) and `:core` (Kotlin), like `WikiLink`,
  and is ported line by line. **Both ports run the same fixture file** of
  Markdown input and expected spans in JSON, so Mac and Android render the
  same way.
- **Mac rendering (TextKit 1, current `NSTextView`).**
  - *Incremental restyle:* on each edit, re-parse and re-style only the
    edited paragraphs. A code fence that opens or closes restyles through
    the end of the block. When the selection changes, restyle only the old
    cursor line and the new one.
  - *Hiding markers:* use a custom `NSLayoutManager` delegate
    (`shouldGenerateGlyphs`) that turns marker glyphs into null/control
    glyphs, so they take up no width. Don't use tiny fonts or clear colors:
    those leave gaps and break caret movement.
  - *Bullets and checkboxes:* glyph substitution, with the checkbox drawn in
    `drawGlyphs` and clicks hit-tested in `mouseDown`.
  - *Hidden markers when moving the cursor:* adjust the selection in
    `textViewDidChangeSelection` so the arrow keys skip hidden ranges on the
    lines they pass through. The cursor line reveals its markers at once, so
    this only matters while moving between lines.
  - *Updating from outside:* `updateNSView` must stop replacing `string`
    wholesale. It should apply external changes (watcher, sync) as the
    smallest replacement range and keep selection, scroll position, and undo
    history.
  - *TextKit 2:* moving to it isn't required for v4. Revisit only if the
    null-glyph approach runs into problems.
- **Mac inline title.** An `NSTextField` pinned as a header view inside the
  editor's scroll view, so it scrolls with the note. It's styled at H1 size
  in the accent color, and Enter or ↓ from the title focuses the body.
  `NotesViewModel.updateTitle` gets a debounced wrapper. The app calls
  `flushPendingTitle()` from `applicationWillTerminate`, from note selection
  changes, and from `windowWillClose`, replacing the current `onDisappear`
  hook.
- **Android rendering.** Put an `EditText` in `AndroidView`, styled with
  spans, instead of using Compose `VisualTransformation`. Hiding characters
  with `OffsetMapping` breaks cursor movement and IME composition, and it has
  to re-transform on every selection change. Spans map directly onto the
  shared parser's output:
  - style spans for formatting
  - a zero-width `ReplacementSpan` for hidden markers
  - a `ReplacementSpan` that draws the bullet or checkbox
  - `ClickableSpan` for links

  This is the approach Markwon's editor uses, and it's proven. The list rules
  go in an `InputFilter`/`TextWatcher`, and the hardware Tab key is handled.
- **Android inline title.** An unbordered, headline-styled `BasicTextField`
  above the editor with the same debounced commit. The commit also flushes
  from the back handler, `ON_STOP`, and note switches.
- **Order of work matters:** span parser and fixtures → Mac incremental
  restyle (with no visible change) → marker hiding → lists → checkboxes →
  inline title → Android. The inline title is the most important fix for
  users. If rendering work slips it can ship first, since it doesn't depend
  on the parser.
- **Android sequencing:** Android work depends on the `android` branch
  landing on `main`. Android folder browsing (a drill-down folder list, the
  unbuilt item 6 of `PRD-android-v1.md`) is a separate PR on that branch.

## Milestones

1. **Inline title with reliable commit, Mac.** Fixes the "New Note" bug.
   Tests cover debounce and flush in the view model, clash warnings, and the
   "Untitled" fallback.
2. **`MarkdownSpans` parser + shared fixtures**, Swift only at first. Cover
   nesting, unclosed markers, code fences, escaped characters, and wiki-link
   aliases.
3. **Mac incremental styling.** Same look as today, with per-paragraph
   restyle and a non-destructive `updateNSView`. Measure on a 5,000-line
   note.
4. **Mac Live Preview.** Marker hiding with cursor-line reveal, headings,
   link rendering, quotes, rules, and code blocks.
5. **Mac lists and checkboxes.** Enter/Tab/Backspace/Home rules, bullet and
   checkbox glyphs, click to toggle.
6. **Android: inline title, then the Kotlin `MarkdownSpans` port** (running
   the same fixtures), then the span-based `EditText` with list rules and
   checkboxes.
7. **Stretch: auto-links to existing note titles** on both platforms.

## Open Questions

- **Revealing markers:** by line (Obsidian), or only the span under the
  cursor (Typora)? Lean: by line, since it's easier to predict and matches
  the reference.
- **YAML frontmatter:** hide it entirely (it's managed data) or show a
  collapsed "Properties" row like Obsidian? Lean: hide it, and show
  Obsidian `tags` as chips under the title later.
- **Android formatting bar:** a row above the keyboard (bold, list,
  checkbox, link) is standard on mobile and may be needed for use with a
  touch keyboard.
- **Accent color:** use the system accent (Mac) and Material You dynamic
  color (Android), or a Seanboy brand accent? GNote 51 moved to the system
  accent.
