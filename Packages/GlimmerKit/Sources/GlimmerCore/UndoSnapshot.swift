import CryptoKit
import Foundation
import Synchronization

/// A document state kept for undo. It starts in memory and can be moved to a
/// package on disk when the history outgrows its memory budget; it loads back
/// when the step is undone. The file is removed when the snapshot is released.
public final class UndoSnapshot: Sendable {
    private enum Storage {
        case memory(DocumentState)
        /// The selection isn't part of the document format, so it stays in memory.
        /// `blobs` are the shared layer files this snapshot links to (see `UndoSpillStore`).
        case disk(URL, selection: Selection?, blobs: [URL])
    }

    private let storage: Mutex<Storage>

    public init(_ state: DocumentState) {
        storage = Mutex(.memory(state))
    }

    deinit {
        if case .disk(let url, _, let blobs) = storage.withLock({ $0 }) { UndoSpillStore.remove(url, blobs: blobs) }
    }

    public var isOnDisk: Bool {
        storage.withLock { if case .disk = $0 { true } else { false } }
    }

    /// The state, read back from disk if it was moved there.
    public func state() throws -> DocumentState {
        switch storage.withLock({ $0 }) {
        case .memory(let state):
            return state
        case .disk(let url, let selection, _):
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
        // Layer files are written once into the folder's shared store and hard-linked into the
        // snapshot, so steps that share layers share their bytes on disk. A failure (a full disk,
        // a write error) leaves nothing behind, and the state stays in memory.
        let blobs = try UndoSpillStore.write(GlimmerPackage.fileWrapper(for: state, cache: cache), to: url, store: directory)
        storage.withLock { $0 = .disk(url, selection: state.selection, blobs: blobs) }
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

/// Undo snapshots on disk without duplicates.
///
/// A spilled snapshot is a whole document package, and consecutive steps share almost all of
/// their layers. Each layer file is therefore stored once, under the hash of its bytes, in
/// `<folder>/blobs`, and hard-linked into every snapshot package that has it. A blob goes
/// when its last snapshot goes. Packages are written as `<name>.partial` and renamed when
/// complete, so nothing half-written is ever read back.
public enum UndoSpillStore {
    public enum SpillError: Error, Equatable {
        /// The store and the snapshot aren't on the same volume (hard links can't cross volumes).
        case differentVolume
        case cannotLink(Int32)
    }

    /// One writer or remover at a time (per process; a spill folder belongs to one process).
    private static let lock = Mutex(())
    /// Files smaller than this (the manifest) are written into the package as they are.
    static let smallFile = 16_384

    static func blobs(in store: URL) -> URL { store.appending(path: "blobs") }

    /// Writes `wrapper` as a package at `url`, sharing its larger files through `store`.
    /// Returns the blobs the package links to.
    public static func write(_ wrapper: FileWrapper, to url: URL, store: URL) throws -> [URL] {
        let fm = FileManager.default
        try fm.createDirectory(at: blobs(in: store), withIntermediateDirectories: true)
        let partial = url.appendingPathExtension("partial")
        try? fm.removeItem(at: partial)
        var linked: [URL] = []
        do {
            try writeTree(wrapper, at: partial, store: store, linked: &linked)
            try fm.moveItem(at: partial, to: url)
        } catch {
            try? fm.removeItem(at: partial)
            lock.withLock { _ in release(linked) }
            throw error
        }
        return linked
    }

    private static func writeTree(_ wrapper: FileWrapper, at url: URL, store: URL, linked: inout [URL]) throws {
        let fm = FileManager.default
        if wrapper.isDirectory {
            try fm.createDirectory(at: url, withIntermediateDirectories: true)
            for (name, child) in wrapper.fileWrappers ?? [:] {
                try writeTree(child, at: url.appending(path: name), store: store, linked: &linked)
            }
            return
        }
        guard let data = wrapper.regularFileContents else { return }
        guard data.count >= smallFile else {
            try data.write(to: url)
            return
        }
        let name = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let blob = blobs(in: store).appending(path: name)
        try lock.withLock { _ in
            for attempt in 0..<2 {
                if !fm.fileExists(atPath: blob.path) {
                    // Written under a temporary name first: a blob with its real name is always whole.
                    let temp = blobs(in: store).appending(path: name + ".tmp-" + UUID().uuidString)
                    do {
                        try data.write(to: temp)
                        try fm.moveItem(at: temp, to: blob)
                    } catch {
                        try? fm.removeItem(at: temp)
                        throw error
                    }
                }
                if link(blob.path, url.path) == 0 { break }
                let code = errno
                if code == ENOENT, attempt == 0 { continue }  // the blob went meanwhile: write it again
                release([blob])  // not linked: don't leave a blob that no step uses
                throw code == EXDEV ? SpillError.differentVolume : SpillError.cannotLink(code)
            }
        }
        linked.append(blob)
    }

    /// How many names a file has (1 for a blob no snapshot links to).
    static func linkCount(_ url: URL) -> Int {
        var info = stat()
        return stat(url.path, &info) == 0 ? Int(info.st_nlink) : 0
    }

    /// Removes the blobs that nothing links to any more. Call with the lock held.
    private static func release(_ blobs: [URL]) {
        for blob in Set(blobs) where linkCount(blob) == 1 { try? FileManager.default.removeItem(at: blob) }
    }

    /// Removes a snapshot package and the blobs only it used.
    public static func remove(_ package: URL, blobs: [URL]) {
        lock.withLock { _ in
            try? FileManager.default.removeItem(at: package)
            release(blobs)
        }
    }

    /// Removes what an interrupted write left in a spill folder: unfinished packages, temporary
    /// blob files, and blobs that no package links to.
    public static func sweep(_ store: URL) {
        let fm = FileManager.default
        lock.withLock { _ in
            for name in (try? fm.contentsOfDirectory(atPath: store.path)) ?? [] where name.hasSuffix(".partial") {
                try? fm.removeItem(at: store.appending(path: name))
            }
            let dir = blobs(in: store)
            for name in (try? fm.contentsOfDirectory(atPath: dir.path)) ?? [] {
                let file = dir.appending(path: name)
                if name.contains(".tmp-") || linkCount(file) == 1 { try? fm.removeItem(at: file) }
            }
        }
    }

    /// The name of a spill folder for this process: `undo-<pid>-<uuid>`.
    public static func folderName(pid: Int32 = ProcessInfo.processInfo.processIdentifier) -> String {
        "undo-\(pid)-\(UUID().uuidString)"
    }

    /// Removes the spill folders of processes that no longer run (the history isn't kept across
    /// launches, so after a crash they are only wasted space). Folders of running processes,
    /// this one included, are left alone. Returns how many were removed.
    @discardableResult
    public static func removeOrphans(in directory: URL, isRunning: (Int32) -> Bool = UndoSpillStore.isRunning) -> Int {
        let fm = FileManager.default
        var removed = 0
        for name in (try? fm.contentsOfDirectory(atPath: directory.path)) ?? [] where name.hasPrefix("undo-") {
            let parts = name.split(separator: "-")
            let url = directory.appending(path: name)
            if parts.count >= 3, let pid = Int32(parts[1]) {
                if isRunning(pid) { continue }
            } else {
                // A folder from before folders carried the process id: only when it is a day old.
                let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                if Date().timeIntervalSince(modified) < 86_400 { continue }
            }
            if (try? fm.removeItem(at: url)) != nil { removed += 1 }
        }
        return removed
    }

    /// Whether a process with this id exists (one we may not signal counts as running).
    public static func isRunning(_ pid: Int32) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }
}
