import SwiftUI

@main
struct GlimmerApp: App {
    var body: some Scene {
        DocumentGroup { document in
            DocumentView(document: document)
        } makeDocument: { _, _ in
            GlimmerDocument()
        }
        .commands {
            ViewMenuCommands()
        }

        Settings {
            SettingsView()
        }
    }
}
