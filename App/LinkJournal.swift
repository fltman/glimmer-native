import AppKit
import GlimmerCore
import OSLog

private let journalLog = Logger(subsystem: "com.brattoo.glimmer", category: "link-journal")

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

    nonisolated static let workCopyName = LinkJournalWriter.workCopyName
    nonisolated static let recordName = LinkJournalWriter.recordName

    /// Nil when the journal is switched off (`-linkJournal NONE`: test copies that must not open another run's leftovers).
    let folder: URL?
    /// Entry folders that could not be read at the last look. They are left where they are, never deleted by the app.
    private(set) var broken: [String] = []

    private var writers: [String: LinkJournalWriter] = [:]
    private var waiting: [String: (record: LinkJournalRecord, state: DocumentState?)] = [:]
    private var busy: Set<String> = []
    /// The last write of each entry: bytes on disk, bytes written by that step, milliseconds (for `GET /status` and measuring).
    private(set) var lastWrite: [String: LinkJournalWriter.Outcome] = [:]
    /// Entries whose last write did not fit on the disk, with how much was needed and how much was free.
    /// What was kept before is still whole; the steps since are only in the window.
    private(set) var noRoom: [String: (needed: Int, free: Int)] = [:]
    /// Called when an entry's write did not fit, and again (with nil) when a later one did.
    var onRoom: ((_ id: String, _ trouble: (needed: Int, free: Int)?) -> Void)?
    #if DEBUG
    /// One shot, for the restart test: the next state write stops the process at this point (`POST /debug/journal-stop`).
    var stopNextWriteAt: LinkJournalWriter.StopPoint?
    #endif

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
                  let record = try? LinkJournalRecord.decoder.decode(LinkJournalRecord.self, from: data), record.id == name,
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
        let writer = writers[record.id] ?? LinkJournalWriter(folder: folder.appending(path: record.id, directoryHint: .isDirectory),
                                                             cache: EncodedLayerCache(byteLimit: Int(ProcessInfo.processInfo.physicalMemory / 16)))
        writers[record.id] = writer
        let id = record.id
        #if DEBUG
        let stopAt = state == nil ? nil : stopNextWriteAt
        if stopAt != nil { stopNextWriteAt = nil }
        #endif
        Task { [weak self] in
            #if DEBUG
            if let stopAt { await writer.stopNextWrite(at: stopAt) { kill(getpid(), SIGKILL); throw LinkJournalWriter.Stopped() } }
            #endif
            while let next = await self?.takeWaiting(id) {
                do {
                    let outcome = try await writer.write(record: next.record, state: next.state)
                    await self?.noteWritten(id, outcome)
                } catch LinkJournalWriter.Failure.noRoom(let needed, let free) {
                    journalLog.error("no room for journal entry \(id, privacy: .public): \(needed) needed, \(free) free")
                    await self?.noteNoRoom(id, needed: needed, free: free)
                } catch {
                    journalLog.error("couldn't write journal entry \(id, privacy: .public): \(error.localizedDescription, privacy: .public)")
                }
            }
            await self?.finished(id)
        }
    }

    private func takeWaiting(_ id: String) -> (record: LinkJournalRecord, state: DocumentState?)? { waiting.removeValue(forKey: id) }
    private func noteWritten(_ id: String, _ outcome: LinkJournalWriter.Outcome) {
        lastWrite[id] = outcome
        if noRoom.removeValue(forKey: id) != nil { onRoom?(id, nil) }
    }
    private func noteNoRoom(_ id: String, needed: Int, free: Int) {
        noRoom[id] = (needed, free)
        onRoom?(id, (needed, free))
    }
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

    /// For `GET /api/v1/status`: how many entries are kept, how many wait with edits not saved back, and which can't be read.
    var summary: [String: Any] {
        let all = entries()
        var d: [String: Any] = ["entries": all.count, "unreturned": all.filter(\.record.unreturned).count, "broken": broken]
        if !noRoom.isEmpty { d["noRoom"] = noRoom.keys.sorted() }
        if let last = lastWrite.values.max(by: { $0.at < $1.at }) {
            d["lastWrite"] = ["bytes": last.bytes, "bytesWritten": last.bytesWritten, "filesWritten": last.filesWritten, "milliseconds": (last.milliseconds * 10).rounded() / 10]
        }
        return d
    }
}
