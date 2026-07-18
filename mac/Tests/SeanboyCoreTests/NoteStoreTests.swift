import XCTest
@testable import SeanboyCore

final class NoteDocumentTests: XCTestCase {
    func testRoundTrip() {
        let note = Note(title: "Groceries", body: "- Milk\n- Eggs\n\n[[Recipes]]")
        let text = NoteDocument.serialize(note)
        let parsed = NoteDocument.note(from: text, relativePath: "Groceries.md")
        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed?.id, note.id)
        XCTAssertEqual(parsed?.title, "Groceries")
        XCTAssertEqual(parsed?.body, note.body)
        XCTAssertEqual(parsed?.isDeleted, false)
        XCTAssertEqual(parsed!.modifiedAt.timeIntervalSince(note.modifiedAt), 0, accuracy: 0.001)
    }

    func testTombstoneSerialization() {
        var note = Note(title: "Gone")
        note.isDeleted = true
        let parsed = NoteDocument.parse(NoteDocument.serialize(note))
        XCTAssertTrue(parsed.deleted)
    }

    func testBodyContainingFrontmatterDelimiter() {
        let note = Note(title: "Tricky", body: "intro\n---\noutro")
        let parsed = NoteDocument.note(
            from: NoteDocument.serialize(note), relativePath: "Tricky.md")
        XCTAssertEqual(parsed?.body, "intro\n---\noutro")
    }

    func testNoFrontmatterIsAllBodyNeedingAdoption() {
        let parsed = NoteDocument.parse("# Just Markdown\n\nNo header at all.")
        XCTAssertNil(parsed.id)
        XCTAssertEqual(parsed.body, "# Just Markdown\n\nNo header at all.")
    }

    func testObsidianFrontmatterPreservedVerbatim() {
        let obsidian = """
        ---
        tags:
          - journal
          - ideas
        aliases: [JRN, Daily]
        cssclass: wide
        created: not-a-date-obsidian-style
        ---

        Body text here.
        """
        let parsed = NoteDocument.parse(obsidian)
        XCTAssertNil(parsed.id)
        // Every unmanaged line survives, order intact — including the
        // unparseable `created:` value, kept as a foreign line.
        XCTAssertEqual(parsed.extraFrontmatter, [
            "tags:",
            "  - journal",
            "  - ideas",
            "aliases: [JRN, Daily]",
            "cssclass: wide",
            "created: not-a-date-obsidian-style",
        ])
        XCTAssertEqual(parsed.body, "Body text here.")

        // Adoption injects only our managed keys; extras ride along verbatim.
        let adopted = NoteDocument.note(
            from: obsidian, relativePath: "Journal/Daily.md", fallbackID: UUID())!
        let rewritten = NoteDocument.serialize(adopted)
        for line in parsed.extraFrontmatter {
            XCTAssertTrue(rewritten.contains(line), "lost line: \(line)")
        }
        let reparsed = NoteDocument.parse(rewritten)
        XCTAssertEqual(reparsed.extraFrontmatter, parsed.extraFrontmatter)
        XCTAssertEqual(reparsed.id, adopted.id)
        XCTAssertEqual(reparsed.body, "Body text here.")
    }

    func testForeignIDStaysOursGoesUnderSeanboyID() {
        let text = """
        ---
        id: 20240811-obsidian-zettel
        ---

        body
        """
        let adopted = NoteDocument.note(
            from: text, relativePath: "Zettel.md", fallbackID: UUID())!
        let rewritten = NoteDocument.serialize(adopted)
        XCTAssertTrue(rewritten.contains("id: 20240811-obsidian-zettel"))
        XCTAssertTrue(rewritten.contains("seanboy-id: \(adopted.id.uuidString)"))

        let reparsed = NoteDocument.parse(rewritten)
        XCTAssertEqual(reparsed.id, adopted.id)
        XCTAssertTrue(reparsed.extraFrontmatter.contains("id: 20240811-obsidian-zettel"))
    }

    func testLegacyTitleReadButNeverWritten() {
        let legacy = """
        ---
        id: \(UUID().uuidString)
        title: Old Style Note
        created: 2026-07-17T12:00:00Z
        modified: 2026-07-17T12:34:56Z
        deleted: false
        ---

        legacy body
        """
        let parsed = NoteDocument.parse(legacy)
        XCTAssertEqual(parsed.legacyTitle, "Old Style Note")
        let note = NoteDocument.note(from: legacy, relativePath: "Old Style Note.md")!
        XCTAssertFalse(NoteDocument.serialize(note).contains("title:"))
    }

    func testGarbageIsJustBody() {
        let parsed = NoteDocument.parse("")
        XCTAssertNil(parsed.id)
        XCTAssertEqual(parsed.body, "")
    }
}

