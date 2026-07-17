import Foundation

/// Pure last-writer-wins merge between the local store and remote rows.
/// Kept free of networking so it is trivially unit-testable; the Supabase
/// service feeds it and executes the returned actions.
public enum SyncMerge {

    /// A note as it exists in the remote `notes` table.
    public struct RemoteNote: Equatable, Sendable {
        public var id: UUID
        public var title: String
        public var body: String
        public var createdAt: Date
        public var updatedAt: Date
        public var isDeleted: Bool

        public init(id: UUID, title: String, body: String,
                    createdAt: Date, updatedAt: Date, isDeleted: Bool) {
            self.id = id
            self.title = title
            self.body = body
            self.createdAt = createdAt
            self.updatedAt = updatedAt
            self.isDeleted = isDeleted
        }

        public init(from note: Note) {
            self.init(id: note.id, title: note.title, body: note.body,
                      createdAt: note.createdAt, updatedAt: note.modifiedAt,
                      isDeleted: note.isDeleted)
        }

        public var asNote: Note {
            Note(id: id, title: title, body: body,
                 createdAt: createdAt, modifiedAt: updatedAt, isDeleted: isDeleted)
        }
    }

    public struct Plan: Equatable, Sendable {
        /// Remote rows to write into the local store.
        public var applyLocally: [RemoteNote] = []
        /// Local notes to upsert to the remote table.
        public var pushRemotely: [RemoteNote] = []

        public init() {}
    }

    /// Timestamps within this window count as equal — filesystem and
    /// Postgres clocks don't store identical precision.
    public static let timestampTolerance: TimeInterval = 0.01

    public static func plan(local: [Note], remote: [RemoteNote]) -> Plan {
        var plan = Plan()
        let remoteByID = Dictionary(uniqueKeysWithValues: remote.map { ($0.id, $0) })
        let localByID = Dictionary(uniqueKeysWithValues: local.map { ($0.id, $0) })

        for note in local {
            guard let theirs = remoteByID[note.id] else {
                // Never seen remotely — push (including tombstones, so
                // deletes made before first sync still propagate).
                plan.pushRemotely.append(RemoteNote(from: note))
                continue
            }
            let delta = note.modifiedAt.timeIntervalSince(theirs.updatedAt)
            if delta > timestampTolerance {
                plan.pushRemotely.append(RemoteNote(from: note))
            } else if delta < -timestampTolerance {
                plan.applyLocally.append(theirs)
            }
            // else: in sync — nothing to do.
        }

        for theirs in remote where localByID[theirs.id] == nil {
            plan.applyLocally.append(theirs)
        }

        return plan
    }
}
