import SwiftUI

@main
struct GlimmerApp: App {
    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate

    var body: some Scene {
        DocumentGroup { document in
            DocumentView(document: document)
        } makeDocument: { _, _ in
            // Also called when a file is opened or a window restored; the reader then
            // replaces this state (and a queued state is handed on, see `queuedState`).
            if let queued = DocumentOpener.shared.takePendingState() {
                let document = GlimmerDocument(state: queued)
                document.queuedState = queued
                return document
            }
            return GlimmerDocument()
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New…") { DocumentOpener.shared.showNewDocumentWindow() }
                    .keyboardShortcut("n")
            }
            GlimmerCommands()
            CheckForUpdatesCommand()
            CommandGroup(replacing: .help) {
                Button("Welcome to Glimmer") { DocumentOpener.shared.showWelcomeWindow() }
                Button("Agent Access…") { DocumentOpener.shared.showAgentSplash() }
                Divider()
                Link("Glimmer Manual", destination: URL(string: "https://glimmer.brattoo.com/manual/")!)
                Link("Frequently Asked Questions", destination: URL(string: "https://glimmer.brattoo.com/faq.html")!)
            }
        }

        Settings {
            SettingsView()
        }
    }
}
