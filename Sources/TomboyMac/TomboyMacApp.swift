import SwiftUI
import TomboyCore

@main
struct TomboyMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = NotesViewModel.shared

    var body: some Scene {
        WindowGroup("Tomboy Mac") {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 700, minHeight: 420)
        }
        .commands {
            CommandGroup(after: .newItem) {
                Button("New Note") { model.createNote() }
                    .keyboardShortcut("n", modifiers: [.command])
                Button("Sync Now") { model.syncNow() }
                    .keyboardShortcut("s", modifiers: [.command, .shift])
            }
            TextFormattingCommands()
        }

        Settings {
            SyncSettingsView()
                .environmentObject(model)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var hotKey: GlobalHotKey?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // ⌃⌥⌘N from anywhere opens the quick-capture panel.
        hotKey = GlobalHotKey(keyCode: kVK_N, modifiers: [.command, .option, .control]) {
            QuickCaptureController.shared.show()
        }
        SpotlightIndexer.reindexAll(notes: NotesViewModel.shared.store.activeNotes)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows {
            sender.windows.first?.makeKeyAndOrderFront(nil)
        }
        return true
    }
}
