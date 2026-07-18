import Foundation
import SeanboyCore

/// Syncs the local NoteStore with an S3-compatible bucket (Cloudflare R2)
/// using the pure three-way planner in SeanboyCore. Strictly on-demand: app
/// open, a debounced nudge after edits, and ⇧⌘S — no timers, no daemons.
@MainActor
final class SyncService: ObservableObject {
    enum State: Equatable {
        case notConfigured
        case idle
        case syncing
        case success(Date)
        case error(String)
    }

    @Published private(set) var state: State = .notConfigured

    /// Remote versions kept per note by copy-on-overwrite.
    static let versionCap = 10
    /// Quiet period after the last edit before a sync fires.
    static let debounceSeconds: Double = 3

    private var store: NoteStore
    private let stateFileURL: URL
    private var client: S3Client?
    private var debounceTask: Task<Void, Never>?

    init(store: NoteStore, stateFileURL: URL) {
        self.store = store
        self.stateFileURL = stateFileURL
        reloadConfig()
    }

    /// Repoints sync at a new store after a notes-folder change.
    func attach(store: NoteStore) {
        self.store = store
    }

    var isConfigured: Bool { client != nil }

    var statusDescription: String {
        switch state {
        case .notConfigured:
            return "Sync is off — add your R2 bucket credentials in Settings"
        case .idle:
            return "Configured — click to sync now"
        case .syncing:
            return "Syncing…"
        case .success(let date):
            return "Last synced \(date.formatted(date: .abbreviated, time: .standard))"
        case .error(let message):
            return "Sync failed: \(message)"
        }
    }

    func reloadConfig() {
        if let config = SyncConfigFile.load() {
            client = S3Client(config: config)
            if state == .notConfigured { state = .idle }
        } else {
            client = nil
            state = .notConfigured
        }
    }

    // MARK: - Triggers

    func syncNow() {
        guard client != nil, state != .syncing else { return }
        debounceTask?.cancel()
        Task { await sync() }
    }

    /// Called after user edits; coalesces bursts of typing into one sync.
    func noteDidChange() {
        guard client != nil else { return }
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.debounceSeconds))
            guard !Task.isCancelled else { return }
            self?.syncNow()
        }
    }

    // MARK: - Sync

    private func sync() async {
        guard let client else { return }
        state = .syncing
        do {
            var syncState = SyncState.load(from: stateFileURL)

            // 1. List live notes and tombstones.
            async let live = client.list(prefix: SyncPlanner.notesPrefix)
            async let tombstones = client.list(prefix: SyncPlanner.tombstonesPrefix)
            var listing = try await (live + tombstones).map {
                SyncPlanner.RemoteFile(key: $0.key, etag: $0.etag)
            }

            // 2. Download anything this device hasn't seen. Objects that
            // don't parse as notes stay note-less and are left untouched.
            let needed = Set(SyncPlanner.keysNeedingDownload(listing: listing, state: syncState))
            for index in listing.indices where needed.contains(listing[index].key) {
                let key = listing[index].key
                let (data, etag) = try await client.get(key: key)
                listing[index].etag = etag
                if let text = String(data: data, encoding: .utf8) {
                    // The key carries the note's tree location; objects
                    // without an id (foreign files) stay note-less.
                    listing[index].note = NoteDocument.note(
                        from: text,
                        relativePath: SyncPlanner.relativePath(forKey: key) ?? "")
                }
            }

            let plan = SyncPlanner.plan(local: store.allNotes, remote: listing, state: syncState)

            // 3. Uploads. Overwrites version-copy the old object first; a
            // 412 means another device wrote concurrently — skip, the next
            // sync downloads their version and re-merges.
            var blocked: [SyncPlanner.Upload] = []
            for upload in plan.uploads {
                do {
                    try await performUpload(upload, client: client, syncState: &syncState)
                } catch S3Error.preconditionFailed {
                    blocked.append(upload)
                }
            }

            // 4. Apply remote changes locally, stashing any displaced local
            // edit into `.versions/` so a lost conflict is never lost data.
            for apply in plan.applyLocally {
                if let displaced = apply.displacedLocal {
                    let name = NoteNaming.sanitize(displaced.title)
                    try? await client.put(
                        key: versionKey(name: name),
                        data: Data(NoteDocument.serialize(displaced).utf8))
                }
                store.applyRemote(apply.note)
                syncState[apply.note.id] = .init(
                    key: apply.key, etag: apply.etag, modifiedAt: apply.note.modifiedAt)
            }

            // 5. Deletions last, so an upload failure never orphans a note.
            for key in plan.deleteRemoteKeys {
                if key.hasPrefix(SyncPlanner.notesPrefix) {
                    await versionCopy(client: client, key: key)
                }
                try? await client.delete(key: key)
            }

            // 6. Retry uploads that hit a taken key — a rename in step 5 may
            // have just freed it. Whatever still fails heals next sync.
            var unresolved = 0
            for upload in blocked {
                do {
                    try await performUpload(upload, client: client, syncState: &syncState)
                } catch {
                    unresolved += 1
                }
            }

            try syncState.save(to: stateFileURL)
            state = .success(Date())
            if unresolved > 0 { noteDidChange() }  // nudge a follow-up merge
        } catch {
            state = .error(error.localizedDescription)
            NSLog("Seanboy: sync failed: \(error)")
        }
    }

    private func performUpload(_ upload: SyncPlanner.Upload, client: S3Client,
                               syncState: inout SyncState) async throws {
        if upload.expectedETag != nil {
            await versionCopy(client: client, key: upload.key)
        }
        let etag = try await client.put(
            key: upload.key,
            data: Data(NoteDocument.serialize(upload.note).utf8),
            ifMatch: upload.expectedETag,
            ifNoneMatch: upload.expectedETag == nil)
        syncState[upload.note.id] = .init(
            key: upload.key, etag: etag, modifiedAt: upload.note.modifiedAt)
    }

    // MARK: - Versioning

    /// Best-effort copy of the current object into `.versions/<name>/`,
    /// pruned to the newest `versionCap` entries.
    private func versionCopy(client: S3Client, key: String) async {
        guard key.hasPrefix(SyncPlanner.notesPrefix) else { return }
        let name = String(key.dropFirst(SyncPlanner.notesPrefix.count).dropLast(3))  // strip ".md"
        try? await client.copy(from: key, to: versionKey(name: name))

        let prefix = SyncPlanner.versionsPrefix + name + "/"
        guard let versions = try? await client.list(prefix: prefix),
              versions.count > Self.versionCap else { return }
        // Timestamped names sort lexically — oldest first.
        for old in versions.sorted(by: { $0.key < $1.key })
            .prefix(versions.count - Self.versionCap) {
            try? await client.delete(key: old.key)
        }
    }

    private func versionKey(name: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return SyncPlanner.versionsPrefix + name + "/" + formatter.string(from: Date()) + ".md"
    }
}
