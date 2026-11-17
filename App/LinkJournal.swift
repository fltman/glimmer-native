import AppKit
import GlimmerCore
import OSLog

private let journalLog = Logger(subsystem: "com.brattoo.glimmer", category: "link-journal")

/// What the journal keeps about one linked document, beside its work copy.
struct LinkJournalRecord: Codable, Equatable, Sendable {
    var id: String
    /// The file of the sibling app: security-scoped bookmark, path, requester.
    var link: DocumentLink
    var fileName: String
    /// Edits were made that have not been saved back into the file.
    var unreturned: Bool
    /// How many steps wait to be saved back (said in the close question and in the waiting list).
    var unreturnedSteps: Int?
    /// Written at Quit, or when the window was closed with Keep for Later: the person left it knowingly. Without it,
    /// an entry with edits waiting was left by a stop (a crash, a kill, the power).
    var keptKnowingly: Bool?
    var linkedAt: Date
    var writtenAt: Date
}

/// Glimmer's own record of linked documents (the-apps/SIBLINGS.md §6.6).
///
/// A linked edit must survive Quit, a crash and a restart whatever the system does with windows:
/// "Close windows when quitting an application" is on by default in macOS, and autosave goes by the
/// clock. So the link and the work are kept here, never only in the system's window state or autosave:
/// one folder per linked document in Application Support/LinkJournal, with `record.json` and the
/// layered work copy `work.glimmer`. It is written when the document is linked and after every step,
/// so a crash costs at most the step in progress.
///
/// A write after a step is cheap for a large document: the work copy is a package with one file per
/// layer, and only the layers the step changed are encoded and written (each beside its place, then
/// moved in). The small manifest goes last, then the record, so an entry on disk is always a whole
/// one: the state before the step or the state after it. Writing happens off the main thread, one
/// writer per entry, and when steps come faster than the disk only the newest state is written.
@MainActor
final class LinkJournal {
    static let shared = LinkJournal()

    struct Entry: Identifiable, Sendable {
        let record: LinkJournalRecord
        let folder: URL
        var id: String { record.id }
        var workCopy: URL { folder.appending(path: LinkJournal.workCopyName) }
    }

    nonisolated static let workCopyName = "work.glimmer"
    nonisolated static let recordName = "record.json"

    /// Nil when the journal is switched off (`-linkJournal NONE`: test copies that must not open another run's leftovers).
    let folder: URL?
    /// Entry folders that could not be read at the last look. They are left where they are, never deleted by the app.
    private(set) var broken: [String] = []

    private var writers: [String: JournalWriter] = [:]
    private var waiting: [String: (record: LinkJournalRecord, state: DocumentState?)] = [:]
    private var busy: Set<String> = []
    /// The last write of each entry: bytes on disk, bytes written by that step, milliseconds (for `GET /status` and measuring).
    private(set) var lastWrite: [String: JournalWriter.Outcome] = [:]

    init() {
        let named = UserDefaults.standard.string(forKey: "linkJournal")
        if named == "NONE" { folder = nil; return }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        folder = support?.appending(path: named.map { "LinkJournal-\($0)" } ?? "LinkJournal", directoryHint: .isDirectory)
    }

    // MARK: Reading

    /// Every entry that can be read, oldest first. Folders that can't are remembered in `broken` and left alone.
    func entries() -> [Entry] {
        guard let folder, let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { broken = []; return [] }
        var found: [Entry] = [], unreadable: [String] = []
        for name in names.sorted() where !name.hasPrefix(".") {
            let entry = folder.appending(path: name, directoryHint: .isDirectory)
            guard let data = try? Data(contentsOf: entry.appending(path: Self.recordName)),
                  let record = try? Self.decoder.decode(LinkJournalRecord.self, from: data), record.id == name,
                  FileManager.default.fileExists(atPath: entry.appending(path: Self.workCopyName).path) else {
                unreadable.append(name)
                continue
            }
            found.append(Entry(record: record, folder: entry))
        }
        if unreadable != broken {
            broken = unreadable
            for name in unreadable { journalLog.error("a journal entry can't be read and is left where it is: \(name, privacy: .public)") }
        }
        return found.sorted { $0.record.linkedAt < $1.record.linkedAt }
    }

