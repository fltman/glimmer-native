import AppKit
import GlimmerCore
import SwiftUI
import UniformTypeIdentifiers


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
        let window = NSWindow(contentRect: .zero, styleMask: [.titled, .closable, .fullSizeContentView],
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
        let window = NSWindow(contentRect: .zero, styleMask: [.titled, .closable, .fullSizeContentView],
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

    func open(_ urls: [URL]) {
        for url in urls {
            let type = UTType(filenameExtension: url.pathExtension)
            if type?.conforms(to: .glimmerDocument) == true {
                NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { _, _, error in
                    if let error { NSApp.presentError(error) }
                }
            } else if url.pathExtension.lowercased() == "aips" {
                openAips(url)
            } else {
                openImage(url)
            }
        }
    }

    private func openImage(_ url: URL) {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        do {
            let image = try ImageImporter.image(contentsOf: url)
            let name = url.deletingPathExtension().lastPathComponent
            // An empty, untouched document (the one Glimmer opens at launch) becomes the image,
            // instead of leaving a blank window behind.
            if let blank = AgentRegistry.shared.sessions.first(where: \.isUntouchedBlank) {
                try blank.place(image, name: name)
                NSDocumentController.shared.noteNewRecentDocumentURL(url)
                return
            }
            let tiles = try ImageImporter.tiles(from: image)
            let layer = Layer(name: name, content: .raster(tiles))
            createDocument(DocumentState(width: image.width, height: image.height, layers: [layer]))
            NSDocumentController.shared.noteNewRecentDocumentURL(url)
        } catch {
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

    func applicationWillFinishLaunching(_ notification: Notification) {
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
        let showsWelcome = !UserDefaults.standard.bool(forKey: WelcomeView.shownKey) && !CommandLine.arguments.contains("-skipWelcome")
        if showsWelcome {
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
        let urls = deferredURLs
        deferredURLs = []
        // Let window restoration finish first: restored untitled documents also go
        // through `makeDocument` and would otherwise pick up the queued state.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            MainActor.assumeIsolated { DocumentOpener.shared.open(urls) }
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
        guard didFinishLaunching else {
            deferredURLs += urls
            return
        }
        MainActor.assumeIsolated { DocumentOpener.shared.open(urls) }
    }

    /// Sits ahead of NSDocumentController in the responder chain.
    @objc func openDocument(_ sender: Any?) {
        MainActor.assumeIsolated { DocumentOpener.shared.showOpenPanel() }
    }
}
