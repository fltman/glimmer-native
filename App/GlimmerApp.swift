import SwiftUI

@main
struct GlimmerApp: App {
    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate

    var body: some Scene {
        DocumentGroup { document in
            DocumentView(document: document)
        } makeDocument: { _, _ in
            // When a file is being opened, the reader replaces this state.
            GlimmerDocument(state: DocumentOpener.shared.takePendingState()
                ?? .new(width: 1920, height: 1080, background: .white))
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New…") { DocumentOpener.shared.showNewDocumentWindow() }
                    .keyboardShortcut("n")
            }
            GlimmerCommands()
        }

        Settings {
            SettingsView()
        }
    }
}
