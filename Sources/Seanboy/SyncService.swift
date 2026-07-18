import Foundation
import Supabase
import SeanboyCore

/// Syncs the local NoteStore with the Supabase `notes` table using the pure
/// last-writer-wins planner in SeanboyCore. Auth is email OTP: Supabase sends
/// a 6-digit code, the user types it into Settings.
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
    @Published private(set) var userEmail: String?

    private let store: NoteStore
    private var client: SupabaseClient?
    private var timer: Timer?

    /// Wire row for the `notes` table (snake_case matches the columns).
    private struct NoteRow: Codable {
        var id: UUID
        var user_id: UUID?
        var title: String
        var body: String
        var created_at: Date
        var updated_at: Date
        var deleted: Bool

        init(_ remote: SyncMerge.RemoteNote, userID: UUID?) {
            id = remote.id
            user_id = userID
            title = remote.title
            body = remote.body
            created_at = remote.createdAt
            updated_at = remote.updatedAt
            deleted = remote.isDeleted
        }

        var asRemote: SyncMerge.RemoteNote {
            .init(id: id, title: title, body: body,
                  createdAt: created_at, updatedAt: updated_at, isDeleted: deleted)
        }
    }

    init(store: NoteStore) {
        self.store = store
        reloadConfig()
    }

    var statusDescription: String {
        switch state {
        case .notConfigured:
            return "Sync is off — add Supabase credentials in Settings"
        case .idle:
            return userEmail == nil
                ? "Configured — sign in from Settings to start syncing"
                : "Signed in as \(userEmail ?? ""). Click to sync now."
        case .syncing:
            return "Syncing…"
        case .success(let date):
            return "Last synced \(date.formatted(date: .abbreviated, time: .standard))"
        case .error(let message):
            return "Sync failed: \(message)"
        }
    }

    var isConfigured: Bool { client != nil }
    var isSignedIn: Bool { userEmail != nil }

    func reloadConfig() {
        guard let config = SupabaseConfig.load() else {
            client = nil
            state = .notConfigured
            userEmail = nil
            return
        }
        client = SupabaseClient(supabaseURL: config.url, supabaseKey: config.anonKey)
        userEmail = client?.auth.currentUser?.email
        state = .idle
    }

    // MARK: - Auth (email OTP)

    func sendLoginCode(email: String) async throws {
        guard let client else { throw notConfiguredError() }
        try await client.auth.signInWithOTP(email: email)
    }

    func verifyLoginCode(email: String, code: String) async throws {
        guard let client else { throw notConfiguredError() }
        try await client.auth.verifyOTP(
            email: email,
            token: code.trimmingCharacters(in: .whitespaces),
            type: .email)
        userEmail = client.auth.currentUser?.email
        syncNow()
    }

    func signOut() async {
        try? await client?.auth.signOut()
        userEmail = nil
        state = client == nil ? .notConfigured : .idle
    }

    // MARK: - Sync

    func startAutoSync(interval: TimeInterval = 300) {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { _ in
            Task { @MainActor [weak self] in self?.syncNow() }
        }
        syncNow()
    }

    func syncNow() {
        guard client != nil, isSignedIn, state != .syncing else { return }
        Task { await sync() }
    }

    private func sync() async {
        guard let client else { return }
        state = .syncing
        do {
            let session = try await client.auth.session
            let userID = session.user.id

            let rows: [NoteRow] = try await client.from("notes")
                .select()
                .execute()
                .value

            let plan = SyncMerge.plan(
                local: store.allNotes,
                remote: rows.map(\.asRemote))

            for remote in plan.applyLocally {
                store.applyRemote(remote.asNote)
            }
            if !plan.pushRemotely.isEmpty {
                let payload = plan.pushRemotely.map { NoteRow($0, userID: userID) }
                try await client.from("notes")
                    .upsert(payload, onConflict: "id")
                    .execute()
            }
            state = .success(Date())
        } catch {
            state = .error(error.localizedDescription)
            NSLog("Seanboy: sync failed: \(error)")
        }
    }

    private func notConfiguredError() -> Error {
        NSError(domain: "Seanboy", code: 2, userInfo: [
            NSLocalizedDescriptionKey:
                "Add your Supabase URL and anon key in Settings → Sync first.",
        ])
    }
}
