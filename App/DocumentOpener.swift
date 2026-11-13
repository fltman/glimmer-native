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

    /// Opens a new untitled document window with `state`.
    func createDocument(_ state: DocumentState) {
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
            let tiles = try ImageImporter.tiles(from: image)
            let layer = Layer(name: url.deletingPathExtension().lastPathComponent, content: .raster(tiles))
            createDocument(DocumentState(width: image.width, height: image.height, layers: [layer]))
            NSDocumentController.shared.noteNewRecentDocumentURL(url)
        } catch {
            NSApp.presentError(error)
        }
    }

    /// File › Open…: `.glimmer` documents and images.
    func showOpenPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.glimmerDocument, .image]
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
    func application(_ application: NSApplication, open urls: [URL]) {
        MainActor.assumeIsolated { DocumentOpener.shared.open(urls) }
    }

    /// Sits ahead of NSDocumentController in the responder chain.
    @objc func openDocument(_ sender: Any?) {
        MainActor.assumeIsolated { DocumentOpener.shared.showOpenPanel() }
    }
}
