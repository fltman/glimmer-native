import AppKit
import GlimmerAI
import GlimmerCore
import GlimmerRender
import OSLog
import SwiftUI
import UniformTypeIdentifiers


let openLog = Logger(subsystem: "com.brattoo.glimmer", category: "open")

/// A small window (Welcome, Agent Access) that closes with Esc, wherever the focus is.
final class EscapeClosingWindow: NSWindow {
    override func cancelOperation(_ sender: Any?) { performClose(sender) }
}

/// Creates new documents and opens files.
///
/// Images are never opened *as* documents: autosave would overwrite the
/// original with a `.glimmer` package. Instead an image becomes a new, untitled
/// document with the image as its first layer.
@MainActor
final class DocumentOpener {
    static let shared = DocumentOpener()

    /// States waiting to be picked up by `DocumentGroup`'s `makeDocument`.
    private var pending: [DocumentState] = []
    private var newDocumentWindow: NSWindow?

    /// File › New…: an AppKit-managed window, so SwiftUI never opens it on its own.
    func showNewDocumentWindow() {
        if let window = newDocumentWindow {
            window.makeKeyAndOrderFront(nil)
            return
        }
        let window = NSWindow(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "New Document"
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: NewDocumentView(dismiss: { [weak self] in
            self?.newDocumentWindow?.close()
            self?.newDocumentWindow = nil
        }))
        window.center()
        window.makeKeyAndOrderFront(nil)
        newDocumentWindow = window
    }

    private var welcomeWindow: NSWindow?
    private var agentWindow: NSWindow?
    private var waitingWindow: NSWindow?