final class NoteNamingTests: XCTestCase {
    func testTitleDerivesFromFilename() {
        let note = Note(relativePath: "Journal/2026/July Notes.md")
        XCTAssertEqual(note.title, "July Notes")
        XCTAssertEqual(note.folder, "Journal/2026")
    }

    func testSettingTitleMovesWithinFolder() {
        var note = Note(relativePath: "Journal/Old.md")
        note.title = "New Name"
        XCTAssertEqual(note.relativePath, "Journal/New Name.md")
    }

    func testSanitization() {
        XCTAssertEqual(NoteNaming.sanitize("a/b: plan"), "a-b- plan")
        XCTAssertEqual(NoteNaming.sanitize("  .hidden  "), "hidden")
        XCTAssertEqual(NoteNaming.sanitize(""), "Untitled")
    }
}

final class NoteStoreTests: XCTestCase {
    private var directory: URL!
    private var tombstoneURL: URL!

    override func setUpWithError() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("SeanboyStoreTests-\(UUID().uuidString)")
        directory = base.appendingPathComponent("Notes")
        tombstoneURL = base.appendingPathComponent("tombstones.json")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory.deletingLastPathComponent())
    }

    private func makeStore() throws -> NoteStore {
        try NoteStore(directory: directory, tombstoneFileURL: tombstoneURL)
    }

    private func writeFile(_ path: String, _ contents: String) throws {
        let url = directory.appendingPathComponent(path)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }

    func testCreateWritesHumanFilename() throws {
        let store = try makeStore()
        let note = store.create(title: "Grocery List", body: "milk")
        XCTAssertEqual(note.relativePath, "Grocery List.md")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("Grocery List.md").path))

        let reloaded = try makeStore()
        XCTAssertEqual(reloaded.note(id: note.id)?.body, "milk")
        XCTAssertEqual(reloaded.note(id: note.id)?.title, "Grocery List")
    }

    func testRecursiveScanFindsNestedNotes() throws {
        try writeFile("Journal/2026/July.md", "# July\n\nentry")
        try writeFile("Projects/Seanboy.md", "notes app")
        try writeFile("root.md", "top-level")
        let store = try makeStore()

        XCTAssertEqual(store.activeNotes.count, 3)
        XCTAssertNotNil(store.note(atPath: "Journal/2026/July.md"))
        XCTAssertEqual(store.note(atPath: "Journal/2026/July.md")?.title, "July")
    }

    func testAdoptionInjectsIDPreservingContent() throws {
        try writeFile("Journal/Daily.md", """
        ---
        tags:
          - journal
        ---

        Obsidian body.
        """)
        let store = try makeStore()
        let note = try XCTUnwrap(store.note(atPath: "Journal/Daily.md"))
        XCTAssertEqual(note.body, "Obsidian body.")
        XCTAssertEqual(note.extraFrontmatter, ["tags:", "  - journal"])

        // The file on disk now carries the injected id and the same content.
        let text = try String(contentsOf: directory.appendingPathComponent("Journal/Daily.md"),
                              encoding: .utf8)
        XCTAssertTrue(text.contains("id: \(note.id.uuidString)"))
        XCTAssertTrue(text.contains("  - journal"))
        XCTAssertTrue(text.contains("Obsidian body."))

        // Adoption is stable: a second store sees the same id.
        let again = try makeStore()
        XCTAssertEqual(again.note(atPath: "Journal/Daily.md")?.id, note.id)
    }

    func testTitleEditRenamesFile() throws {
        let store = try makeStore()
        var note = store.create(title: "Draft", body: "text")
        note.title = "Final"
        store.update(note)

        XCTAssertFalse(FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("Draft.md").path))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("Final.md").path))
        XCTAssertEqual(store.note(id: note.id)?.title, "Final")
        XCTAssertNil(store.note(atPath: "Draft.md"))
    }

    func testCaseOnlyRename() throws {
        let store = try makeStore()
        var note = store.create(title: "readme")
        note.title = "README"
        store.update(note)
        XCTAssertEqual(store.note(id: note.id)?.title, "README")
        let listing = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertEqual(listing.filter { $0.hasSuffix(".md") }, ["README.md"])
    }

    func testDeleteRemovesFileAndRecordsTombstone() throws {
        let store = try makeStore()
        let note = store.create(title: "Doomed")
        store.delete(id: note.id)

        XCTAssertFalse(FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("Doomed.md").path))
        XCTAssertTrue(store.tombstones.contains(id: note.id))
        // Sync still sees the deletion.
        XCTAssertTrue(store.allNotes.contains { $0.id == note.id && $0.isDeleted })
        // The user's folder holds no tombstone files.
        let mdFiles = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasSuffix(".md") }
        XCTAssertTrue(mdFiles.isEmpty)
    }

    func testExternalEditPicksUpNewBody() throws {
        let store = try makeStore()
        let note = store.create(title: "Shared", body: "original")
        // Simulate vim: rewrite the file without updating frontmatter dates.
        let url = directory.appendingPathComponent("Shared.md")
        var text = try String(contentsOf: url, encoding: .utf8)
        text = text.replacingOccurrences(of: "original", with: "edited externally")
        try text.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(10)], ofItemAtPath: url.path)

        XCTAssertTrue(try store.reload())
        XCTAssertEqual(store.note(id: note.id)?.body, "edited externally")
    }

    func testExternalRenameMatchedByID() throws {
        let store = try makeStore()
        let note = store.create(title: "Before", body: "same content")
        let fm = FileManager.default
        try fm.createDirectory(
            at: directory.appendingPathComponent("Archive"), withIntermediateDirectories: true)
        try fm.moveItem(
            at: directory.appendingPathComponent("Before.md"),
            to: directory.appendingPathComponent("Archive/After.md"))

        XCTAssertTrue(try store.reload())
        let moved = try XCTUnwrap(store.note(id: note.id))
        XCTAssertEqual(moved.relativePath, "Archive/After.md")
        XCTAssertEqual(moved.title, "After")
        XCTAssertFalse(store.tombstones.contains(id: note.id))
    }

    func testExternalDeleteRecordsTombstone() throws {
        let store = try makeStore()
        let note = store.create(title: "Removed Outside")
        try FileManager.default.removeItem(
            at: directory.appendingPathComponent("Removed Outside.md"))

        XCTAssertTrue(try store.reload())
        XCTAssertNil(store.note(id: note.id))
        XCTAssertTrue(store.tombstones.contains(id: note.id))
    }

    func testReloadWithoutChangesIsQuiet() throws {
        let store = try makeStore()
        store.create(title: "Stable")
        var fired = false
        store.onChange = { fired = true }
        XCTAssertFalse(try store.reload())
        XCTAssertFalse(fired)
    }

    func testUniqueTitlesPerFolderOnly() throws {
        let store = try makeStore()
        let a = store.create(title: "Ideas")
        let b = store.create(title: "Ideas")
        XCTAssertEqual(a.title, "Ideas")
        XCTAssertEqual(b.title, "Ideas 2")
        // Same title in a different folder is fine.
        let c = store.create(title: "Ideas", folder: "Projects")
        XCTAssertEqual(c.relativePath, "Projects/Ideas.md")
    }

    func testWikiLinkResolutionAcrossFoldersMostRecentWins() throws {
        try writeFile("Journal/Ideas.md", "old")
        try writeFile("Projects/Ideas.md", "new")
        let store = try makeStore()
        var older = try XCTUnwrap(store.note(atPath: "Journal/Ideas.md"))
        older.modifiedAt = Date(timeIntervalSinceNow: -3600)
        store.update(older, touchModified: false)
        var newer = try XCTUnwrap(store.note(atPath: "Projects/Ideas.md"))
        newer.modifiedAt = Date()
        store.update(newer, touchModified: false)

        XCTAssertEqual(store.note(titled: "Ideas")?.relativePath, "Projects/Ideas.md")
        // Qualified form pins the folder.
        XCTAssertEqual(store.note(titled: "Journal/Ideas")?.relativePath, "Journal/Ideas.md")
    }

    func testApplyRemoteTombstoneTrashesFile() throws {
        let store = try makeStore()
        let note = store.create(title: "Synced Away")
        var tombstone = note
        tombstone.isDeleted = true
        tombstone.modifiedAt = Date()
        store.applyRemote(tombstone)

        XCTAssertNil(store.note(id: note.id))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("Synced Away.md").path))
        XCTAssertTrue(store.tombstones.contains(id: note.id))
    }

    func testApplyRemoteMoveRelocatesFile() throws {
        let store = try makeStore()
        let note = store.create(title: "Mobile", body: "v1")
        var moved = note
        moved.relativePath = "Archive/Mobile.md"
        moved.body = "v2"
        store.applyRemote(moved)

        XCTAssertEqual(store.note(id: note.id)?.relativePath, "Archive/Mobile.md")
        XCTAssertEqual(store.note(id: note.id)?.body, "v2")
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("Mobile.md").path))
    }
}

