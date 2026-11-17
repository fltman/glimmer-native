import Foundation

/// What the link journal keeps about one linked document, beside its work copy (the-apps/SIBLINGS.md §6.6).
public struct LinkJournalRecord: Codable, Equatable, Sendable {
    public var id: String
    /// The file of the sibling app: security-scoped bookmark, path, requester.
    public var link: DocumentLink
    public var fileName: String
    /// Edits were made that have not been saved back into the file.
    public var unreturned: Bool
    /// How many steps wait to be saved back (said in the close question and in the waiting list).
    public var unreturnedSteps: Int?
    /// Written at Quit, or when the window was closed with Keep for Later: the person left it knowingly. Without it,
    /// an entry with edits waiting was left by a stop (a crash, a kill, the power).
    public var keptKnowingly: Bool?
    public var linkedAt: Date
    public var writtenAt: Date

    public init(id: String, link: DocumentLink, fileName: String, unreturned: Bool, unreturnedSteps: Int? = nil,
                keptKnowingly: Bool? = nil, linkedAt: Date, writtenAt: Date) {
        self.id = id; self.link = link; self.fileName = fileName; self.unreturned = unreturned
        self.unreturnedSteps = unreturnedSteps; self.keptKnowingly = keptKnowingly; self.linkedAt = linkedAt; self.writtenAt = writtenAt
    }

    public static let decoder: JSONDecoder = { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }()
    public static let encoder: JSONEncoder = { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; e.outputFormatting = [.sortedKeys]; return e }()
}