    func showWelcomeWindow() {
        if let welcomeWindow {
            welcomeWindow.makeKeyAndOrderFront(nil)
            return
        }
        let window = EscapeClosingWindow(contentRect: .zero, styleMask: [.titled, .closable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.title = String(localized: "Welcome to Glimmer")
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: WelcomeView(dismiss: { [weak self] in
            UserDefaults.standard.set(true, forKey: WelcomeView.shownKey)
            self?.welcomeWindow?.close()
            self?.welcomeWindow = nil
        }))
        window.center()
        window.makeKeyAndOrderFront(nil)
        welcomeWindow = window
        UserDefaults.standard.set(true, forKey: WelcomeView.shownKey)
    }

    /// File › Linked Files Waiting…
    func showLinkedWaiting() {
        waitingWindow?.close()
        let window = EscapeClosingWindow(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = String(localized: "Linked Files Waiting")
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.contentViewController = NSHostingController(rootView: LinkedWaitingView(close: { [weak self] in
            self?.waitingWindow?.close()
            self?.waitingWindow = nil
        }))
        window.center()
        window.makeKeyAndOrderFront(nil)
        waitingWindow = window
    }

    func showAgentSplash() {
        if let agentWindow {
            agentWindow.makeKeyAndOrderFront(nil)
            return
        }
        let window = EscapeClosingWindow(contentRect: .zero, styleMask: [.titled, .closable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.title = String(localized: "Agent Access")
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = NSColor(red: 0.05, green: 0.04, blue: 0.08, alpha: 1)
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: AgentSplashView(dismiss: { [weak self] in
            self?.agentWindow?.close()
            self?.agentWindow = nil
        }))
        window.center()
        window.makeKeyAndOrderFront(nil)
        agentWindow = window
    }

    /// SwiftUI's action for opening a new document from an instance (captured
    /// from the environment by `GlimmerCommands`).
    var newDocumentAction: NewDocumentAction?

    /// Opens a new untitled document window with `state`.
    func createDocument(_ state: DocumentState) {
        if let newDocumentAction {
            newDocumentAction(GlimmerDocument(state: state))
            return
        }
        // Fallback: queue the state for `makeDocument`.
        pending.append(state)
        NSDocumentController.shared.newDocument(nil)
    }

    /// Called from `makeDocument`. Also runs when a file is being opened (the
    /// reader then replaces the state), so it must never block.
    func takePendingState() -> DocumentState? {
        pending.isEmpty ? nil : pending.removeFirst()
    }

    /// `requester` is the sibling app that handed the files over (Flimmer, Jämmer): its
    /// PNG or JPEG is then edited in linked mode, where Save writes back into the same file.
    func open(_ urls: [URL], requester: String? = nil) {
        for url in urls {
            // By its extension first: the system can hand back an undeclared type for
            // ".glimmer" (several copies of the app, or none registered yet), and the
            // document would then be read as an image and refused.
            let type = UTType(filenameExtension: url.pathExtension)
            if url.pathExtension.lowercased() == "glimmer" || type?.conforms(to: .glimmerDocument) == true {
                NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { _, _, error in
                    if let error { NSApp.presentError(PersonMessage.presentable(error)) }
                }
            } else if url.pathExtension.lowercased() == "aips" {
                openAips(url)
            } else if requester != nil, let existing = AgentRegistry.shared.sessions.first(where: {
                let path = url.resolvingSymlinksInPath().path
                return $0.linkedImage?.url.resolvingSymlinksInPath().path == path
                    || $0.brokenLink.map { URL(fileURLWithPath: $0.link.path).resolvingSymlinksInPath().path == path } == true
            }) {
                // The file is already being edited here (perhaps in a window restored after a
                // restart, or one whose file had gone and is back): show that window with its
                // work, rather than a second one of the same file.
                existing.refreshLinkedFile()
                bringForward(existing)
            } else if requester != nil, let entry = LinkJournal.shared.entry(for: url) {
                if pendingEntries.values.contains(where: { $0.id == entry.id }) {
                    // Being opened from the journal this very moment (a launch for this file): only bring it forward.
                    bringForwardLinked(url, attempt: 0)
                } else if entry.record.unreturned {
                    // Glimmer stopped, or the window was closed with Keep for Later, while this file had edits that
                    // were not saved back: open that work, with its layers, instead of the file as it is on disk.
                    openLog.notice("reopening the journal entry for \(url.lastPathComponent, privacy: .public)")
                    if open(entry) { bringForwardLinked(url, attempt: 0) }
                    else { openImage(url, link: requester.flatMap { LinkedImage(url: url, requester: $0) }) }
                } else {
                    // Nothing was waiting: the file as its owner has it now is what is edited.
                    LinkJournal.shared.remove(entry.id)
                    openImage(url, link: requester.flatMap { LinkedImage(url: url, requester: $0) })
                }
            } else {
                openImage(url, link: requester.flatMap { LinkedImage(url: url, requester: $0) })
            }
        }
    }

    // MARK: The link journal at launch and on request

    /// Journal entries on their way to a window, by the id of the document's first layer.
    private var pendingEntries: [UUID: LinkJournal.Entry] = [:]

    private func isOpen(_ entry: LinkJournal.Entry) -> Bool {
        AgentRegistry.shared.sessions.contains { $0.journalID == entry.id } || pendingEntries.values.contains { $0.id == entry.id }
    }

    /// Entries that are not open in a window now (File › Linked Files Waiting…).
    func waitingEntries() -> [LinkJournal.Entry] { LinkJournal.shared.entries().filter { !isOpen($0) } }

    /// Opens an entry as a linked document, from its work copy. False when the work copy can't be read: the entry
    /// is then left where it is and reported, never removed.
    @discardableResult
    func open(_ entry: LinkJournal.Entry) -> Bool {
        guard !isOpen(entry) else { return true }
        do {
            let state = try LinkJournal.state(of: entry)
            guard let first = state.layers.first?.id else { throw CocoaError(.fileReadCorruptFile) }
            pendingEntries[first] = entry
            createDocument(state)
            return true
        } catch {
            openLog.error("a journal entry's work copy can't be read; it is left where it is: \(entry.id, privacy: .public): \(error.localizedDescription, privacy: .public)")
            LinkJournal.shared.noteUnreadable(entry.id)
            return false
        }
    }

    /// At launch (SIBLINGS.md §6.6): every entry with edits that were not saved back is opened, linked and with its
    /// edits, whatever the system's setting for windows says and however the app was started. An entry with nothing
    /// waiting follows the system's setting like any window: opened when windows are kept at Quit, removed when not.
    func openJournalAtLaunch() {
        let d = UserDefaults.standard
        let keepsWindows = d.bool(forKey: "NSQuitAlwaysKeepsWindows") && !d.bool(forKey: "ApplePersistenceIgnoreState")
        for entry in LinkJournal.shared.entries() where !isOpen(entry) {
            if entry.record.unreturned || keepsWindows { open(entry) } else { LinkJournal.shared.remove(entry.id) }
        }
    }

    /// Brings the window that edits `file` to the front once it is there and linked.
    private func bringForwardLinked(_ file: URL, attempt: Int) {
        let wanted = file.resolvingSymlinksInPath().path
        if let session = AgentRegistry.shared.sessions.first(where: { $0.linkedImage?.url.resolvingSymlinksInPath().path == wanted }) {
            bringForward(session)
        } else if attempt < 50 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                MainActor.assumeIsolated { self?.bringForwardLinked(file, attempt: attempt + 1) }
            }
        }
    }

    /// Linked images waiting for their window, by the id of the document's first layer.
    private var pendingLinks: [UUID: LinkedImage] = [:]

    #if GLIMMER_PSD
    /// Documents just made from a Photoshop file, by the id of their first layer: their window
    /// shows the import report when it appears. (The report itself is in the document.)
    private var reportsToShow: Set<UUID> = []

    /// Called when a document window appears: a document just made from a Photoshop file shows its report.
    func claimImportReport(for session: EditorSession) {
        guard let id = session.state.layers.first?.id, reportsToShow.remove(id) != nil, session.importReport != nil else { return }
        session.isImportReportPresented = true
    }

    /// Whether these bytes are a Photoshop file (by its signature, not its name).
    static func isPhotoshopFile(_ data: Data) -> Bool { data.prefix(4) == Data("8BPS".utf8) }

    /// The document for a Photoshop file, with its report in it: what came through, and how
    /// far Glimmer's picture of the layers is from the picture the file carries. The window
    /// that gets this document shows the report. There is no other way in.
    func importPhotoshopFile(_ data: Data) throws -> DocumentState {
        var (state, report) = try PSDImport.document(from: data)
        guard let first = state.layers.first else { throw PSDFile.Problem("This Photoshop file has nothing in it that Glimmer can show.") }
        if !report.flattened, let metal = MetalContext.shared, let difference = PSDAppearance.difference(of: state, from: data, context: metal) {
            report.meanDifference = difference.mean
            report.shareVisiblyDifferent = difference.shareVisible
        }
        state.importReport = report
        reportsToShow.insert(first.id)
        return state
    }

    /// A Photoshop file opens as a new, untitled document with its layers.
    private func openPhotoshopFile(_ data: Data, url: URL) throws {
        createDocument(try importPhotoshopFile(data))
        NSDocumentController.shared.noteNewRecentDocumentURL(url)
    }
    #endif

    #if GLIMMER_RAW
    /// Whether the file's name says it is a camera's RAW file (the decoder decides whether it can be developed).
    static func isRawFile(_ url: URL) -> Bool {
        UTType(filenameExtension: url.pathExtension)?.conforms(to: .rawImage) == true
    }

    /// Whether these bytes are a camera's RAW file, by what the system's image reader says they are (not by a name).
    static func isRawData(_ data: Data) -> Bool {
        guard data.count >= 64, let source = CGImageSourceCreateWithData(data as CFData, nil), let id = CGImageSourceGetType(source) as String? else { return false }
        return UTType(id)?.conforms(to: .rawImage) == true
    }

    /// A RAW file opens as a new document with one layer that keeps the file, so it can be developed again.
    /// Developing takes seconds, so it runs away from the main thread while a small window says
    /// what is happening; the app stays usable. `finished` gets nil when the document is open,
    /// or why it is not.
    func openRawFile(_ data: Data, fileName: String, finished: @escaping @MainActor (Error?) -> Void) {
        let progress = showRawProgress(fileName)
        Task {
            let result = await Task.detached(priority: .userInitiated) { Result { try RawLayer.make(from: data, fileName: fileName) } }.value
            progress.close()
            switch result {
            case .success(let made):
                createDocument(DocumentState(width: made.width, height: made.height, layers: [made.layer]))
                finished(nil)
            case .failure(let error):
                finished(error)
            }
        }
    }

    private func showRawProgress(_ fileName: String) -> NSWindow {
        let panel = NSPanel(contentRect: .zero, styleMask: [.titled, .utilityWindow, .hudWindow], backing: .buffered, defer: false)
        panel.title = String(localized: "Develop RAW")
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.contentViewController = NSHostingController(rootView:
            HStack(spacing: 10) {
                ProgressView().controlSize(.small).accessibilityHidden(true)
                Text("Developing \(fileName)…").fixedSize(horizontal: false, vertical: true)
            }
            .padding(16).frame(width: 360, alignment: .leading))
        panel.center()
        panel.orderFront(nil)
        return panel
    }
    #endif

    /// Called when a document window appears: a handed-over image becomes linked.
    func claimLink(for session: EditorSession) {
        if let id = session.state.layers.first?.id, let entry = pendingEntries.removeValue(forKey: id) {
            // From the link journal: the record holds the link, the document is the work copy.
            // The entry is this window's from now on (said at once, so nothing opens it a second time while the window settles).
            session.journalID = entry.id
            session.document.linkRecord = entry.record.link
            session.restoreLink(journal: entry)
            return
        }
        guard let id = session.state.layers.first?.id, let link = pendingLinks.removeValue(forKey: id) else {
            // Not a hand-over just now: perhaps a window restored by an earlier version, whose document carries its link.
            session.restoreLink()
            return
        }
        session.link(to: link)
        session.setDocumentName(link.fileName)
        bringForward(session)
    }

    /// The app that handed the image over expects Glimmer in front with that document.
    private func bringForward(_ session: EditorSession) {
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                session.canvasWindow?.makeKeyAndOrderFront(nil)
                AgentRegistry.shared.markFront(session)
                NSApp.activate()
            }
        }
    }

    /// The sibling app that sent the current "open" Apple event, by its bundle id, or nil
    /// for Finder and everything else (those images open as ordinary new documents).
    static func appleEventRequester() -> String? {
        requester(of: NSAppleEventManager.shared().currentAppleEvent)
    }

    /// The process that sent `event`: its PID attribute, or the audit token (which a
    /// sandboxed sender's events carry even when the PID is LaunchServices' or missing).
    nonisolated static func senderApp(of event: NSAppleEventDescriptor) -> NSRunningApplication? {
        var pids: [pid_t] = []
        if let pid = event.attributeDescriptor(forKeyword: AEKeyword(keySenderPIDAttr))?.int32Value, pid > 0 { pids.append(pid) }
        if let token = event.attributeDescriptor(forKeyword: AEKeyword(keySenderAuditTokenAttr))?.data,
           token.count == MemoryLayout<audit_token_t>.size {
            // audit_token_to_pid (libbsm) reads val[5]; read it directly rather than link libbsm.
            let pid = token.withUnsafeBytes { pid_t(bitPattern: $0.load(as: audit_token_t.self).val.5) }
            if pid > 0 { pids.append(pid) }
        }
        let apps = pids.compactMap { NSRunningApplication(processIdentifier: $0) }
        openLog.notice("open event: pids \(pids.map(String.init).joined(separator: ","), privacy: .public) → \(apps.map { $0.bundleIdentifier ?? "?" }.joined(separator: ","), privacy: .public)")
        // LaunchServices can be the sender when it starts the app; prefer a real app.
        return apps.first { $0.bundleIdentifier != nil && $0.activationPolicy != .prohibited } ?? apps.first
    }

    nonisolated static func requester(of event: NSAppleEventDescriptor?) -> String? {
        #if DEBUG
        // Tests hand files over from a script: `-linkAnyOpen YES`, or `-linkAnyOpen Flimmer` to name the app.
        if let any = UserDefaults.standard.string(forKey: "linkAnyOpen"), !["", "NO", "0", "false"].contains(any) {
            return ["YES", "1", "true"].contains(any) ? "Test" : any
        }
        #endif
        guard let event else {
            openLog.notice("open: no current Apple event")
            return nil
        }
        guard let app = senderApp(of: event) else {
            openLog.notice("open: the Apple event names no running sender")
            return nil
        }
        openLog.notice("open from \(app.bundleIdentifier ?? "?", privacy: .public) (pid \(app.processIdentifier))")
        if let sibling = SiblingApp.allCases.first(where: { $0.accepts(bundleID: app.bundleIdentifier) }) { return sibling.displayName }
        #if DEBUG
        // Tests send from helper apps with their own bundle ids: com.brattoo.glimmer.linktester…
        // (a sandboxed helper can't pass launch arguments), or `-linkSenderIDs <id>[,<id>…]`.
        let extra = (UserDefaults.standard.string(forKey: "linkSenderIDs") ?? "").split(separator: ",").map(String.init)
        if let id = app.bundleIdentifier, extra.contains(id) || id.hasPrefix("com.brattoo.glimmer.linktester") {
            return app.localizedName ?? id
        }
        #endif
        return nil
    }

    private func openImage(_ url: URL, link: LinkedImage? = nil, asPlainPicture: Bool = false) {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        do {
            // A Photoshop file comes in with its layers. (A file handed over by a sibling to edit
            // and save back stays the picture it is: SIBLINGS.md §6 has no PSD.)
            // Only in builds that have the import (Config/Features.xcconfig); without it the file opens as the picture macOS reads from it.
            #if GLIMMER_PSD
            if link == nil, let handle = try? FileHandle(forReadingFrom: url), let start = try? handle.read(upToCount: 4), Self.isPhotoshopFile(start) {
                try? handle.close()
                try openPhotoshopFile(try Data(contentsOf: url, options: .mappedIfSafe), url: url)
                return
            }
            #endif
            #if GLIMMER_RAW
            // A camera's RAW file keeps its RAW in the layer (Layer › Develop…). A file handed over by
            // a sibling stays a plain picture, as for Photoshop files.
            if link == nil, !asPlainPicture, Self.isRawFile(url) {
                openRawFile(try Data(contentsOf: url, options: .mappedIfSafe), fileName: url.lastPathComponent) { [weak self] error in
                    guard let error else { NSDocumentController.shared.noteNewRecentDocumentURL(url); return }
                    // The decoder gives no picture: macOS's general reader may still have one (a preview
                    // stored in the file), which opens as an ordinary picture. If not, the RAW reason is the one to show.
                    let access = url.startAccessingSecurityScopedResource()
                    let readable = (try? ImageImporter.image(contentsOf: url)) != nil
                    if access { url.stopAccessingSecurityScopedResource() }
                    if error is RawDevelopment.Problem, readable {
                        self?.openImage(url, asPlainPicture: true)
                    } else {
                        openLog.error("couldn't develop \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
                        NSApp.presentError(PersonMessage.presentable(error))
                    }
                }
                return
            }
            #endif
            let image = try ImageImporter.image(contentsOf: url)
            let name = url.deletingPathExtension().lastPathComponent
            // An empty, untouched document (the one Glimmer opens at launch) becomes the image,
            // instead of leaving a blank window behind.
            if let blank = AgentRegistry.shared.sessions.first(where: \.isUntouchedBlank) {
                try blank.place(image, name: name)
                if let link {
                    blank.link(to: link)
                    blank.setDocumentName(link.fileName)
                    bringForward(blank)
                }
                NSDocumentController.shared.noteNewRecentDocumentURL(url)
                return
            }
            let tiles = try ImageImporter.tiles(from: image)
            let layer = Layer(name: name, content: .raster(tiles))
            if let link { pendingLinks[layer.id] = link }
            createDocument(DocumentState(width: image.width, height: image.height, layers: [layer]))
            NSDocumentController.shared.noteNewRecentDocumentURL(url)
        } catch {
            openLog.error("couldn't open \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
            NSApp.presentError(PersonMessage.presentable(error))
        }
    }

    /// Projects from Glimmer for the web open as new, untitled documents.
    private func openAips(_ url: URL) {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        do {
            createDocument(try AipsImporter.importProject(Data(contentsOf: url)))
            NSDocumentController.shared.noteNewRecentDocumentURL(url)
        } catch {
            NSApp.presentError(PersonMessage.presentable(error))
        }
    }

    /// File › Open…: `.glimmer` documents, images and web projects.
    func showOpenPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.glimmerDocument, .image, .aipsProject]
        panel.allowsMultipleSelection = true
        panel.begin { response in
            guard response == .OK else { return }
            let urls = panel.urls
            Task { @MainActor in DocumentOpener.shared.open(urls) }
        }
    }
}

