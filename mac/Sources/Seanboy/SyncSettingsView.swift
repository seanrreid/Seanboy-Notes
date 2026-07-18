import SwiftUI
import AppKit
import SeanboyCore

struct SyncSettingsView: View {
    @EnvironmentObject private var model: NotesViewModel
    @ObservedObject private var sync: SyncService

    @State private var endpoint = ""
    @State private var bucket = ""
    @State private var accessKeyID = ""
    @State private var secretAccessKey = ""
    @State private var message: String?

    init() {
        _sync = ObservedObject(wrappedValue: NotesViewModel.shared.sync)
    }

    var body: some View {
        Form {
            Section("R2 Bucket") {
                TextField("Endpoint", text: $endpoint,
                          prompt: Text("https://<account>.r2.cloudflarestorage.com"))
                TextField("Bucket", text: $bucket, prompt: Text("seanboy-notes"))
                TextField("Access Key ID", text: $accessKeyID)
                SecureField("Secret Access Key", text: $secretAccessKey)
                HStack {
                    Button("Save & Test") { saveAndTest() }
                        .disabled(endpoint.isEmpty || bucket.isEmpty
                                  || accessKeyID.isEmpty || secretAccessKey.isEmpty)
                    Button("Reveal Config File") {
                        NSWorkspace.shared.activateFileViewerSelecting([SyncConfigFile.fileURL])
                    }
                }
                Text("Stored in `sync.json` under Application Support — see the README for the one-time R2 bucket setup. Works with any S3-compatible host; set `region` in the file for non-R2 providers.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Status") {
                LabeledContent("Sync", value: sync.statusDescription)
                Button("Sync Now") { model.syncNow() }
                    .disabled(!sync.isConfigured)
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
            if let config = SyncConfigFile.load() {
                endpoint = config.endpoint.absoluteString
                bucket = config.bucket
                accessKeyID = config.accessKeyID
                secretAccessKey = config.secretAccessKey
            }
        }
    }

    private func saveAndTest() {
        do {
            let config = try SyncConfigFile.save(
                endpoint: endpoint, bucket: bucket,
                accessKeyID: accessKeyID, secretAccessKey: secretAccessKey)
            sync.reloadConfig()
            message = "✓ Credentials saved — testing connection…"
            Task {
                do {
                    _ = try await S3Client(config: config).list(prefix: SyncPlanner.notesPrefix)
                    message = "✓ Connected — first sync started."
                    model.syncNow()
                } catch {
                    message = "Could not reach the bucket: \(error.localizedDescription)"
                }
            }
        } catch {
            message = error.localizedDescription
        }
    }
}
