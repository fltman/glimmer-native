import GlimmerCore
import GlimmerRender
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

/// A `.glimmer` document. Images are imported into new documents by
/// `DocumentOpener`, never opened in place (autosave would overwrite them).
///
/// Every edit goes through `edit(_:undoManager:_:)`. SwiftUI uses the undo
/// stack to detect unsaved changes, so autosave depends on it.
@Observable
final class GlimmerDocument: Document {
    static let readableContentTypes: [UTType] = [.glimmerDocument]
    static let writableContentTypes: [UTType] = [.glimmerDocument]

    var state: DocumentState

    @ObservationIgnored let encodedLayers = EncodedLayerCache()

    /// Names of the undoable steps since the document was opened (History panel),
    /// and how many of them are applied (the rest can be redone).
    private(set) var history: [String] = []
    private(set) var historyIndex = 0

    static let historyLimitKey = "history.limit"
    static var historyLimit: Int {
        let v = UserDefaults.standard.integer(forKey: historyLimitKey)
        return v > 0 ? v : 100
    }

    /// A state handed over by `DocumentOpener`. If SwiftUI turns out to be
    /// restoring or opening a file with this instance (`apply` gets called),
    /// the state is passed on to a fresh document instead of being lost.
    @ObservationIgnored var queuedState: DocumentState?

    /// While set, edits don't register their own undo steps; `endTransaction`
    /// registers one step for all of them (an assistant plan undoes as a whole).
    @ObservationIgnored private var transaction: (name: String, before: DocumentState, changed: Bool)?

    init(state: DocumentState = .new(width: 1920, height: 1080, background: .white)) {
        self.state = state
    }

    // MARK: Reading and writing

    func reader(configuration: sending ReadConfiguration) -> sending FileWrapperDocumentReader<DocumentState> {
        FileWrapperDocumentReader(configuration) { wrapper in
            try GlimmerPackage.state(from: wrapper)
        }
    }

    @MainActor
    func apply(snapshot: sending DocumentState, previous: sending DocumentState?) async throws {
        state = snapshot
        if let handedOver = queuedState {
            queuedState = nil
            DocumentOpener.shared.createDocument(handedOver)
        }
    }

    func writer(configuration: sending WriteConfiguration) -> sending FileWrapperDocumentWriter<DocumentState> {
        let cache = encodedLayers
        return FileWrapperDocumentWriter(configuration) { snapshot, _ in
            try GlimmerPackage.fileWrapper(for: snapshot, cache: cache, quickLook: Self.quickLookImages(snapshot))
        }
    }

    @MainActor
    func snapshot(contentType: UTType) async throws -> sending DocumentState {
        state
    }

    /// PNG thumbnail (512 px) and preview (1600 px) for Finder and QuickLook.
    nonisolated static func quickLookImages(_ state: DocumentState) -> (thumbnail: Data, preview: Data)? {
        guard let metal = MetalContext.shared, let full = try? ImageExporter.flattenedSRGB(state, context: metal),
              let preview = EditorSession.downscaled(full, maxSide: 1600),
              let thumb = EditorSession.downscaled(preview, maxSide: 512) else { return nil }
        func png(_ image: CGImage) -> Data? {
            let data = NSMutableData()
            guard let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
            CGImageDestinationAddImage(dest, image, nil)
            return CGImageDestinationFinalize(dest) ? data as Data : nil
        }
        guard let t = png(thumb), let p = png(preview) else { return nil }
        return (t, p)
    }

    // MARK: Editing

    /// Applies an undoable change. Snapshots are cheap (tiles are shared), so
    /// undo simply restores the previous state.
    @MainActor
    func edit(_ actionName: String, undoManager: UndoManager?, _ change: (inout DocumentState) throws -> Void) rethrows {
        let before = state
        var after = state
        try change(&after)
        state = after
        registerUndo(actionName, undoManager: undoManager, restoring: before)
    }

    /// Records an undo step for a change that was applied interactively (e.g. a
    /// slider drag), restoring `before`.
    @MainActor
    func commitInteractiveEdit(_ actionName: String, undoManager: UndoManager?, before: DocumentState) {
        registerUndo(actionName, undoManager: undoManager, restoring: before)
    }

    @MainActor
    func beginTransaction(_ actionName: String) {
        guard transaction == nil else { return }
        transaction = (actionName, state, false)
    }

    @MainActor
    func endTransaction(undoManager: UndoManager?) {
        guard let t = transaction else { return }
        transaction = nil
        if t.changed { registerUndo(t.name, undoManager: undoManager, restoring: t.before) }
    }

    var isInTransaction: Bool { transaction != nil }

    @MainActor
    private func registerUndo(_ actionName: String, undoManager: UndoManager?, restoring snapshot: DocumentState) {
        guard let undoManager else { return }
        if transaction != nil, !undoManager.isUndoing, !undoManager.isRedoing {
            transaction?.changed = true
            return
        }
        // Snapshots share tiles, so a step costs only the tiles it changed; the
        // limit keeps long sessions from holding on to every intermediate tile.
        if undoManager.levelsOfUndo != Self.historyLimit { undoManager.levelsOfUndo = Self.historyLimit }
        if undoManager.isUndoing {
            historyIndex = max(historyIndex - 1, 0)
        } else if undoManager.isRedoing {
            historyIndex = min(historyIndex + 1, history.count)
        } else {
            history.removeSubrange(historyIndex...)
            history.append(actionName)
            if history.count > undoManager.levelsOfUndo { history.removeFirst(history.count - undoManager.levelsOfUndo) }
            historyIndex = history.count
        }
        undoManager.registerUndo(withTarget: self) { document in
            let current = document.state
            document.state = snapshot
            document.registerUndo(actionName, undoManager: undoManager, restoring: current)
        }
        // Action names are catalog keys: the Edit menu shows "Undo <localized name>".
        undoManager.setActionName(String(localized: String.LocalizationValue(actionName)))
    }

    /// Steps back or forward to `index` applied steps (History panel clicks).
    @MainActor
    func jumpToHistory(_ index: Int, undoManager: UndoManager?) {
        guard let undoManager else { return }
        while historyIndex > index, undoManager.canUndo { undoManager.undo() }
        while historyIndex < index, undoManager.canRedo { undoManager.redo() }
    }
}