/// Routes Finder/Dock opens and File › Open… through `DocumentOpener`.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var didFinishLaunching = false
    private var deferredURLs: [URL] = []
    private var deferredRequester: String?
    /// Started by a sibling app to edit a file: no restored windows, no Welcome or splash.
    private var launchedForSibling = false

    /// "Open documents" events, read here rather than in application(_:open:): on a cold launch
    /// with windows to restore, AppKit delivers the files later, when the event (and so its sender)
    /// is gone. Opening the files ourselves is fine: LaunchServices grants this process access.
    @objc func handleOpenDocuments(_ event: NSAppleEventDescriptor, withReplyEvent reply: NSAppleEventDescriptor) {
        guard let list = event.paramDescriptor(forKeyword: keyDirectObject) else { return }
        let items = list.numberOfItems > 0 ? (1...list.numberOfItems).compactMap { list.atIndex($0) } : [list]
        let urls = items.compactMap { $0.coerce(toDescriptorType: typeFileURL)?.fileURLValue ?? $0.fileURLValue }
        let requester = DocumentOpener.requester(of: event)
        openLog.notice("odoc: \(urls.count) file(s), requester \(requester ?? "none", privacy: .public), launching \(!self.didFinishLaunching)")
        receive(urls, requester: requester)
    }

    private func receive(_ urls: [URL], requester: String?) {
        guard !urls.isEmpty else { return }
        guard didFinishLaunching else {
            if requester != nil, deferredURLs.isEmpty {
                // Started by a sibling to edit a file: no old windows, no Welcome or splash.
                // Volatile, like the UI tests, so the user's own setting is untouched.
                launchedForSibling = true
                var args = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
                args["ApplePersistenceIgnoreState"] = true
                UserDefaults.standard.setVolatileDomain(args, forName: UserDefaults.argumentDomain)
            }
            deferredURLs += urls
            deferredRequester = deferredRequester ?? requester
            return
        }
        MainActor.assumeIsolated { DocumentOpener.shared.open(urls, requester: requester) }
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSAppleEventManager.shared().setEventHandler(self, andSelector: #selector(handleOpenDocuments(_:withReplyEvent:)),
                                                     forEventClass: AEEventClass(kCoreEventClass), andEventID: AEEventID(kAEOpenDocuments))
        openLog.notice("will finish launching")
        // Undo steps a crashed or killed Glimmer left on disk are only wasted space.
        let orphans = UndoSpillStore.removeOrphans(in: FileManager.default.temporaryDirectory)
        if orphans > 0 { openLog.notice("removed \(orphans) leftover undo folder(s)") }
        // No system Open panel at launch: it only accepts .glimmer documents, and Glimmer
        // shows its Welcome window, Agent Access or its own Open panel instead.
        UserDefaults.standard.register(defaults: ["NSShowAppCentricOpenPanelInsteadOfUntitledFile": false])
        // UI tests start clean: no restored windows. Volatile, so the user's own
        // restoration setting is never touched.
        if CommandLine.arguments.contains("-uiTestingNewDocument") {
            var args = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
            args["ApplePersistenceIgnoreState"] = true
            UserDefaults.standard.setVolatileDomain(args, forName: UserDefaults.argumentDomain)
        }
    }

    /// Quit never asks about a linked document (SIBLINGS.md §6.6): its edits are in the link journal and come back
    /// at the next launch. The system looks for documents to ask about BEFORE it asks the app (tried 2026-11-17), so
    /// a linked document is kept from counting as changed all along (`EditorSession.leaveSystemSaving`, after every
    /// step); here the journal only gets the time to finish what it is writing.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let idle = MainActor.assumeIsolated {
            // Left knowingly: the next launch says "Kept from last time", not "Brought back after Glimmer stopped".
            for session in AgentRegistry.shared.sessions where session.journalID != nil && session.hasUnreturnedEdits {
                session.writeJournal(withState: false, keptKnowingly: true)
            }
            return LinkJournal.shared.isIdle
        }
        guard !idle else { return .terminateNow }
        let started = Date()
        func wait() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                let done = MainActor.assumeIsolated { LinkJournal.shared.isIdle }
                if done || Date().timeIntervalSince(started) > 10 { NSApp.reply(toApplicationShouldTerminate: true) } else { wait() }
            }
        }
        wait()
        return .terminateLater
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // A move of OpenRouter's key to its new keychain account that was interrupted is finished here.
        ProviderKeys.keychain.removeLeftoverOpenRouterItem()
        didFinishLaunching = true
        openLog.notice("did finish launching; for a sibling: \(self.launchedForSibling)")
        // Undo snapshots a previous run left on disk (documents remove their own while the app runs).
        let temp = FileManager.default.temporaryDirectory
        for name in (try? FileManager.default.contentsOfDirectory(atPath: temp.path)) ?? [] where name.hasPrefix("undo-") {
            try? FileManager.default.removeItem(at: temp.appending(path: name))
        }
        // UI tests start from a fresh 800 × 600 document.
        if CommandLine.arguments.contains("-uiTestingNewDocument") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                MainActor.assumeIsolated {
                    DocumentOpener.shared.createDocument(.new(width: 800, height: 600, background: .white))
                    // Started from a background service, the app isn't brought forward by the system.
                    NSApp.activate(ignoringOtherApps: true)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        NSApp.windows.first { $0.isVisible }?.orderFrontRegardless()
                        NSApp.activate(ignoringOtherApps: true)
                    }
                }
            }
        }
        // The local API for agents (guide at /glimmer), and the splash that points agents to it.
        MainActor.assumeIsolated { AgentServer.shared.start() }
        // Linked documents with edits that were not saved back come back now, whatever the system does with windows.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            MainActor.assumeIsolated { DocumentOpener.shared.openJournalAtLaunch() }
        }
        #if DEBUG
        MainActor.assumeIsolated { IntentSelfTest.runIfAsked() }
        #endif
        let showsWelcome = !UserDefaults.standard.bool(forKey: WelcomeView.shownKey) && !CommandLine.arguments.contains("-skipWelcome")
        if UserDefaults.standard.bool(forKey: "forceAgentSplash") {
            // `-forceAgentSplash YES` (series rule): Agent Access at launch whatever else applies,
            // e.g. to audit it with axaudit.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                MainActor.assumeIsolated { DocumentOpener.shared.showAgentSplash() }
            }
        } else if launchedForSibling {
            // Only the handed-over file: no Welcome, Agent Access or Open panel.
        } else if showsWelcome {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                MainActor.assumeIsolated { DocumentOpener.shared.showWelcomeWindow() }
            }
        } else if UserDefaults.standard.object(forKey: AgentSplashView.showAtLaunchKey) as? Bool ?? true,
                  !CommandLine.arguments.contains("-uiTestingNewDocument"), !CommandLine.arguments.contains("-skipAgentSplash") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                MainActor.assumeIsolated { DocumentOpener.shared.showAgentSplash() }
            }
        } else if deferredURLs.isEmpty, !CommandLine.arguments.contains("-uiTestingNewDocument") {
            // Nothing else to show and no windows restored: offer Glimmer's own Open panel
            // (images too), not the system's document panel that only accepts .glimmer files.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                MainActor.assumeIsolated {
                    if !NSApp.windows.contains(where: { $0.isVisible && $0.level == .normal && !($0 is NSPanel) }) {
                        DocumentOpener.shared.showOpenPanel()
                    }
                }
            }
        }
        guard !deferredURLs.isEmpty else { return }
        let urls = deferredURLs, requester = deferredRequester
        deferredURLs = []
        deferredRequester = nil
        // Let window restoration finish first: restored untitled documents also go
        // through `makeDocument` and would otherwise pick up the queued state.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            MainActor.assumeIsolated { DocumentOpener.shared.open(urls, requester: requester) }
        }
    }

    /// macOS would otherwise show its own Open panel at launch, which only accepts
    /// .glimmer documents; Glimmer shows Welcome, Agent Access or its own panel instead.
    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool { false }

    /// Clicking the Dock icon with no windows open shows Glimmer's Open panel.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { MainActor.assumeIsolated { DocumentOpener.shared.showOpenPanel() } }
        return false
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        // Opens that don't come as an "open documents" event (handleOpenDocuments takes those).
        receive(urls, requester: MainActor.assumeIsolated { DocumentOpener.appleEventRequester() })
    }

    /// Sits ahead of NSDocumentController in the responder chain.
    @objc func openDocument(_ sender: Any?) {
        MainActor.assumeIsolated { DocumentOpener.shared.showOpenPanel() }
    }
}
