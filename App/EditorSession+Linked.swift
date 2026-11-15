import AppKit
import GlimmerCore
import GlimmerRender
import UniformTypeIdentifiers

/// "Edit in Glimmer" from a sibling app (Flimmer, Jämmer): the handed-over image is an
/// untitled Glimmer document, and Save writes it back, flattened, into the same file in
/// the same format. Autosave never touches the file.
extension EditorSession {
    /// File › Save while linked: flatten and write back in place.
    func saveLinkedImage() {
        guard let link = linkedImage else { return }
        guard let metal = MetalContext.shared else {
            errorMessage = String(localized: "No Metal GPU available.")
            return
        }
        commitLiveEdit()
        let state = self.state
        Task { @MainActor in
            do {
                try await Task.detached(priority: .userInitiated) {
                    let access = link.url.startAccessingSecurityScopedResource()
                    defer { if access { link.url.stopAccessingSecurityScopedResource() } }
                    try link.write(try ImageExporter.flatten(state, context: metal))
                }.value
                markSavedWithoutPackage()
                showToast(String(localized: "Saved \(link.fileName) for \(link.requester)"))
            } catch {
                errorMessage = String(localized: "Couldn't save \(link.fileName): \(error.localizedDescription)")
            }
        }
    }

    /// The window's document has no unsaved changes now (they're in the linked file), so
    /// closing it doesn't ask to save a `.glimmer` package.
    private func markSavedWithoutPackage() {
        guard let window = canvasWindow, let document = NSDocumentController.shared.document(for: window) else { return }
        document.updateChangeCount(.changeCleared)
    }

    /// File › Save a Glimmer Copy…: the layered document as a `.glimmer` next to the image,
    /// if the user wants one (a save panel, so the sandbox allows writing there).
    func saveGlimmerCopy() {
        guard let link = linkedImage else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.glimmerDocument]
        panel.directoryURL = link.url.deletingLastPathComponent()
        panel.nameFieldStringValue = link.url.deletingPathExtension().lastPathComponent + ".glimmer"
        panel.message = String(localized: "The layers stay editable in the copy; \(link.fileName) is still what Save writes.")
        let state = self.state
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            MainActor.assumeIsolated {
                do {
                    let wrapper = try GlimmerPackage.fileWrapper(for: state)
                    try wrapper.write(to: url, options: [.atomic], originalContentsURL: nil)
                    self?.showToast(String(localized: "Saved \(url.lastPathComponent)"))
                } catch {
                    self?.errorMessage = error.localizedDescription
                }
            }
        }
    }
}
