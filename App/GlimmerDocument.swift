import AppKit
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
    static let readableContentTypes: [UTType] = UTType.glimmerDocumentTypes
    static let writableContentTypes: [UTType] = UTType.glimmerDocumentTypes

    var state: DocumentState

    /// Saving re-encodes only the layers that changed. The cache may use an eighth of the
    /// Mac's memory, so a big document's unchanged layers stay encoded between autosaves.
    @ObservationIgnored let encodedLayers = EncodedLayerCache(byteLimit: Int(ProcessInfo.processInfo.physicalMemory / 8))

    /// Names of the undoable steps since the document was opened (History panel),
    /// and how many of them are applied (the rest can be redone).
    private(set) var history: [String] = []
    private(set) var historyIndex = 0

    static let historyLimitKey = "history.limit"
    static var historyLimit: Int {
        let v = UserDefaults.standard.integer(forKey: historyLimitKey)
        return v > 0 ? v : 100
    }

    /// Memory the undo history may hold on to (MB), on top of the step limit.
    static let historyBudgetKey = "history.memoryBudgetMB"
    static var historyBudgetBytes: Int {
        #if DEBUG
        if let mb = ProcessInfo.processInfo.environment["GLIMMER_HISTORY_BUDGET_MB"].flatMap(Int.init) { return mb * 1_048_576 }
        #endif
        let v = UserDefaults.standard.integer(forKey: historyBudgetKey)
        return (v > 0 ? v : 2048) * 1_048_576
    }

    /// Bytes each applied step keeps alive: the tiles it replaced (index-aligned with `history`).
    private(set) var stepCosts: [Int] = []
    var historyBytes: Int { stepCosts.prefix(historyIndex).reduce(0, +) }

    /// The snapshot each step restores when undone (index-aligned with `history`).
    /// Older ones move to disk when the history outgrows its memory budget.
    @ObservationIgnored private var snapshots: [UndoSnapshot] = []
    @ObservationIgnored private var spilling: Set<ObjectIdentifier> = []
    @ObservationIgnored private let spillCache = EncodedLayerCache()
    @ObservationIgnored private let spillDirectory =
        FileManager.default.temporaryDirectory.appending(path: UndoSpillStore.folderName())
    /// How many undo steps currently live on disk (shown in the History panel).
    private(set) var stepsOnDisk = 0
    /// Set when the disk was too full to keep the whole undo history: what happened, for the user.
    /// The window shows it once and clears it.
    var diskNotice: String?
    @ObservationIgnored private var saidDiskIsLow = false
    @ObservationIgnored private var saidDocumentIsLarge = false

    /// Says once, without stopping anything, that the document has outgrown this Mac's memory.
    @MainActor
    func noteSize() {
        guard !saidDocumentIsLarge, let notice = DocumentLimits.comfortNotice(textureTiles: state.textureTileIDs.count) else { return }
        saidDocumentIsLarge = true
        diskNotice = notice
    }
    @ObservationIgnored private weak var historyUndoManager: UndoManager?

    deinit {
        try? FileManager.default.removeItem(at: spillDirectory)
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
        noteSize()
        if let handedOver = queuedState {
            queuedState = nil
            DocumentOpener.shared.createDocument(handedOver)
        }
    }

    /// Writes the package itself (instead of handing a file wrapper to SwiftUI) so that a full
    /// disk is noticed before anything is written, nothing half-written is left behind, and
    /// the person is told: a save that fails silently looks like a save that worked.
    struct PackageWriter: DocumentWriter {
        let cache: EncodedLayerCache

        @concurrent
        func write(snapshot: sending DocumentState, to destination: URL, previous: sending DocumentState?,
                   progress: consuming Subprogress) async throws {
            // The destination is a temporary copy that the system moves into place; its name is the document's.
            let name = destination.lastPathComponent
            do {
                let wrapper = try GlimmerPackage.fileWrapper(for: snapshot, cache: cache, quickLook: GlimmerDocument.quickLookImages(snapshot))
                // The empty folder the system made for the document must go when the write fails:
                // left in place, the system takes the save for done and installs an empty document.
                try DocumentSaver.write(wrapper, to: destination)
                // Never wait for the main thread here: for some saves the system blocks it
                // until this function returns, and waiting would lock the app up.
                Task { @MainActor in SaveFailures.shared.saved(name) }
            } catch {
                let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                let advice = (error as? LocalizedError)?.recoverySuggestion
                Task { @MainActor in SaveFailures.shared.failed(message, advice: advice, saving: name) }
                throw error
            }
        }
    }

    func writer(configuration: sending WriteConfiguration) -> sending PackageWriter {
        PackageWriter(cache: encodedLayers)
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
    /// `separateStep`: for changes made outside a user event (an AI job finishing, the agent
    /// API), which must be undo steps of their own (`UndoManager.separateStep`).
    @MainActor
    func edit(_ actionName: String, undoManager: UndoManager?, separateStep: Bool = false,
              _ change: (inout DocumentState) throws -> Void) rethrows {
        let before = state
        var after = state
        try change(&after)
        state = after
        if separateStep, let undoManager {
            undoManager.separateStep { registerUndo(actionName, undoManager: undoManager, restoring: before) }
        } else {
            registerUndo(actionName, undoManager: undoManager, restoring: before)
        }
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

    /// Transactions (agent steps, assistant plans, saved actions) end outside a user event, so
    /// each is an undo step of its own; otherwise quick requests merged into one.
    @MainActor
    func endTransaction(undoManager: UndoManager?) {
        guard let t = transaction else { return }
        transaction = nil
        guard t.changed else { return }
        if let undoManager {
            undoManager.separateStep { registerUndo(t.name, undoManager: undoManager, restoring: t.before) }
        }
    }

    var isInTransaction: Bool { transaction != nil }

    @MainActor
    private func registerUndo(_ actionName: String, undoManager: UndoManager?, restoring snapshot: DocumentState) {
        guard let undoManager else { return }
        if transaction != nil, !undoManager.isUndoing, !undoManager.isRedoing {
            transaction?.changed = true
            return
        }
        historyUndoManager = undoManager
        // Snapshots share tiles, so a step costs only the tiles it changed.
        let box = UndoSnapshot(snapshot)
        if undoManager.isUndoing {
            // `box` is the redo snapshot; the undo stack below it is unchanged.
            historyIndex = max(historyIndex - 1, 0)
        } else if undoManager.isRedoing {
            if historyIndex < snapshots.count {
                snapshots[historyIndex] = box
                stepCosts[historyIndex] = Self.cost(of: snapshot, comparedTo: state)
            }
            historyIndex = min(historyIndex + 1, history.count)
        } else {
            history.removeSubrange(historyIndex...)
            stepCosts.removeSubrange(min(historyIndex, stepCosts.count)...)
            snapshots.removeSubrange(min(historyIndex, snapshots.count)...)
            history.append(actionName)
            stepCosts.append(Self.cost(of: snapshot, comparedTo: state))
            snapshots.append(box)
            let keep = Self.historyLimit
            if undoManager.levelsOfUndo != keep { undoManager.levelsOfUndo = keep }
            if history.count > keep {
                let extra = history.count - keep
                history.removeFirst(extra)
                stepCosts.removeFirst(extra)
                snapshots.removeFirst(extra)
            }
            historyIndex = history.count
        }
        spillIfNeeded()
        noteSize()
        undoManager.registerUndo(withTarget: self) { document in
            let current = document.state
            // A snapshot that can't be read back leaves the document as it is.
            if let restored = try? box.state() { document.state = restored } else { NSSound.beep() }
            document.registerUndo(actionName, undoManager: undoManager, restoring: current)
        }
        // Action names are catalog keys: the Edit menu shows "Undo <localized name>".
        undoManager.setActionName(String(localized: String.LocalizationValue(actionName)))
    }

    /// Moves the oldest in-memory snapshots to disk until the rest fit the memory budget.
    @MainActor
    private func spillIfNeeded() {
        var inMemory = 0
        for (i, box) in snapshots.enumerated() where !box.isOnDisk && !spilling.contains(ObjectIdentifier(box)) {
            inMemory += stepCosts[i]
        }
        var index = 0
        // Space already promised to snapshots that are being written.
        var promised = snapshots.filter { spilling.contains(ObjectIdentifier($0)) }.reduce(0) { $0 + $1.diskBytesUpperBound }
        // The newest step always stays in memory, whatever it costs.
        while inMemory > Self.historyBudgetBytes, index < snapshots.count - 1 {
            let box = snapshots[index]
            if !box.isOnDisk, !spilling.contains(ObjectIdentifier(box)) {
                // Never fill the disk with undo steps: when there isn't room, forget the oldest instead.
                let bytes = box.diskBytesUpperBound
                guard UndoSpillPolicy.canSpill(bytes: bytes + promised, free: UndoSpillPolicy.freeBytes(at: spillDirectory)) else {
                    forgetOldestSteps()
                    break
                }
                promised += bytes
                inMemory -= stepCosts[index]
                spilling.insert(ObjectIdentifier(box))
                let directory = spillDirectory, cache = spillCache
                Task { @MainActor [weak self] in
                    let failed = await Task.detached(priority: .utility) { () -> Bool in
                        do { try box.moveToDisk(in: directory, cache: cache); return false } catch { return true }
                    }.value
                    guard let self else { return }
                    self.spilling.remove(ObjectIdentifier(box))
                    self.stepsOnDisk = self.snapshots.count { $0.isOnDisk }
                    // The write failed (the disk filled up meanwhile): the step is still in memory.
                    if failed { self.forgetOldestSteps() }
                }
            }
            index += 1
        }
        stepsOnDisk = snapshots.count { $0.isOnDisk }
    }

    /// The disk has no room for older undo steps: drops the oldest ones until what is kept in
    /// memory fits the budget, and says so once. The document itself is untouched.
    @MainActor
    private func forgetOldestSteps() {
        guard let undoManager = historyUndoManager, !undoManager.isUndoing, !undoManager.isRedoing else { return }
        let applied = min(historyIndex, snapshots.count)
        let costs = (0..<applied).map { snapshots[$0].isOnDisk || spilling.contains(ObjectIdentifier(snapshots[$0])) ? 0 : stepCosts[$0] }
        let forget = UndoSpillPolicy.stepsToForget(costs: costs, budget: Self.historyBudgetBytes)
        guard forget > 0 else { return }
        history.removeFirst(forget)
        stepCosts.removeFirst(forget)
        snapshots.removeFirst(forget)
        historyIndex -= forget
        // The undo manager drops its oldest steps when its limit goes below what it holds.
        undoManager.levelsOfUndo = max(historyIndex, 1)
        stepsOnDisk = snapshots.count { $0.isOnDisk }
        if !saidDiskIsLow {
            saidDiskIsLow = true
            diskNotice = String(localized: "Your disk is almost full, so Glimmer keeps fewer undo steps for this document. The document itself is safe. Free up space to get the full history back for new changes.")
        }
    }

    /// Memory an undo snapshot holds beyond the current state: the texture tiles only it references.
    nonisolated static func cost(of snapshot: DocumentState, comparedTo current: DocumentState) -> Int {
        snapshot.textureTileIDs.subtracting(current.textureTileIDs).count * TileGeometry.byteCount
    }

    /// Steps back or forward to `index` applied steps (History panel clicks).
    @MainActor
    func jumpToHistory(_ index: Int, undoManager: UndoManager?) {
        guard let undoManager else { return }
        while historyIndex > index, undoManager.canUndo { undoManager.undo() }
        while historyIndex < index, undoManager.canRedo { undoManager.redo() }
    }
}