final class LegacyMigrationTests: XCTestCase {
    func testMigratesUUIDFilesToTitles() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("SeanboyMigration-\(UUID().uuidString)")
        let dir = base.appendingPathComponent("Notes")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }

        let liveID = UUID()
        let deadID = UUID()
        try """
        ---
        id: \(liveID.uuidString)
        title: Meeting Notes
        created: 2026-07-01T10:00:00Z
        modified: 2026-07-02T10:00:00Z
        deleted: false
        ---

        agenda
        """.write(to: dir.appendingPathComponent("\(liveID.uuidString).md"),
                  atomically: true, encoding: .utf8)
        try """
        ---
        id: \(deadID.uuidString)
        title: Old Junk
        created: 2026-07-01T10:00:00Z
        modified: 2026-07-03T10:00:00Z
        deleted: true
        ---

        """.write(to: dir.appendingPathComponent("\(deadID.uuidString).md"),
                  atomically: true, encoding: .utf8)

        XCTAssertTrue(LegacyMigration.isNeeded(in: dir))
        let tombstones = TombstoneStore(fileURL: base.appendingPathComponent("tombstones.json"))
        let migrated = try LegacyMigration.run(in: dir, tombstones: tombstones)
        XCTAssertEqual(migrated, 2)
        XCTAssertFalse(LegacyMigration.isNeeded(in: dir))

        let store = try NoteStore(
            directory: dir, tombstoneFileURL: base.appendingPathComponent("tombstones.json"))
        let live = try XCTUnwrap(store.note(id: liveID))
        XCTAssertEqual(live.relativePath, "Meeting Notes.md")
        XCTAssertEqual(live.body, "agenda")
        XCTAssertNil(store.note(id: deadID))
        XCTAssertTrue(store.tombstones.contains(id: deadID))
    }
}

final class FolderWatcherTests: XCTestCase {
    func testExternalFileCreationFiresCallback() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SeanboyWatcher-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let expectation = expectation(description: "watcher fired")
        expectation.assertForOverFulfill = false
        let watcher = FolderWatcher(url: dir, debounce: 0.2) {
            expectation.fulfill()
        }
        watcher.start()
        defer { watcher.stop() }

        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) {
            try? "# hi".write(to: dir.appendingPathComponent("new.md"),
                              atomically: true, encoding: .utf8)
        }
        wait(for: [expectation], timeout: 10)
    }
}
