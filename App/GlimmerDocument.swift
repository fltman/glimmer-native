import GlimmerCore
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
    }

    func writer(configuration: sending WriteConfiguration) -> sending FileWrapperDocumentWriter<DocumentState> {
        let cache = encodedLayers
        return FileWrapperDocumentWriter(configuration) { snapshot, _ in
            try GlimmerPackage.fileWrapper(for: snapshot, cache: cache)
        }
    }

    @MainActor
    func snapshot(contentType: UTType) async throws -> sending DocumentState {
        state
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
    private func registerUndo(_ actionName: String, undoManager: UndoManager?, restoring snapshot: DocumentState) {
        guard let undoManager else { return }
        undoManager.registerUndo(withTarget: self) { document in
            let current = document.state
            document.state = snapshot
            document.registerUndo(actionName, undoManager: undoManager, restoring: current)
        }
        undoManager.setActionName(actionName)
    }
}
