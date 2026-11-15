import AppKit
import GlimmerCore
import os

let saveLog = Logger(subsystem: "com.brattoo.glimmer", category: "save")

/// Tells the person why a document couldn't be saved (or autosaved).
///
/// The system shows its own sheet for a failed save, but all it can say is that the file
/// doesn't exist. Glimmer's explanation (how much room is needed, that nothing was lost)
/// follows once that sheet is gone: the document's save isn't finished until then, and a
/// second sheet on top of it locked the next save. Shown once per document until a save works.
@MainActor
final class SaveFailures {
    static let shared = SaveFailures()
    private var failing: Set<String> = []

    func failed(_ message: String, advice: String?, saving name: String) {
        saveLog.error("couldn't save \(name, privacy: .public): \(message, privacy: .public)")
        guard failing.insert(name).inserted else { return }
        Task { @MainActor in
            // Wait for the system's sheet to come and go (or not to come at all, as for an autosave).
            var sawSheet = false
            for tick in 0..<1200 {
                let sheetUp = NSApp.windows.contains { $0.attachedSheet != nil } || NSApp.modalWindow != nil
                if sheetUp { sawSheet = true } else if sawSheet || tick > 20 { break }
                try? await Task.sleep(for: .milliseconds(100))
            }
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = String(localized: "The document couldn't be saved")
            alert.informativeText = message + "\n\n"
                + (advice ?? String(localized: "The document is still open and nothing was lost. Try saving it somewhere else."))
            alert.addButton(withTitle: String(localized: "OK"))
            if let window = NSApp.keyWindow ?? NSApp.mainWindow {
                alert.beginSheetModal(for: window) { _ in }
            } else {
                alert.runModal()
            }
        }
    }

    func saved(_ name: String) {
        failing.remove(name)
    }
}
