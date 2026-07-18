import AppKit
import SwiftUI

/// Floating quick-capture panel summoned by the global hotkey. First line
/// becomes the note title; the rest is the body.
@MainActor
final class QuickCaptureController {
    static let shared = QuickCaptureController()
    private var panel: NSPanel?

    func show() {
        if panel == nil {
            let panel = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 440, height: 220),
                styleMask: [.titled, .closable, .nonactivatingPanel, .utilityWindow],
                backing: .buffered, defer: false)
            panel.title = "Quick Note"
            panel.level = .floating
            panel.isFloatingPanel = true
            panel.hidesOnDeactivate = false
            panel.isReleasedWhenClosed = false
            panel.contentView = NSHostingView(
                rootView: QuickCaptureView { [weak self] in self?.dismiss() })
            panel.center()
            self.panel = panel
        }
        panel?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func dismiss() {
        panel?.close()
    }
}

private struct QuickCaptureView: View {
    var onDone: () -> Void
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextEditor(text: $text)
                .font(.body)
                .focused($focused)
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 6).fill(.quaternary.opacity(0.5)))

            HStack {
                Text("First line becomes the title")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") {
                    text = ""
                    onDone()
                }
                .keyboardShortcut(.cancelAction)
                Button("Save Note") {
                    save()
                }
                .keyboardShortcut(.return, modifiers: [.command])
                .buttonStyle(.borderedProminent)
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(12)
        .frame(width: 440, height: 220)
        .onAppear { focused = true }
    }

    private func save() {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var lines = trimmed.components(separatedBy: "\n")
        let title = lines.removeFirst().trimmingCharacters(in: .whitespaces)
        let body = lines.drop(while: \.isEmpty).joined(separator: "\n")
        NotesViewModel.shared.createNote(title: title.isEmpty ? "Quick Note" : title, body: body)
        text = ""
        onDone()
    }
}