/// Writes one journal entry: `record.json` and the layered work copy `work.glimmer`, in the entry's folder.
///
/// **An entry on disk is always a whole one: the state before a step or the state after it, never a mix.**
/// The new work copy is built beside the old one (`work.next.glimmer`): files the step did not change are
/// hard links to the old copy's files (they cost no room and no time), the changed ones are written, and
/// then the new copy takes the old one's place in one move. A stop at any point before that move leaves the
/// old copy as it was; a stop after it leaves the new one. What was left of an unfinished build is removed
/// by the next write.
///
/// The record is written before the work copy when it says that something waits (so a stop never leaves
/// waiting work marked as nothing waiting) and again after it.
///
/// Room is looked for before anything is written and again before each changed file: when the step will not
/// fit, nothing of the entry is touched and `Failure.noRoom` says how much was needed.
public actor LinkJournalWriter {
    public static let workCopyName = "work.glimmer"
    public static let recordName = "record.json"
    static let stagingName = "work.next.glimmer"
    /// Room left over on the volume after a write.
    static let reserve = 2 * 1_048_576

    public struct Outcome: Sendable {
        /// The whole entry on disk.
        public var bytes: Int
        /// What this write put there (files the step did not change cost nothing).
        public var bytesWritten: Int
        public var filesWritten: Int
        public var milliseconds: Double
        public var at: Date
    }

    public enum Failure: LocalizedError, Equatable {
        /// The step needs `needed` bytes and the volume has `free`.
        case noRoom(needed: Int, free: Int)
        public var errorDescription: String? {
            switch self {
            case .noRoom(let needed, let free):
                let f = ByteCountFormatter(); f.countStyle = .file
                return "There isn't enough room to keep these edits: \(f.string(fromByteCount: Int64(needed))) is needed and \(f.string(fromByteCount: Int64(max(free, 0)))) is free."
            }
        }
    }

    /// Where a test stops a write, to show what is on disk at that moment (debug builds stop the process there).
    public enum StopPoint: Equatable, Sendable {
        /// After this many of the step's changed files have been written into the new copy.
        case afterFiles(Int)
        /// With the new copy complete, before it takes the old one's place.
        case beforeSwap
        /// With the new copy in place, before the record is written again.
        case beforeRecord
    }
    public struct Stopped: Error { public init() {} }

    private let folder: URL
    private let cache: EncodedLayerCache
    /// The bytes of each file of the work copy as it is on disk now, by its path inside the package.
    private var written: [String: Data] = [:]
    private var loaded = false
    private var stopPoint: StopPoint?
    private var stop: (@Sendable () throws -> Void)?

    public init(folder: URL, cache: EncodedLayerCache? = nil) {
        self.folder = folder
        self.cache = cache ?? EncodedLayerCache()
    }

    /// Arms a stop for the next write that reaches `point` (once). `stop` throws, or never returns.
    public func stopNextWrite(at point: StopPoint, _ stop: @escaping @Sendable () throws -> Void = { throw Stopped() }) {
        stopPoint = point
        self.stop = stop
    }

    private func reached(_ point: StopPoint) throws {
        guard stopPoint == point, let stop else { return }
        stopPoint = nil
        self.stop = nil
        try stop()
    }

    public func write(record: LinkJournalRecord, state: DocumentState?) throws -> Outcome {
        let start = Date()
        let fm = FileManager.default
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let package = folder.appending(path: Self.workCopyName, directoryHint: .isDirectory)
        let staging = folder.appending(path: Self.stagingName, directoryHint: .isDirectory)
        var record = record
        record.writtenAt = Date()
        func writeRecord() throws -> Int {
            let data = try LinkJournalRecord.encoder.encode(record)
            try data.write(to: folder.appending(path: Self.recordName), options: .atomic)
            return data.count
        }
        var bytesWritten = 0, filesWritten = 0
        if var state {
            state.link = nil   // the record holds the link
            // No thumbnail or preview: the work copy is read by Glimmer only, and making them would cost more than the step.
            let wrapper = try GlimmerPackage.fileWrapper(for: state, cache: cache, quickLook: nil)
            var files: [String: Data] = [:]
            Self.collect(wrapper, under: "", into: &files)
            // After a relaunch: what is on disk is what was written, so the first step does not write every layer again.
            if !loaded {
                loaded = true
                for path in files.keys {
                    if let data = try? Data(contentsOf: package.appending(path: path), options: .alwaysMapped) { written[path] = data }
                }
            }
            let changed = files.filter { written[$0.key] != $0.value }.sorted { $0.key < $1.key }
            if !changed.isEmpty || files.count != written.count {
                var needed = changed.reduce(0) { $0 + $1.value.count }
                func room() throws {
                    if let free = UndoSpillPolicy.freeBytes(at: folder), free - needed < Self.reserve { throw Failure.noRoom(needed: needed, free: free) }
                }
                try room()
                // Something waits: said first, so that a stop from here on never leaves it marked as nothing waiting.
                if record.unreturned { _ = try writeRecord() }
                try? fm.removeItem(at: staging)   // what an unfinished build left
                try fm.createDirectory(at: staging, withIntermediateDirectories: true)
                do {
                    for (path, data) in files where written[path] == data {
                        let to = staging.appending(path: path)
                        try fm.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
                        do { try fm.linkItem(at: package.appending(path: path), to: to) } catch { try data.write(to: to) }
                    }
                    // The manifest last of the changed files: it is the smallest, and nothing reads the new copy before the move anyway.
                    let manifest = GlimmerPackage.manifestFilename
                    for (path, data) in changed.filter({ $0.key != manifest }) + changed.filter({ $0.key == manifest }) {
                        try room()
                        let to = staging.appending(path: path)
                        try fm.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
                        try data.write(to: to)
                        needed -= data.count
                        bytesWritten += data.count; filesWritten += 1
                        try reached(.afterFiles(filesWritten))
                    }
                    try reached(.beforeSwap)
                    if fm.fileExists(atPath: package.path) {
                        _ = try fm.replaceItemAt(package, withItemAt: staging)
                    } else {
                        try fm.moveItem(at: staging, to: package)
                    }
                } catch {
                    // The old copy is as it was. (After a real stop the unfinished build stays until the next write removes it.)
                    if !(error is Stopped) { try? fm.removeItem(at: staging) }
                    throw error
                }
                written = files
                try reached(.beforeRecord)
            }
        }
        let recordBytes = try writeRecord()
        return Outcome(bytes: written.values.reduce(recordBytes) { $0 + $1.count }, bytesWritten: bytesWritten + recordBytes,
                       filesWritten: filesWritten + 1, milliseconds: Date().timeIntervalSince(start) * 1000, at: Date())
    }

    private static func collect(_ wrapper: FileWrapper, under prefix: String, into files: inout [String: Data]) {
        for (name, child) in wrapper.fileWrappers ?? [:] {
            let path = prefix.isEmpty ? name : prefix + "/" + name
            if child.isDirectory { collect(child, under: path, into: &files) }
            else if let data = child.regularFileContents { files[path] = data }
        }
    }

    /// The bytes an entry's folder holds (for the list of what is waiting). Hard-linked files are counted once each here.
    public static func bytes(of entryFolder: URL) -> Int {
        guard let walk = FileManager.default.enumerator(at: entryFolder, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) else { return 0 }
        var total = 0
        for case let url as URL in walk where !url.path.contains("/" + stagingName + "/") {
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            if values?.isRegularFile == true { total += values?.fileSize ?? 0 }
        }
        return total
    }
}
