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
        do {
            try GlimmerPackage.fileWrapper(for: state, cache: cache).write(to: url, options: .atomic, originalContentsURL: nil)
        } catch {
            // A full disk or a write error: leave nothing half-written behind. The state stays in memory.
            try? FileManager.default.removeItem(at: url)
            throw error
        }
        storage.withLock { $0 = .disk(url, selection: state.selection) }
    }

    /// The most bytes this snapshot can take on disk: its pixel tiles, uncompressed.
    public var diskBytesUpperBound: Int {
        guard case .memory(let state) = storage.withLock({ $0 }) else { return 0 }
        return state.textureTileIDs.count * TileGeometry.byteCount
    }
}

/// What to do with an undo history that has outgrown its memory budget.
public enum UndoSpillPolicy {
    /// Free space Glimmer always leaves on the disk it spills to.
    public static let reserveBytes = 1_073_741_824

    /// Bytes free for Glimmer's use on the volume that holds `url` (nil if it can't be read).
    public static func freeBytes(at url: URL) -> Int? {
        var probe = url
        while !FileManager.default.fileExists(atPath: probe.path), probe.pathComponents.count > 1 { probe.deleteLastPathComponent() }
        let values = try? probe.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey])
        if let v = values?.volumeAvailableCapacityForImportantUsage, v > 0 { return Int(v) }
        return values?.volumeAvailableCapacity
    }

    /// Whether a snapshot of at most `bytes` may be written when `free` bytes are available.
    public static func canSpill(bytes: Int, free: Int?) -> Bool {
        guard let free else { return true }  // unknown: try, and handle the failure
        return free - bytes >= reserveBytes
    }

    /// How many of the oldest applied steps to forget so the steps kept in memory fit `budget`.
    /// `costs` are the applied steps' memory costs, oldest first, 0 for steps already on disk.
    /// The newest applied step is always kept.
    public static func stepsToForget(costs: [Int], budget: Int) -> Int {
        var inMemory = costs.reduce(0, +)
        var forget = 0
        while inMemory > budget, forget < costs.count - 1 {
            inMemory -= costs[forget]
            forget += 1
        }
        return forget
    }
}
