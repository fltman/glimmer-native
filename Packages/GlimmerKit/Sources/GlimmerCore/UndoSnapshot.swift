import Foundation
import Synchronization

/// A document state kept for undo. It starts in memory and can be moved to a
/// package on disk when the history outgrows its memory budget; it loads back
/// when the step is undone. The file is removed when the snapshot is released.
public final class UndoSnapshot: Sendable {
    private enum Storage {
        case memory(DocumentState)
        /// The selection isn't part of the document format, so it stays in memory.
        case disk(URL, selection: Selection?)
    }

    private let storage: Mutex<Storage>

    public init(_ state: DocumentState) {
        storage = Mutex(.memory(state))
    }

    deinit {
        if case .disk(let url, _) = storage.withLock({ $0 }) { try? FileManager.default.removeItem(at: url) }
    }

    public var isOnDisk: Bool {
        storage.withLock { if case .disk = $0 { true } else { false } }
    }

    /// The state, read back from disk if it was moved there.
    public func state() throws -> DocumentState {
        switch storage.withLock({ $0 }) {
        case .memory(let state):
            return state
        case .disk(let url, let selection):
            var state = try GlimmerPackage.state(from: FileWrapper(url: url))
            state.selection = selection
            return state
        }
    }

    /// Writes the state to `directory` and releases the in-memory copy. Safe to
    /// call from a background task; does nothing when already on disk.
    public func moveToDisk(in directory: URL, cache: EncodedLayerCache? = nil) throws {
        guard case .memory(let state) = storage.withLock({ $0 }) else { return }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: UUID().uuidString + ".glimmer")
        try GlimmerPackage.fileWrapper(for: state, cache: cache).write(to: url, options: .atomic, originalContentsURL: nil)
        storage.withLock { $0 = .disk(url, selection: state.selection) }
    }
}