    /// An entry whose work copy turned out not to be readable when it was opened.
    func noteUnreadable(_ id: String) { if !broken.contains(id) { broken.append(id) } }

    /// The work copy of an entry, read with care: an entry that can't be read is reported, not removed.
    nonisolated static func state(of entry: Entry) throws -> DocumentState {
        var state = try GlimmerPackage.state(from: FileWrapper(url: entry.workCopy, options: .immediate))
        state.link = nil   // the record holds the link
        return state
    }

    /// The entry that edits `file`, if one is kept (by where its bookmark leads now, or by its path).
    func entry(for file: URL) -> Entry? {
        let wanted = file.resolvingSymlinksInPath().path
        return entries().last { entry in
            if URL(fileURLWithPath: entry.record.link.path).resolvingSymlinksInPath().path == wanted { return true }
            guard let bookmark = entry.record.link.bookmark else { return false }
            var stale = false
            let resolved = try? URL(resolvingBookmarkData: bookmark, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &stale)
            return resolved?.resolvingSymlinksInPath().path == wanted
        }
    }

    // MARK: Writing

    /// Writes the entry: the record, and the work copy when `state` is given. Returns at once; the newest state wins.
    func write(_ record: LinkJournalRecord, state: DocumentState?) {
        guard let folder else { return }
        // A record alone must not push a state that is still waiting out of the queue.
        waiting[record.id] = (record, state ?? waiting[record.id]?.state)
        guard !busy.contains(record.id) else { return }
        busy.insert(record.id)
        let writer = writers[record.id] ?? JournalWriter(folder: folder.appending(path: record.id, directoryHint: .isDirectory))
        writers[record.id] = writer
        let id = record.id
        Task { [weak self] in
            while let next = await self?.takeWaiting(id) {
                do {
                    let outcome = try await writer.write(record: next.record, state: next.state)
                    await self?.noteWritten(id, outcome)
                } catch {
                    journalLog.error("couldn't write journal entry \(id, privacy: .public): \(error.localizedDescription, privacy: .public)")
                }
            }
            await self?.finished(id)
        }
    }

    private func takeWaiting(_ id: String) -> (record: LinkJournalRecord, state: DocumentState?)? { waiting.removeValue(forKey: id) }
    private func noteWritten(_ id: String, _ outcome: JournalWriter.Outcome) { lastWrite[id] = outcome }
    private func finished(_ id: String) {
        busy.remove(id)
        if let again = waiting[id] { write(again.record, state: again.state) }
    }

    /// Whether everything asked for has reached the disk (tests wait for this before a hard stop "after" a step).
    var isIdle: Bool { busy.isEmpty && waiting.isEmpty }

    /// Removes an entry: its edits are saved back and its document closed.
    func remove(_ id: String) {
        guard let folder else { return }
        waiting[id] = nil
        writers[id] = nil
        lastWrite[id] = nil
        let entry = folder.appending(path: id, directoryHint: .isDirectory)
        // After a write that is under way, so a late file does not bring the folder back.
        Task.detached { [busy = busy.contains(id)] in
            if busy { try? await Task.sleep(for: .milliseconds(400)) }
            try? FileManager.default.removeItem(at: entry)
        }
    }

    /// The person declined an entry: its work copy goes to the Trash, not away, and the entry is removed.
    /// Returns false when the work copy could not be moved; then the entry is left as it is.
    @discardableResult
    func discard(_ entry: Entry) -> Bool {
        // In the Trash under a name the person can recognise.
        let named = entry.folder.appending(path: "\((entry.record.fileName as NSString).deletingPathExtension) (edit for \(entry.record.link.requester)).glimmer")
        do {
            try FileManager.default.moveItem(at: entry.workCopy, to: named)
            try FileManager.default.trashItem(at: named, resultingItemURL: nil)
        } catch {
            journalLog.error("couldn't move a declined work copy to the Trash: \(error.localizedDescription, privacy: .public)")
            try? FileManager.default.moveItem(at: named, to: entry.workCopy)
            return false
        }
        remove(entry.id)
        return true
    }

