import SwiftUI
import AppKit

struct SyncSettingsView: View {
    @EnvironmentObject private var model: NotesViewModel
    @ObservedObject private var sync: SyncService

    @State private var urlString = ""
    @State private var anonKey = ""
    @State private var email = ""
    @State private var code = ""
    @State private var codeSent = false
    @State private var message: String?

    init() {
        _sync = ObservedObject(wrappedValue: NotesViewModel.shared.sync)
    }

    var body: some View {
        Form {
            Section("Supabase Project") {
                TextField("Project URL", text: $urlString,
                          prompt: Text("https://xyzcompany.supabase.co"))
                SecureField("Anon (public) API key", text: $anonKey)
                HStack {
                    Button("Save Credentials") { saveCredentials() }
                        .disabled(urlString.isEmpty || anonKey.isEmpty)
                    Button("Reveal Config File") {
                        NSWorkspace.shared.activateFileViewerSelecting([SupabaseConfig.fileURL])
                    }
                }
                Text("Stored in `supabase.json` under Application Support — see the README for the one-time Supabase project setup (SQL schema included).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Account") {
                if sync.isSignedIn {
                    LabeledContent("Signed in as", value: sync.userEmail ?? "—")
                    Button("Sign Out") { Task { await sync.signOut() } }
                } else {
                    TextField("Email", text: $email, prompt: Text("you@example.com"))
                    if codeSent {
                        TextField("6-digit code from the email", text: $code)
                        Button("Verify & Sign In") { verifyCode() }
                            .disabled(code.count < 6)
                    }
                    Button(codeSent ? "Resend Code" : "Send Login Code") { sendCode() }
                        .disabled(email.isEmpty || !sync.isConfigured)
                }
            }

            Section("Status") {
                LabeledContent("Sync", value: sync.statusDescription)
                Button("Sync Now") { model.syncNow() }
                    .disabled(!sync.isSignedIn)
            }

            if let message {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(message.hasPrefix("✓") ? Color.green : Color.red)
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .padding(.vertical, 8)
        .onAppear {
            if let config = SupabaseConfig.load() {
                urlString = config.url.absoluteString
                anonKey = config.anonKey
            }
            email = sync.userEmail ?? ""
        }
    }

    private func saveCredentials() {
        do {
            _ = try SupabaseConfig.save(urlString: urlString, anonKey: anonKey)
            sync.reloadConfig()
            message = "✓ Credentials saved."
        } catch {
            message = error.localizedDescription
        }
    }

    private func sendCode() {
        Task {
            do {
                try await sync.sendLoginCode(email: email)
                codeSent = true
                message = "✓ Code sent — check your email."
            } catch {
                message = error.localizedDescription
            }
        }
    }

    private func verifyCode() {
        Task {
            do {
                try await sync.verifyLoginCode(email: email, code: code)
                codeSent = false
                code = ""
                message = "✓ Signed in — first sync started."
            } catch {
                message = error.localizedDescription
            }
        }
    }
}
