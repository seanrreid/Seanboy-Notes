import Foundation

/// Pure three-way sync planner between the local store, the bucket listing,
/// and the last-sync state. Free of networking so every scenario is unit-
/// testable; `SyncService` feeds it and executes the returned actions.
///
/// Bucket layout:
///   notes/<Title>.md            live notes, human-browsable
///   .tombstones/<uuid>.md       deleted notes (so deletion propagates)
///   .versions/<name>/<ts>.md    copy-on-overwrite history (service-managed)
public enum SyncPlanner {

    public static let notesPrefix = "notes/"
    public static let tombstonesPrefix = ".tombstones/"
    public static let versionsPrefix = ".versions/"

    /// `modifiedAt` values within this window count as equal.
    public static let timestampTolerance: TimeInterval = 0.01

    /// A listed bucket object; `note` is populated once downloaded.
    public struct RemoteFile: Equatable, Sendable {
        public var key: String
        public var etag: String
        public var note: Note?

        public init(key: String, etag: String, note: Note? = nil) {
            self.key = key
            self.etag = etag
            self.note = note
        }
    }

    public struct Upload: Equatable, Sendable {
        public var note: Note
        public var key: String
        /// ETag the object must still have (`If-Match`). nil means the key
        /// must not exist yet (`If-None-Match: *`).
        public var expectedETag: String?

        public init(note: Note, key: String, expectedETag: String? = nil) {
            self.note = note
            self.key = key
            self.expectedETag = expectedETag
        }
    }

    public struct LocalApply: Equatable, Sendable {
        public var note: Note
        public var key: String
        public var etag: String
        /// Local content displaced by a lost conflict — the service stashes
        /// it in `.versions/` before overwriting, so nothing is silently lost.
        public var displacedLocal: Note?

        public init(note: Note, key: String, etag: String, displacedLocal: Note? = nil) {
            self.note = note
            self.key = key
            self.etag = etag
            self.displacedLocal = displacedLocal
        }
    }

    public struct Plan: Equatable, Sendable {
        public var applyLocally: [LocalApply] = []
        public var uploads: [Upload] = []
        /// Remote keys made obsolete (renames, superseded tombstones,
        /// duplicate objects). Deleted after uploads succeed.
        public var deleteRemoteKeys: [String] = []

        public init() {}

        public var isEmpty: Bool {
            applyLocally.isEmpty && uploads.isEmpty && deleteRemoteKeys.isEmpty
        }
    }

    // MARK: - Keys

    /// Object key a note lives at: its relative path under `notes/` (the
    /// bucket mirrors the local tree 1:1), UUID under `.tombstones/` once
    /// deleted. Paths are unique locally, so no collision handling needed.
    public static func key(for note: Note) -> String {
        note.isDeleted
            ? tombstonesPrefix + note.id.uuidString + ".md"
            : notesPrefix + note.relativePath
    }

    /// The relative path a `notes/`-prefixed key maps to locally.
    public static func relativePath(forKey key: String) -> String? {
        key.hasPrefix(notesPrefix) ? String(key.dropFirst(notesPrefix.count)) : nil
    }

    // MARK: - Planning

    /// Keys the service must download before planning: any listed object
    /// whose (key, etag) pair this device hasn't recorded.
    public static func keysNeedingDownload(listing: [RemoteFile], state: SyncState) -> [String] {
        let known = Set(state.entries.values.map { "\($0.key)\u{0}\($0.etag)" })
        return listing
            .filter { $0.note == nil && !known.contains("\($0.key)\u{0}\($0.etag)") }
            .map(\.key)
    }

