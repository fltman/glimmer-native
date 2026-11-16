import AppKit
import GlimmerCore
import GlimmerRender
import UniformTypeIdentifiers

/// "Edit in Glimmer" from a sibling app (Flimmer, Jämmer): the handed-over image is an
/// untitled Glimmer document, and Save writes it back, flattened, into the same file in
/// the same format. Autosave never touches the file.
extension EditorSession {
    /// Links the document to `image`; the link is saved with the document from now on.
    func link(to image: LinkedImage) {
        setLinkedImage(image)
        // The bookmark is what lets a relaunched, sandboxed Glimmer write the file again.
        let bookmark = try? image.url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
        if bookmark == nil { saveLog.error("no bookmark for the linked file \(image.fileName, privacy: .public)") }
        document.linkRecord = DocumentLink(bookmark: bookmark, path: image.url.path, requester: image.requester)
        noteLinkChanged()
        watchCloseButton()
        watchLinkedFile()
    }

    /// Why the linked file can't be saved back right now, or nil when it can. Looked at on
    /// disk each time: the sibling may remove, restore or replace its file while Glimmer runs.
    static func linkTrouble(path: String, name: String, requester: String) -> String? {
        guard FileManager.default.fileExists(atPath: path) else {
            return String(localized: "\(name) is no longer where it was, so Glimmer can't save it back to \(requester).")
        }
        guard FileManager.default.isWritableFile(atPath: path), (try? FileHandle(forUpdating: URL(fileURLWithPath: path)))?.closeFile() != nil else {
            return String(localized: "Glimmer is no longer allowed to write \(name), so it can't save it back to \(requester).")
        }
        return nil
    }

    /// Brings the link's state in line with the file as it is now. A file that has gone makes
    /// the link a broken one (the bar, the menu and the agent API's `available` follow, and
    /// Save explains instead of failing); a file that is back, or has been replaced by a new
    /// one at the same place, makes it whole again. Returns true when the file can be saved to.
    @discardableResult
    func refreshLinkedFile() -> Bool {
        if let link = linkedImage {
            guard let trouble = Self.linkTrouble(path: link.url.path, name: link.fileName, requester: link.requester) else { return true }
            let record = document.linkRecord ?? DocumentLink(bookmark: nil, path: link.url.path, requester: link.requester)
            saveLog.notice("the linked file went away while open: \(link.fileName, privacy: .public)")
            linkedImage = nil
            brokenLink = (record, trouble)
            return false
        }
        if let broken = brokenLink {
            let path = broken.link.path
            guard Self.linkTrouble(path: path, name: broken.link.fileName, requester: broken.link.requester) == nil,
                  let image = LinkedImage(url: linkAccess?.path == path ? linkAccess! : URL(fileURLWithPath: path), requester: broken.link.requester) else { return false }
            saveLog.notice("the linked file is back: \(image.fileName, privacy: .public)")
            brokenLink = nil
            setLinkedImage(image)
            return true
        }
        return false
    }

