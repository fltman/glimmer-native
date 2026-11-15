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
                    if let error { NSApp.presentError(error) }
                }
            } else if url.pathExtension.lowercased() == "aips" {
                openAips(url)
            } else {
                openImage(url, link: requester.flatMap { LinkedImage(url: url, requester: $0) })
            }
        }
    }

    /// Linked images waiting for their window, by the id of the document's first layer.
    private var pendingLinks: [UUID: LinkedImage] = [:]

    /// Called when a document window appears: a handed-over image becomes linked.
    func claimLink(for session: EditorSession) {
        guard let id = session.state.layers.first?.id, let link = pendingLinks.removeValue(forKey: id) else { return }
        session.linkedImage = link
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
        if let sibling = SiblingApp.allCases.first(where: { $0.bundleID == app.bundleIdentifier }) { return sibling.displayName }
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

    private func openImage(_ url: URL, link: LinkedImage? = nil) {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        do {
            let image = try ImageImporter.image(contentsOf: url)
            let name = url.deletingPathExtension().lastPathComponent
            // An empty, untouched document (the one Glimmer opens at launch) becomes the image,
            // instead of leaving a blank window behind.
            if let blank = AgentRegistry.shared.sessions.first(where: \.isUntouchedBlank) {
                try blank.place(image, name: name)
                blank.linkedImage = link
                if let link {
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
            NSApp.presentError(error)
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
            NSApp.presentError(error)
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

    func applicationDidFinishLaunching(_ notification: Notification) {
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
