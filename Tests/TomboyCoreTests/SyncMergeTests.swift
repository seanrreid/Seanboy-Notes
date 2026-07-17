import XCTest
@testable import TomboyCore

final class SyncMergeTests: XCTestCase {
    private func note(_ title: String, modified: TimeInterval, deleted: Bool = false) -> Note {
        Note(title: title, body: "body of \(title)",
             createdAt: Date(timeIntervalSince1970: 0),
             modifiedAt: Date(timeIntervalSince1970: modified),
             isDeleted: deleted)
    }

    private func remote(_ n: Note, updated: TimeInterval? = nil) -> SyncMerge.RemoteNote {
        var r = SyncMerge.RemoteNote(from: n)
        if let updated { r.updatedAt = Date(timeIntervalSince1970: updated) }
        return r
    }

    func testLocalOnlyNoteIsPushed() {
        let a = note("A", modified: 100)
        let plan = SyncMerge.plan(local: [a], remote: [])
        XCTAssertEqual(plan.pushRemotely.map(\.id), [a.id])
        XCTAssertTrue(plan.applyLocally.isEmpty)
    }

    func testRemoteOnlyNoteIsApplied() {
        let a = note("A", modified: 100)
        let plan = SyncMerge.plan(local: [], remote: [remote(a)])
        XCTAssertEqual(plan.applyLocally.map(\.id), [a.id])
        XCTAssertTrue(plan.pushRemotely.isEmpty)
    }

    func testNewerLocalWins() {
        let a = note("A", modified: 200)
        let plan = SyncMerge.plan(local: [a], remote: [remote(a, updated: 100)])
        XCTAssertEqual(plan.pushRemotely.map(\.id), [a.id])
        XCTAssertTrue(plan.applyLocally.isEmpty)
    }

    func testNewerRemoteWins() {
        let a = note("A", modified: 100)
        let theirs = remote(a, updated: 200)
        let plan = SyncMerge.plan(local: [a], remote: [theirs])
        XCTAssertEqual(plan.applyLocally, [theirs])
        XCTAssertTrue(plan.pushRemotely.isEmpty)
    }

    func testEqualTimestampsDoNothing() {
        let a = note("A", modified: 100)
        let plan = SyncMerge.plan(local: [a], remote: [remote(a, updated: 100.005)])
        XCTAssertTrue(plan.applyLocally.isEmpty)
        XCTAssertTrue(plan.pushRemotely.isEmpty)
    }

    func testLocalTombstonePropagates() {
        let a = note("A", modified: 300, deleted: true)
        let plan = SyncMerge.plan(local: [a], remote: [remote(a, updated: 100)])
        XCTAssertEqual(plan.pushRemotely.first?.isDeleted, true)
    }

    func testRemoteTombstoneApplies() {
        let a = note("A", modified: 100)
        var theirs = remote(a, updated: 200)
        theirs.isDeleted = true
        let plan = SyncMerge.plan(local: [a], remote: [theirs])
        XCTAssertEqual(plan.applyLocally.first?.isDeleted, true)
    }

    func testUnsyncedTombstoneStillPushes() {
        let a = note("A", modified: 100, deleted: true)
        let plan = SyncMerge.plan(local: [a], remote: [])
        XCTAssertEqual(plan.pushRemotely.first?.isDeleted, true)
    }

    func testRoundTripThroughRemoteNote() {
        let a = note("A", modified: 123)
        XCTAssertEqual(SyncMerge.RemoteNote(from: a).asNote, a)
    }
}