    /// `remote` must contain every listed object under `notes/` and
    /// `.tombstones/`, with `note` populated for each key returned by
    /// `keysNeedingDownload`.
    public static func plan(local: [Note], remote: [RemoteFile], state: SyncState) -> Plan {
        var plan = Plan()
        let etagByKey = Dictionary(remote.map { ($0.key, $0.etag) },
                                   uniquingKeysWith: { first, _ in first })

        // Downloaded remote notes by ID; duplicates (stale rename leftovers)
        // resolve to the newest copy, the rest get cleaned up.
        var remoteByID: [UUID: RemoteFile] = [:]
        for file in remote {
            guard let note = file.note else { continue }
            if let existing = remoteByID[note.id], let existingNote = existing.note {
                if note.modifiedAt > existingNote.modifiedAt {
                    plan.deleteRemoteKeys.append(existing.key)
                    remoteByID[note.id] = file
                } else {
                    plan.deleteRemoteKeys.append(file.key)
                }
            } else {
                remoteByID[note.id] = file
            }
        }

        let localByID = Dictionary(uniqueKeysWithValues: local.map { ($0.id, $0) })

        for note in local {
            let entry = state[note.id]
            let target = key(for: note)
            let localChanged = entry.map {
                note.modifiedAt.timeIntervalSince($0.modifiedAt) > timestampTolerance
            } ?? true

            if let file = remoteByID[note.id], let theirs = file.note {
                // Remote changed (or state was lost and everything re-downloaded).
                if notesEquivalent(note, theirs) {
                    // Already in sync — just refresh state via a no-op apply.
                    plan.applyLocally.append(LocalApply(note: note, key: file.key, etag: file.etag))
                    continue
                }
                // Timestamps decide only a true conflict (both sides changed);
                // a remote-only change always applies, so clock skew on
                // another device can never override an edit made here.
                let localWins = localChanged
                    && note.modifiedAt.timeIntervalSince(theirs.modifiedAt) > timestampTolerance
                if localWins {
                    plan.uploads.append(Upload(
                        note: note, key: target,
                        expectedETag: target == file.key ? file.etag : nil))
                    if target != file.key {
                        plan.deleteRemoteKeys.append(file.key)
                    }
                } else {
                    // Remote wins; preserve the losing local edit if there was one.
                    plan.applyLocally.append(LocalApply(
                        note: theirs, key: file.key, etag: file.etag,
                        displacedLocal: localChanged ? note : nil))
                    if let entry, entry.key != file.key, etagByKey[entry.key] != nil {
                        plan.deleteRemoteKeys.append(entry.key)
                    }
                }
            } else if let entry {
                if etagByKey[entry.key] == nil {
                    // The object vanished without a tombstone (manual bucket
                    // edit or interrupted rename) — restore it from local.
                    plan.uploads.append(Upload(note: note, key: target, expectedETag: nil))
                } else if localChanged || target != entry.key {
                    // Remote untouched since last sync; push the local edit
                    // (or relocate the object after a key reassignment).
                    plan.uploads.append(Upload(
                        note: note, key: target,
                        expectedETag: target == entry.key ? entry.etag : nil))
                    if target != entry.key {
                        plan.deleteRemoteKeys.append(entry.key)
                    }
                }
                // else: fully in sync — nothing to do.
            } else {
                // Never synced from this device — push, tombstones included,
                // so deletes made before first sync still propagate.
                plan.uploads.append(Upload(note: note, key: target, expectedETag: nil))
            }
        }

        // Remote-only notes: new on another device — pull them in.
        for (id, file) in remoteByID where localByID[id] == nil {
            guard let note = file.note else { continue }
            plan.applyLocally.append(LocalApply(note: note, key: file.key, etag: file.etag))
        }

        return plan
    }

    /// Content-equal within timestamp tolerance — used to recognize
    /// already-in-sync notes after a state-file loss.
    static func notesEquivalent(_ a: Note, _ b: Note) -> Bool {
        a.id == b.id && a.relativePath == b.relativePath && a.body == b.body
            && a.isDeleted == b.isDeleted
            && a.extraFrontmatter == b.extraFrontmatter
            && abs(a.modifiedAt.timeIntervalSince(b.modifiedAt)) <= timestampTolerance
    }
}