    nonisolated static let decoder: JSONDecoder = { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }()
    nonisolated static let encoder: JSONEncoder = { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; e.outputFormatting = [.sortedKeys]; return e }()

    /// For `GET /api/v1/status`: how many entries are kept, how many wait with edits not saved back, and which can't be read.
    var summary: [String: Any] {
        let all = entries()
        var d: [String: Any] = ["entries": all.count, "unreturned": all.filter(\.record.unreturned).count, "broken": broken]
        if let last = lastWrite.values.max(by: { $0.at < $1.at }) {
            d["lastWrite"] = ["bytes": last.bytes, "bytesWritten": last.bytesWritten, "filesWritten": last.filesWritten, "milliseconds": (last.milliseconds * 10).rounded() / 10]
        }
        return d
    }
}

/// Writes one entry, off the main thread. Remembers what it wrote, so the next step writes only what changed.
actor JournalWriter {
    struct Outcome: Sendable {
        /// The whole entry on disk.
        var bytes: Int
        /// What this write put there.
        var bytesWritten: Int
        var filesWritten: Int
        var milliseconds: Double
        var at: Date
    }

    private let folder: URL
    private let cache = EncodedLayerCache(byteLimit: Int(ProcessInfo.processInfo.physicalMemory / 16))
    /// The bytes last written for each file of the work copy, by its path inside the package.
    private var written: [String: Data] = [:]

    init(folder: URL) { self.folder = folder }

    func write(record: LinkJournalRecord, state: DocumentState?) throws -> Outcome {
        let start = Date()
        let fm = FileManager.default
        let package = folder.appending(path: LinkJournal.workCopyName, directoryHint: .isDirectory)
        try fm.createDirectory(at: package, withIntermediateDirectories: true)
        var bytesWritten = 0, filesWritten = 0
        if var state {
            state.link = nil
            // No thumbnail or preview: the work copy is read by Glimmer only, and making them would cost more than the step.
            let wrapper = try GlimmerPackage.fileWrapper(for: state, cache: cache, quickLook: nil)
            var files: [String: Data] = [:]
            Self.collect(wrapper, under: "", into: &files)
            // Everything but the manifest first: until the manifest changes, the entry is the state before the step.
            let manifest = GlimmerPackage.manifestFilename
            for (path, data) in files.sorted(by: { $0.key < $1.key }) where path != manifest && written[path] != data {
                let url = package.appending(path: path)
                try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: url, options: .atomic)
                written[path] = data
                bytesWritten += data.count; filesWritten += 1
            }
            if let data = files[manifest], written[manifest] != data {
                try data.write(to: package.appending(path: manifest), options: .atomic)
                written[manifest] = data
                bytesWritten += data.count; filesWritten += 1
            }
            // Files of layers that are gone, only now that no manifest names them.
            for path in written.keys where files[path] == nil {
                try? fm.removeItem(at: package.appending(path: path))
                written[path] = nil
            }
        }
        var record = record
        record.writtenAt = Date()
        let data = try LinkJournal.encoder.encode(record)
        try data.write(to: folder.appending(path: LinkJournal.recordName), options: .atomic)
        return Outcome(bytes: written.values.reduce(data.count) { $0 + $1.count }, bytesWritten: bytesWritten + data.count,
                       filesWritten: filesWritten + 1, milliseconds: Date().timeIntervalSince(start) * 1000, at: Date())
    }

    private static func collect(_ wrapper: FileWrapper, under prefix: String, into files: inout [String: Data]) {
        for (name, child) in wrapper.fileWrappers ?? [:] {
            let path = prefix.isEmpty ? name : prefix + "/" + name
            if child.isDirectory { collect(child, under: path, into: &files) }
            else if let data = child.regularFileContents { files[path] = data }
        }
    }
}
