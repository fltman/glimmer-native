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
        adoptJournal(nil)
        watchCloseButton()
        watchLinkedFile()
    }

    // MARK: The link journal (the-apps/SIBLINGS.md §6.6)

    /// Starts this document's journal entry, or takes over the one it was opened from, and takes the document out of
    /// the system's own saving and window restoration: the journal is the one way a linked window comes back.
    func adoptJournal(_ entry: LinkJournal.Entry?) {
        journalID = entry?.id ?? journalID ?? UUID().uuidString
        linkedAt = entry?.record.linkedAt ?? linkedAt ?? Date()
        if let entry {
            hasUnreturnedEdits = entry.record.unreturned
            unreturnedSteps = entry.record.unreturnedSteps ?? (entry.record.unreturned ? 1 : 0)
            recovered = entry.record.unreturned
            keptFromLastTime = entry.record.unreturned && entry.record.keptKnowingly == true
            if recovered {
                // The whole sentence, once: what happened, that nothing is in the file yet, and that the history starts here.
                let name = entry.record.fileName, requester = entry.record.link.requester
                showToast(keptFromLastTime
                    ? String(localized: "Kept from last time: the edits of \(name) are not saved back to \(requester) yet. Undo starts from here.")
                    : String(localized: "Brought back after Glimmer stopped: the edits of \(name) are not saved back to \(requester) yet. Undo starts from here."))
            }
        }
        document.onStep = { [weak self] in self?.stepWasMade() }
        // An entry that was just read is on disk as it is; a new link writes its first state now.
        writeJournal(withState: entry == nil)
        leaveSystem()
    }

    /// After every step: the entry is written, so a crash costs at most the step in progress.
    private func stepWasMade() {
        guard journalID != nil else { return }
        hasUnreturnedEdits = true
        unreturnedSteps += 1
        writeJournal(withState: true)
        DispatchQueue.main.async { [weak self] in MainActor.assumeIsolated { self?.leaveSystemSaving() } }
    }

    /// `keptKnowingly`: at Quit and at Keep for Later, so the next launch can say "Kept from last time" rather than "Brought back".
    func writeJournal(withState: Bool, keptKnowingly: Bool = false) {
        guard let id = journalID, let link = document.linkRecord ?? brokenLink?.link else { return }
        let record = LinkJournalRecord(id: id, link: link, fileName: link.fileName, unreturned: hasUnreturnedEdits,
                                       unreturnedSteps: unreturnedSteps, keptKnowingly: keptKnowingly ? true : nil,
                                       linkedAt: linkedAt ?? Date(), writtenAt: Date())
        LinkJournal.shared.write(record, state: withState ? state : nil)
    }

    /// This document's journal entry as it is on disk, if it has one.
    var journalEntry: LinkJournal.Entry? {
        guard let id = journalID else { return nil }
        return LinkJournal.shared.entries().first { $0.id == id }
    }

    /// The document no longer has a journal entry (saved back and closed, kept for later, or declined).
    func leaveJournal(removingEntry: Bool) {
        guard let id = journalID else { return }
        if removingEntry { LinkJournal.shared.remove(id) }
        journalID = nil
        document.onStep = nil
    }

    /// Out of the system's saving and restoring, as soon as the window is there.
    private func leaveSystem(attempt: Int = 0) {
        guard let window = canvasWindow, NSDocumentController.shared.document(for: window) != nil else {
            if attempt < 50 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                    MainActor.assumeIsolated { self?.leaveSystem(attempt: attempt + 1) }
                }
            }
            return
        }
        window.isRestorable = false
        leaveSystemSaving()
    }

    /// Closing a linked window. Nothing unreturned: it closes, and its entry is removed. With edits that are not
    /// saved back the person chooses: Save Back, Keep for Later (the entry stays and comes back at the next launch and
    /// under File › Linked Files Waiting…) or Discard (the work copy goes to the Trash). The system's own
    /// "keep this new document?" is never the question for a linked document.
    func closeLinkedWindow(_ close: @escaping @MainActor () -> Void) {
        guard journalID != nil, let window = canvasWindow else { return close() }
        guard hasUnreturnedEdits else {
            leaveSystemSaving()
            leaveJournal(removingEntry: true)
            return close()
        }
        let name = linkedImage?.fileName ?? brokenLink?.link.fileName ?? documentName
        let requester = linkedImage?.requester ?? brokenLink?.link.requester ?? ""
        let alert = NSAlert()
        alert.messageText = unreturnedSteps == 1
            ? String(localized: "\(name) has 1 step not saved back to \(requester).")
            : String(localized: "\(name) has \(unreturnedSteps) steps not saved back to \(requester).")
        alert.informativeText = String(localized: "Keep for Later closes the window and keeps your edits. They come back the next time Glimmer starts, and you find them in the File menu under Linked Files Waiting. Discard moves them to the Trash.")
        // The same four choices when the file can't be reached, with the layered copy in place of saving back.
        let canSaveBack = linkedImage != nil
        alert.addButton(withTitle: canSaveBack ? String(localized: "Save Back") : String(localized: "Save a Glimmer Copy…"))
        alert.addButton(withTitle: String(localized: "Keep for Later"))
        alert.addButton(withTitle: String(localized: "Discard"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.beginSheetModal(for: window) { [weak self] response in
            MainActor.assumeIsolated {
                guard let self else { return }
                let chosen = response.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
                switch chosen {
                case 0 where !canSaveBack:
                    self.saveGlimmerCopy()   // the window stays: the copy is the person's own file, the entry waits as it was
                case 0:
                    self.saveLinkedImage { [weak self] in
                        self?.leaveSystemSaving()
                        self?.leaveJournal(removingEntry: true)
                        close()
                    }
                case 1:
                    self.writeJournal(withState: true, keptKnowingly: true)
                    self.leaveSystemSaving()
                    self.leaveJournal(removingEntry: false)
                    close()
                case 2:
                    let entry = self.journalEntry
                    self.leaveSystemSaving()
                    self.leaveJournal(removingEntry: false)
                    if let entry, !LinkJournal.shared.discard(entry) {
                        self.errorMessage = String(localized: "Glimmer couldn't move the edits to the Trash, so they are kept. You find them in the File menu under Linked Files Waiting.")
                        return
                    }
                    close()
                default:
                    break
                }
            }
        }
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
    func restoreLink(journal entry: LinkJournal.Entry? = nil, attempt: Int = 0) {
        guard linkedImage == nil, brokenLink == nil, let record = document.linkRecord else { return }
        // Wait for the window: whether the document is a file of the person's own is asked of it.
        guard let window = canvasWindow, let saved = NSDocumentController.shared.document(for: window) else {
            if attempt < 50 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                    MainActor.assumeIsolated { self?.restoreLink(journal: entry, attempt: attempt + 1) }
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
            adoptJournal(entry)   // never held back: the edits are shown, and Save a Glimmer Copy… is the way on
            watchCloseButton()
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
        adoptJournal(entry)
        if document.linkRecord != entry?.record.link { writeJournal(withState: false) }   // a fresh bookmark or a new path
        saveLog.notice("linked file restored: \(name, privacy: .public), security scope \(scoped ? "held" : "not needed or not given", privacy: .public)")
    }

    /// Closing a linked window whose work is all in the file must not ask "keep this new
    /// document?": nothing is unsaved then, and the kept copy is no longer needed.
    func prepareToCloseLinkedWindow() {
        guard linkedImage != nil, !hasUnreturnedEdits else { return }
        leaveSystemSaving()
    }

    /// Takes the document out of the system's own saving: it no longer counts as changed, so the system neither
    /// asks about it nor keeps a copy of its own. What is not saved back yet is in the link journal.
    func leaveSystemSaving() {
        guard let window = canvasWindow, let document = NSDocumentController.shared.document(for: window), document.fileURL == nil else { return }
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
    func saveLinkedImage(then done: (@MainActor () -> Void)? = nil) {
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
                done?()
            } catch {
                errorMessage = String(localized: "Couldn't save \(link.fileName): \(error.localizedDescription)")
            }
        }
    }

    /// The window's document has no unsaved changes now (they're in the linked file), so
    /// closing it doesn't ask to save a `.glimmer` package.
    private func markSavedWithoutPackage() {
        // Everything is in the file now. The entry stays while the window is open (the link survives Quit),
        // and says that nothing waits to be saved back.
        savedBackGeneration = stateGeneration
        hasUnreturnedEdits = false
        unreturnedSteps = 0
        recovered = false
        keptFromLastTime = false
        writeJournal(withState: true)
        leaveSystemSaving()
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
        let action = action, target = target
        let proceed: @MainActor () -> Void = { if let action { NSApp.sendAction(action, to: target, from: sender) } }
        if let session { session.closeLinkedWindow(proceed) } else { proceed() }
    }
}
