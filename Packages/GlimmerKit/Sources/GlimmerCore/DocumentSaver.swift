import Foundation

/// Why a document couldn't be saved, in words for the person saving it.
public enum DocumentSaveError: LocalizedError, Equatable {
    /// The disk has `free` bytes and the document needs `needed`.
    case diskFull(needed: Int, free: Int, volume: String)

    public var errorDescription: String? {
        switch self {
        case .diskFull(let needed, let free, let volume):
            let f = ByteCountFormatter()
            f.countStyle = .file
            return "There isn't enough room on “\(volume)” to save this document: it needs \(f.string(fromByteCount: Int64(needed))) and \(f.string(fromByteCount: Int64(max(free, 0)))) is free."
        }
    }

    public var recoverySuggestion: String? {
        "The document is still open and nothing was lost. Free up space or save it on another disk."
    }
}

/// Writes a document package so that a failure never leaves half a document: free space is
/// checked first, the package is written beside its destination and moved into place, and
/// an earlier saved version stays as it was when the write fails.
public enum DocumentSaver {
    /// Room left over on top of the document itself (file system overhead, the temporary copy's metadata).
    static let margin = 2 * 1_048_576

    /// The bytes of every file in `wrapper`.
    public static func byteCount(of wrapper: FileWrapper) -> Int {
        if wrapper.isDirectory { return (wrapper.fileWrappers ?? [:]).values.reduce(0) { $0 + byteCount(of: $1) } }
        return wrapper.regularFileContents?.count ?? 0
    }

    /// Removes `destination` when it is an empty folder: the system creates the package's
    /// folder before the document is written, and an empty one left behind after a failed
    /// save looks like a saved document that can't be opened.
    static func removeIfEmpty(_ destination: URL) {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: destination.path, isDirectory: &isDirectory), isDirectory.boolValue,
              let contents = try? FileManager.default.contentsOfDirectory(atPath: destination.path), contents.isEmpty else { return }
        try? FileManager.default.removeItem(at: destination)
    }

    public static func write(_ wrapper: FileWrapper, to destination: URL) throws {
        do {
            try writeChecked(wrapper, to: destination)
        } catch {
            removeIfEmpty(destination)
            throw error
        }
    }

    private static func writeChecked(_ wrapper: FileWrapper, to destination: URL) throws {
        let needed = byteCount(of: wrapper) + margin
        let volume = (try? destination.deletingLastPathComponent().resourceValues(forKeys: [.volumeNameKey]))?.volumeName ?? "the disk"
        if let free = UndoSpillPolicy.freeBytes(at: destination.deletingLastPathComponent()), free < needed {
            throw DocumentSaveError.diskFull(needed: needed, free: free, volume: volume)
        }
        let existed = FileManager.default.fileExists(atPath: destination.path)
        do {
            try wrapper.write(to: destination, options: .atomic, originalContentsURL: nil)
        } catch {
            // Nothing half-written may stay behind, where it would look like a saved document.
            if !existed { try? FileManager.default.removeItem(at: destination) }
            let ns = error as NSError
            let outOfSpace = (ns.domain == NSCocoaErrorDomain && ns.code == NSFileWriteOutOfSpaceError)
                || (ns.domain == NSPOSIXErrorDomain && ns.code == Int(ENOSPC))
                || ((ns.userInfo[NSUnderlyingErrorKey] as? NSError).map { $0.domain == NSPOSIXErrorDomain && $0.code == Int(ENOSPC) } ?? false)
            if outOfSpace {
                throw DocumentSaveError.diskFull(needed: needed, free: UndoSpillPolicy.freeBytes(at: destination.deletingLastPathComponent()) ?? 0, volume: volume)
            }
            throw error
        }
    }
}