    /// Looks at the linked file once a second while the document is linked (or was, and may be again).
    func watchLinkedFile() {
        guard linkWatch == nil else { return }
        linkWatch = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.linkedImage != nil || self.brokenLink != nil else {
                    self?.linkWatch?.invalidate()
                    self?.linkWatch = nil
                    return
                }
                self.refreshLinkedFile()
            }
        }
    }

    /// After a restart: the document came back from disk with a link. Finds the file again,
    /// or says why it can't; either way the window stays the linked one.
    func restoreLink(attempt: Int = 0) {
        guard linkedImage == nil, brokenLink == nil, let record = document.linkRecord else { return }
        // Wait for the window: whether the document is a file of the person's own is asked of it.
        guard let window = canvasWindow, let saved = NSDocumentController.shared.document(for: window) else {
            if attempt < 50 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                    MainActor.assumeIsolated { self?.restoreLink(attempt: attempt + 1) }
                }
            }
            return
        }
        // A document the person saved as a .glimmer file of their own is theirs, not the link's.
        if saved.fileURL != nil {
            document.linkRecord = nil
            return
        }
        var url = URL(fileURLWithPath: record.path)
        var scoped = false
        if let bookmark = record.bookmark {
            var stale = false
            if let resolved = try? URL(resolvingBookmarkData: bookmark, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &stale) {
                url = resolved
                scoped = resolved.startAccessingSecurityScopedResource()
                if scoped { linkAccess = resolved }
                if stale, let fresh = try? resolved.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil) {
                    document.linkRecord?.bookmark = fresh
                }
            }
        }
        let name = record.fileName
        func broken(_ reason: String) {
            saveLog.error("linked file not restored: \(reason, privacy: .public)")
            brokenLink = (record, reason)
            setDocumentName(name)
            watchLinkedFile()   // the file may come back while the window is open
        }
        guard FileManager.default.fileExists(atPath: url.path) else {
            return broken(String(localized: "\(name) is no longer where it was, so Glimmer can't save it back to \(record.requester)."))
        }
        guard FileManager.default.isWritableFile(atPath: url.path), (try? FileHandle(forUpdating: url))?.closeFile() != nil else {
            return broken(String(localized: "Glimmer is no longer allowed to write \(name), so it can't save it back to \(record.requester)."))
        }
        guard let image = LinkedImage(url: url, requester: record.requester) else {
            return broken(String(localized: "Glimmer can't write \(name) in its format."))
        }
        setLinkedImage(image)
        watchCloseButton()
        watchLinkedFile()
        setDocumentName(image.fileName)   // the file may have been renamed or moved; the bookmark follows it
        if document.linkRecord?.path != url.path { document.linkRecord?.path = url.path }
        saveLog.notice("linked file restored: \(name, privacy: .public), security scope \(scoped ? "held" : "not needed or not given", privacy: .public)")
    }

    /// The link is part of what autosave writes, so the document counts as changed: a
    /// window that is restored after a restart then has its link with it.
    func noteLinkChanged(attempt: Int = 0) {
        guard let window = canvasWindow, let saved = NSDocumentController.shared.document(for: window) else {
            if attempt < 50 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                    MainActor.assumeIsolated { self?.noteLinkChanged(attempt: attempt + 1) }
                }
            }
            return
        }
        saved.updateChangeCount(.changeDone)
    }

    /// Closing a linked window whose work is all in the file must not ask "keep this new
    /// document?": nothing is unsaved then, and the kept copy is no longer needed.
    func prepareToCloseLinkedWindow() {
        guard linkedImage != nil, savedBackGeneration == stateGeneration,
              let window = canvasWindow, let document = NSDocumentController.shared.document(for: window), document.fileURL == nil else { return }
        document.updateChangeCount(.changeCleared)
    }

    /// The window's close button goes through `prepareToCloseLinkedWindow` first.
    func watchCloseButton(attempt: Int = 0) {
        guard let window = canvasWindow, let button = window.standardWindowButton(.closeButton) else {
            if attempt < 50 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                    MainActor.assumeIsolated { self?.watchCloseButton(attempt: attempt + 1) }
                }
            }
            return
        }
        guard !(button.target is LinkedWindowCloser) else { return }
        let closer = LinkedWindowCloser(session: self, target: button.target, action: button.action)
        linkedCloser = closer
        button.target = closer
        button.action = #selector(LinkedWindowCloser.close(_:))
    }

    /// ⌘S on a document whose link is broken: explain, and offer the layered copy. Never Save As by itself.
    func explainBrokenLink() {
        guard let broken = brokenLink else { return }
        errorMessage = broken.reason + " " + String(localized: "Your edit is still here. File › Save a Glimmer Copy… keeps it with its layers; then send the picture to \(broken.link.requester) again from there.")
    }

    /// File › Save while linked: flatten and write back in place.
    func saveLinkedImage() {
        // The file is looked at now, not as it was a second ago: a file that has gone gets
        // the explanation and the way on (Save a Glimmer Copy…), never a bare write error.
        guard refreshLinkedFile() else { return explainBrokenLink() }
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
        // The layered document, with its link, is what brings this window back after a restart
        // or a crash. The system keeps that copy only for a document that counts as changed
        // (at Quit it drops the others before the app is asked anything), so a linked document
        // stays "changed" and is autosaved now; closing it is handled in `prepareToCloseLinkedWindow`.
        savedBackGeneration = stateGeneration
        document.updateChangeCount(.changeDone)
        document.autosave(withImplicitCancellability: false) { error in
            if let error { saveLog.error("autosave after saving back failed: \(error.localizedDescription, privacy: .public)") }
        }
    }

    /// File › Save a Glimmer Copy…: the layered document as a `.glimmer` next to the image,
    /// if the user wants one (a save panel, so the sandbox allows writing there).
    func saveGlimmerCopy() {
        let source: URL
        if let link = linkedImage { source = link.url } else if let broken = brokenLink { source = URL(fileURLWithPath: broken.link.path) } else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.glimmerDocument]
        if linkedImage != nil { panel.directoryURL = source.deletingLastPathComponent() }
        panel.nameFieldStringValue = source.deletingPathExtension().lastPathComponent + ".glimmer"
        panel.message = linkedImage != nil
            ? String(localized: "The layers stay editable in the copy; \(source.lastPathComponent) is still what Save writes.")
            : String(localized: "The layers stay editable in the copy.")
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

/// Target of a linked window's close button: prepares, then does what the button did before.
/// (Not `performClose`: that presses the close button, which would come straight back here.)
@MainActor
final class LinkedWindowCloser: NSObject {
    weak var session: EditorSession?
    weak var target: AnyObject?
    let action: Selector?

    init(session: EditorSession, target: AnyObject?, action: Selector?) {
        self.session = session
        self.target = target
        self.action = action
    }

    @objc func close(_ sender: Any?) {
        session?.prepareToCloseLinkedWindow()
        if let action { NSApp.sendAction(action, to: target, from: sender) }
    }
}
