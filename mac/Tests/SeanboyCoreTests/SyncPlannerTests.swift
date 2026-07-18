import XCTest
@testable import SeanboyCore

final class SyncPlannerTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_750_000_000)
    private func at(_ offset: TimeInterval) -> Date { t0.addingTimeInterval(offset) }

    private func makeNote(_ title: String, body: String = "body",
                          created: TimeInterval = 0, modified: TimeInterval = 0,
                          deleted: Bool = false) -> Note {
        Note(title: title, body: body, createdAt: at(created),
             modifiedAt: at(modified), isDeleted: deleted)
    }

    private func stateEntry(for note: Note, key: String, etag: String) -> SyncState {
        var state = SyncState()
        state[note.id] = .init(key: key, etag: etag, modifiedAt: note.modifiedAt)
        return state
    }

    // MARK: - Keys

    func testKeyMirrorsRelativePath() {
        let note = Note(relativePath: "Journal/2026/July.md")
        XCTAssertEqual(SyncPlanner.key(for: note), "notes/Journal/2026/July.md")
        XCTAssertEqual(SyncPlanner.relativePath(forKey: "notes/Journal/2026/July.md"),
                       "Journal/2026/July.md")
        XCTAssertNil(SyncPlanner.relativePath(forKey: ".tombstones/x.md"))
    }

    func testKeyForTombstoneUsesID() {
        let deleted = makeNote("Gone", deleted: true)
        XCTAssertEqual(SyncPlanner.key(for: deleted),
                       ".tombstones/\(deleted.id.uuidString).md")
    }

    // MARK: - Download selection

    func testKeysNeedingDownloadSkipsKnownPairs() {
        let note = makeNote("Known")
        let state = stateEntry(for: note, key: "notes/Known.md", etag: "e1")
        let listing = [
            SyncPlanner.RemoteFile(key: "notes/Known.md", etag: "e1"),
            SyncPlanner.RemoteFile(key: "notes/Known2.md", etag: "e9"),
            SyncPlanner.RemoteFile(key: "notes/Known.md", etag: "e2"),
        ]
        XCTAssertEqual(
            SyncPlanner.keysNeedingDownload(listing: listing, state: state),
            ["notes/Known2.md", "notes/Known.md"])
    }

    // MARK: - Planning

    func testFirstSyncPushesEverythingIncludingTombstones() {
        let live = makeNote("Fresh")
        let dead = makeNote("Dead", deleted: true)
        let plan = SyncPlanner.plan(local: [live, dead], remote: [], state: SyncState())

        XCTAssertEqual(plan.uploads.count, 2)
        XCTAssertTrue(plan.applyLocally.isEmpty)
        XCTAssertTrue(plan.deleteRemoteKeys.isEmpty)
        let byID = Dictionary(uniqueKeysWithValues: plan.uploads.map { ($0.note.id, $0) })
        XCTAssertEqual(byID[live.id]?.key, "notes/Fresh.md")
        XCTAssertNil(byID[live.id]?.expectedETag)
        XCTAssertEqual(byID[dead.id]?.key, ".tombstones/\(dead.id.uuidString).md")
    }

    func testRemoteOnlyNoteIsApplied() {
        let theirs = makeNote("From elsewhere")
        let remote = [SyncPlanner.RemoteFile(key: "notes/From elsewhere.md",
                                             etag: "e1", note: theirs)]
        let plan = SyncPlanner.plan(local: [], remote: remote, state: SyncState())

        XCTAssertEqual(plan.applyLocally, [
            .init(note: theirs, key: "notes/From elsewhere.md", etag: "e1"),
        ])
        XCTAssertTrue(plan.uploads.isEmpty)
    }

    func testLocalEditPushesWithIfMatch() {
        var note = makeNote("Edited", modified: 0)
        let state = stateEntry(for: note, key: "notes/Edited.md", etag: "e1")
        note.modifiedAt = at(60)
        let remote = [SyncPlanner.RemoteFile(key: "notes/Edited.md", etag: "e1")]

        let plan = SyncPlanner.plan(local: [note], remote: remote, state: state)
        XCTAssertEqual(plan.uploads, [
            .init(note: note, key: "notes/Edited.md", expectedETag: "e1"),
        ])
        XCTAssertTrue(plan.applyLocally.isEmpty)
        XCTAssertTrue(plan.deleteRemoteKeys.isEmpty)
    }

    func testFullySyncedProducesEmptyPlan() {
        let note = makeNote("Stable")
        let state = stateEntry(for: note, key: "notes/Stable.md", etag: "e1")
        let remote = [SyncPlanner.RemoteFile(key: "notes/Stable.md", etag: "e1")]
        XCTAssertTrue(SyncPlanner.plan(local: [note], remote: remote, state: state).isEmpty)
    }

    func testRemoteEditAppliesEvenWithOlderTimestamp() {
        // Device B's clock is behind, so its edit carries an older modifiedAt.
        // Local is unchanged — the remote edit must still win.
        let note = makeNote("Skewed", modified: 0)
        let state = stateEntry(for: note, key: "notes/Skewed.md", etag: "e1")
        var theirs = note
        theirs.body = "edited on B"
        theirs.modifiedAt = at(-3600)
        let remote = [SyncPlanner.RemoteFile(key: "notes/Skewed.md", etag: "e2", note: theirs)]

        let plan = SyncPlanner.plan(local: [note], remote: remote, state: state)
        XCTAssertEqual(plan.applyLocally.count, 1)
        XCTAssertEqual(plan.applyLocally.first?.note.body, "edited on B")
        XCTAssertNil(plan.applyLocally.first?.displacedLocal)
        XCTAssertTrue(plan.uploads.isEmpty)
    }

    func testConflictLocalWins() {
        var note = makeNote("Conflict", modified: 0)
        let state = stateEntry(for: note, key: "notes/Conflict.md", etag: "e1")
        var theirs = note
        theirs.body = "their edit"
        theirs.modifiedAt = at(30)
        note.body = "my edit"
        note.modifiedAt = at(60)
        let remote = [SyncPlanner.RemoteFile(key: "notes/Conflict.md", etag: "e2", note: theirs)]

        let plan = SyncPlanner.plan(local: [note], remote: remote, state: state)
        XCTAssertEqual(plan.uploads, [
            .init(note: note, key: "notes/Conflict.md", expectedETag: "e2"),
        ])
        XCTAssertTrue(plan.applyLocally.isEmpty)
    }

    func testConflictRemoteWinsPreservesDisplacedLocal() {
        var note = makeNote("Conflict", modified: 0)
        let state = stateEntry(for: note, key: "notes/Conflict.md", etag: "e1")
        var theirs = note
        theirs.body = "their edit"
        theirs.modifiedAt = at(60)
        note.body = "my edit"
        note.modifiedAt = at(30)
        let remote = [SyncPlanner.RemoteFile(key: "notes/Conflict.md", etag: "e2", note: theirs)]

        let plan = SyncPlanner.plan(local: [note], remote: remote, state: state)
        XCTAssertEqual(plan.applyLocally.count, 1)
        XCTAssertEqual(plan.applyLocally.first?.note.body, "their edit")
        XCTAssertEqual(plan.applyLocally.first?.displacedLocal?.body, "my edit")
    }

    func testRenameUploadsNewKeyAndDeletesOld() {
        var note = makeNote("Old Title", modified: 0)
        let state = stateEntry(for: note, key: "notes/Old Title.md", etag: "e1")
        note.title = "New Title"
        note.modifiedAt = at(60)
        let remote = [SyncPlanner.RemoteFile(key: "notes/Old Title.md", etag: "e1")]

        let plan = SyncPlanner.plan(local: [note], remote: remote, state: state)
        XCTAssertEqual(plan.uploads, [
            .init(note: note, key: "notes/New Title.md", expectedETag: nil),
        ])
        XCTAssertEqual(plan.deleteRemoteKeys, ["notes/Old Title.md"])
    }

    func testKeyReassignmentRelocatesUnchangedNote() {
        // Same title/timestamps, but the key this note should live at changed
        // (e.g. a collision was resolved). It must still relocate.
        let note = makeNote("Moved")
        let state = stateEntry(for: note, key: "notes/Stale Name.md", etag: "e1")
        let remote = [SyncPlanner.RemoteFile(key: "notes/Stale Name.md", etag: "e1")]

        let plan = SyncPlanner.plan(local: [note], remote: remote, state: state)
        XCTAssertEqual(plan.uploads, [
            .init(note: note, key: "notes/Moved.md", expectedETag: nil),
        ])
        XCTAssertEqual(plan.deleteRemoteKeys, ["notes/Stale Name.md"])
    }

    func testLocalDeletePushesTombstoneAndRemovesLiveObject() {
        var note = makeNote("Doomed", modified: 0)
        let state = stateEntry(for: note, key: "notes/Doomed.md", etag: "e1")
        note.isDeleted = true
        note.modifiedAt = at(60)
        let remote = [SyncPlanner.RemoteFile(key: "notes/Doomed.md", etag: "e1")]

        let plan = SyncPlanner.plan(local: [note], remote: remote, state: state)
        XCTAssertEqual(plan.uploads, [
            .init(note: note, key: ".tombstones/\(note.id.uuidString).md", expectedETag: nil),
        ])
        XCTAssertEqual(plan.deleteRemoteKeys, ["notes/Doomed.md"])
    }

    func testRemoteTombstoneApplies() {
        let note = makeNote("Deleted elsewhere", modified: 0)
        let state = stateEntry(for: note, key: "notes/Deleted elsewhere.md", etag: "e1")
        var theirs = note
        theirs.isDeleted = true
        theirs.modifiedAt = at(60)
        let key = ".tombstones/\(note.id.uuidString).md"
        let remote = [SyncPlanner.RemoteFile(key: key, etag: "t1", note: theirs)]

        let plan = SyncPlanner.plan(local: [note], remote: remote, state: state)
        XCTAssertEqual(plan.applyLocally.count, 1)
        XCTAssertEqual(plan.applyLocally.first?.note.isDeleted, true)
        XCTAssertEqual(plan.applyLocally.first?.key, key)
    }

    func testEditAfterRemoteDeleteResurrectsNote() {
        var note = makeNote("Lazarus", modified: 0)
        let state = stateEntry(for: note, key: "notes/Lazarus.md", etag: "e1")
        var theirs = note
        theirs.isDeleted = true
        theirs.modifiedAt = at(30)
        note.body = "edited after their delete"
        note.modifiedAt = at(60)
        let tombstoneKey = ".tombstones/\(note.id.uuidString).md"
        let remote = [SyncPlanner.RemoteFile(key: tombstoneKey, etag: "t1", note: theirs)]

        let plan = SyncPlanner.plan(local: [note], remote: remote, state: state)
        XCTAssertEqual(plan.uploads, [
            .init(note: note, key: "notes/Lazarus.md", expectedETag: nil),
        ])
        XCTAssertEqual(plan.deleteRemoteKeys, [tombstoneKey])
    }

    func testVanishedRemoteObjectIsRestored() {
        let note = makeNote("Vanished")
        let state = stateEntry(for: note, key: "notes/Vanished.md", etag: "e1")

        let plan = SyncPlanner.plan(local: [note], remote: [], state: state)
        XCTAssertEqual(plan.uploads, [
            .init(note: note, key: "notes/Vanished.md", expectedETag: nil),
        ])
    }

    func testStateLossRecognizesEquivalentNotes() {
        let note = makeNote("Recovered")
        let remote = [SyncPlanner.RemoteFile(key: "notes/Recovered.md", etag: "e1", note: note)]

        let plan = SyncPlanner.plan(local: [note], remote: remote, state: SyncState())
        XCTAssertTrue(plan.uploads.isEmpty)
        XCTAssertEqual(plan.applyLocally, [
            .init(note: note, key: "notes/Recovered.md", etag: "e1"),
        ])
    }

    func testDuplicateRemoteObjectsKeepNewest() {
        var newer = makeNote("Dup", modified: 60)
        var older = newer
        older.modifiedAt = at(0)
        newer.modifiedAt = at(60)
        let remote = [
            SyncPlanner.RemoteFile(key: "notes/Dup (old).md", etag: "e1", note: older),
            SyncPlanner.RemoteFile(key: "notes/Dup.md", etag: "e2", note: newer),
        ]

        let plan = SyncPlanner.plan(local: [], remote: remote, state: SyncState())
        XCTAssertEqual(plan.deleteRemoteKeys, ["notes/Dup (old).md"])
        XCTAssertEqual(plan.applyLocally.map(\.key), ["notes/Dup.md"])
    }

    func testForeignObjectIsLeftAlone() {
        // A README someone dropped into notes/ — undecodable, never touched.
        let remote = [SyncPlanner.RemoteFile(key: "notes/README.txt", etag: "x1")]
        let plan = SyncPlanner.plan(local: [], remote: remote, state: SyncState())
        XCTAssertTrue(plan.isEmpty)
    }
}
