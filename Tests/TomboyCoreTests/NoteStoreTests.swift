import XCTest
@testable import TomboyCore

final class NoteDocumentTests: XCTestCase {
    func testRoundTrip() {
        let note = Note(title: "Groceries: weekly", body: "- Milk\n- Eggs\n\n[[Recipes]]")
        let text = NoteDocument.serialize(note)
        let parsed = NoteDocument.deserialize(text)
        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed?.id, note.id)
        XCTAssertEqual(parsed?.title, "Groceries: weekly")
        XCTAssertEqual(parsed?.body, note.body)
        XCTAssertEqual(parsed?.isDeleted, false)
        XCTAssertEqual(parsed!.modifiedAt.timeIntervalSince(note.modifiedAt), 0, accuracy: 0.001)
    }

    func testDeserializeTombstone() {
        var note = Note(title: "Gone")
        note.isDeleted = true
        let parsed = NoteDocument.deserialize(NoteDocument.serialize(note))
        XCTAssertEqual(parsed?.isDeleted, true)
    }

    func testBodyContainingFrontmatterDelimiter() {
        let note = Note(title: "Tricky", body: "intro\n---\noutro")
        let parsed = NoteDocument.deserialize(NoteDocument.serialize(note))
        XCTAssertEqual(parsed?.body, "intro\n---\noutro")
    }

    func testGarbageReturnsNil() {
        XCTAssertNil(NoteDocument.deserialize("just some markdown, no header"))
        XCTAssertNil(NoteDocument.deserialize(""))
    }
}

final class NoteStoreTests: XCTestCase {
    private var dir: URL!
    private var store: NoteStore!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tomboy-tests-\(UUID().uuidString)")
        store = try NoteStore(directory: dir)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    func testCreatePersistsToDiskAndReloads() throws {
        let note = store.create(title: "Hello", body: "World")
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.fileURL(for: note.id).path))

        let fresh = try NoteStore(directory: dir)
        XCTAssertEqual(fresh.activeNotes.count, 1)
        XCTAssertEqual(fresh.activeNotes.first?.title, "Hello")
        XCTAssertEqual(fresh.activeNotes.first?.body, "World")
    }

    func testUpdateTouchesModified() throws {
        var note = store.create(title: "A")
        let before = note.modifiedAt
        note.body = "changed"
        store.update(note)
        let after = try XCTUnwrap(store.note(id: note.id))
        XCTAssertEqual(after.body, "changed")
        XCTAssertGreaterThanOrEqual(after.modifiedAt, before)
    }

    func testDeleteTombstonesAndHides() throws {
        let note = store.create(title: "Bye")
        store.delete(id: note.id)
        XCTAssertTrue(store.activeNotes.isEmpty)
        // Tombstone still on disk and marked deleted, so it can sync.
        let fresh = try NoteStore(directory: dir)
        XCTAssertEqual(fresh.allNotes.count, 1)
        XCTAssertEqual(fresh.allNotes.first?.isDeleted, true)
    }

    func testUniqueTitles() {
        XCTAssertEqual(store.create(title: "New Note").title, "New Note")
        XCTAssertEqual(store.create(title: "New Note").title, "New Note 2")
        XCTAssertEqual(store.create(title: "new note").title, "new note 3")
    }

    func testTitleLookupIsCaseInsensitive() {
        store.create(title: "Recipes")
        XCTAssertNotNil(store.note(titled: "recipes"))
        XCTAssertNotNil(store.note(titled: "  RECIPES "))
        XCTAssertNil(store.note(titled: "Missing"))
    }
}
