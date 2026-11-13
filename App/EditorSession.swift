import AppKit
import GlimmerCore
import GlimmerRender
import GlimmerTools
import SwiftUI
import UniformTypeIdentifiers

/// Per-window editing state: the active tool, transient previews, panels and
/// every user command. Owns the document's undo registration.
@MainActor
@Observable
final class EditorSession {
    let document: GlimmerDocument
    let canvas = CanvasController()

    @ObservationIgnored weak var undoManager: UndoManager?

    var tool: ToolID = .move
    /// Space held: the Hand tool takes over temporarily.
    var temporaryHand = false
    var effectiveTool: ToolID { temporaryHand ? .hand : tool }

    /// Non-undoable preview of an in-progress tool action.
    var overrides = LayerOverrides.none

    var showLayersPanel = true
    var isExportSheetPresented = false
    var exportOptions = ExportOptions()
    var isExporting = false
    var errorMessage: String?

    private(set) var thumbnails: [UUID: CGImage] = [:]

    @ObservationIgnored private let metal = MetalContext.shared
    @ObservationIgnored private lazy var thumbnailRenderer = metal.flatMap { try? ThumbnailRenderer(context: $0) }
    @ObservationIgnored private var thumbnailKeys: [UUID: Int] = [:]
    @ObservationIgnored private var thumbnailTask: Task<Void, Never>?
    @ObservationIgnored private var move: (layer: UUID, start: SIMD2<Double>)?

    init(document: GlimmerDocument) {
        self.document = document
        canvas.documentSize = document.state.size
        observeDocument()
        refreshThumbnails()
    }

    var state: DocumentState { document.state }

    // MARK: Observation

    private func observeDocument() {
        withObservationTracking {
            _ = document.state
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.documentDidChange()
                self.observeDocument()
            }
        }
    }

    private func documentDidChange() {
        canvas.documentSize = state.size
        canvas.requestRender()
        thumbnailTask?.cancel()
        thumbnailTask = Task {
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            refreshThumbnails()
        }
    }

    private func refreshThumbnails() {
        guard let renderer = thumbnailRenderer else { return }
        var next: [UUID: CGImage] = [:]
        var keys: [UUID: Int] = [:]
        for layer in state.layers {
            var hasher = Hasher()
            hasher.combine(layer.tiles.contentSignature)
            hasher.combine(state.bounds)
            let key = hasher.finalize()
            if thumbnailKeys[layer.id] == key, let existing = thumbnails[layer.id] {
                next[layer.id] = existing
            } else if let image = renderer.thumbnail(of: layer.tiles, documentBounds: state.bounds, maxPixels: 96) {
                next[layer.id] = image
            }
            keys[layer.id] = key
        }
        thumbnailKeys = keys
        thumbnails = next
    }

    // MARK: Editing helpers

    private func edit(_ name: String, _ change: (inout DocumentState) throws -> Void) {
        do {
            try document.edit(name, undoManager: undoManager, change)
        } catch {
            report(error)
        }
    }

    func report(_ error: Error) {
        errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }

    // MARK: Commands

    func canPerform(_ id: CommandID) -> Bool {
        let index = state.activeIndex
        switch id {
        case .duplicateLayer, .deleteLayer:
            return index != nil
        case .bringLayerForward, .bringLayerToFront:
            return index.map { $0 < state.layers.count - 1 } ?? false
        case .sendLayerBackward, .sendLayerToBack:
            return index.map { $0 > 0 } ?? false
        case .export:
            return !isExporting
        case .zoomIn, .zoomOut, .fitToWindow, .actualSize, .rotateViewLeft, .rotateViewRight, .resetViewRotation:
            return canvas.canPerform(id)
        default:
            return true
        }
    }

    func perform(_ id: CommandID) {
        guard canPerform(id) else { return }
        switch id {
        case .newLayer:
            edit("New Layer") { $0.insertLayerAboveActive(Layer(name: $0.nextLayerName(), content: .raster(TileGrid()))) }
        case .duplicateLayer:
            edit("Duplicate Layer") { $0.duplicateActiveLayer() }
        case .deleteLayer:
            edit("Delete Layer") { $0.deleteActiveLayer() }
        case .bringLayerForward:
            edit("Bring Forward") { $0.moveActiveLayer(by: 1) }
        case .sendLayerBackward:
            edit("Send Backward") { $0.moveActiveLayer(by: -1) }
        case .bringLayerToFront:
            edit("Bring to Front") { $0.moveActiveLayer(by: $0.layers.count) }
        case .sendLayerToBack:
            edit("Send to Back") { $0.moveActiveLayer(by: -$0.layers.count) }
        case .toggleLayersPanel:
            showLayersPanel.toggle()
        case .placeImage:
            choosePlaceImage()
        case .export:
            isExportSheetPresented = true
        default:
            canvas.perform(id)
        }
    }

    // MARK: Layer panel actions

    func setActiveLayer(_ id: UUID?) {
        guard let id, id != state.activeLayerID else { return }
        // Selection is not an undoable edit.
        document.state.activeLayerID = id
    }

    func setVisibility(_ id: UUID, _ visible: Bool) {
        edit(visible ? "Show Layer" : "Hide Layer") { $0.updateLayer(id) { $0.isVisible = visible } }
    }

    func rename(_ id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, state.layers.first(where: { $0.id == id })?.name != trimmed else { return }
        edit("Rename Layer") { $0.updateLayer(id) { $0.name = trimmed } }
    }

    func setBlendMode(_ mode: GlimmerCore.BlendMode) {
        guard let id = state.activeLayerID, state.activeLayer?.blendMode != mode else { return }
        edit("Change Blend Mode") { $0.updateLayer(id) { $0.blendMode = mode } }
    }

    @ObservationIgnored private var opacityEditStart: DocumentState?

    /// Live opacity change during a slider drag; one undo step on release.
    func setOpacity(_ value: Double, editing: Bool) {
        guard let id = state.activeLayerID else { return }
        if editing, opacityEditStart == nil { opacityEditStart = state }
        document.state.updateLayer(id) { $0.opacity = min(max(value, 0), 1) }
        if !editing {
            let before = opacityEditStart ?? state
            opacityEditStart = nil
            document.commitInteractiveEdit("Change Opacity", undoManager: undoManager, before: before)
        }
    }

    func endOpacityEdit() {
        guard let before = opacityEditStart else { return }
        opacityEditStart = nil
        document.commitInteractiveEdit("Change Opacity", undoManager: undoManager, before: before)
    }

    /// Reorders using indices into the top-down list shown in the Layers panel.
    func moveLayers(fromDisplayed source: IndexSet, toDisplayed destination: Int) {
        edit("Reorder Layers") { state in
            var topDown = Array(state.layers.reversed())
            topDown.move(fromOffsets: source, toOffset: destination)
            state.layers = topDown.reversed()
        }
    }

    // MARK: Move tool

    func beginMove(at point: SIMD2<Double>) {
        guard let layer = state.activeLayer, !layer.tiles.isEmpty else { return }
        move = (layer.id, point)
    }

    func updateMove(to point: SIMD2<Double>) {
        guard let move else { return }
        let d = point - move.start
        overrides = LayerOverrides(offsets: [move.layer: SIMD2(Int(d.x.rounded()), Int(d.y.rounded()))])
    }

    func endMove() {
        guard let move else { return }
        let offset = overrides.offsets[move.layer] ?? .zero
        self.move = nil
        commitTranslation(of: move.layer, by: offset, actionName: "Move")
        overrides = .none
    }

    func nudgeActiveLayer(by offset: SIMD2<Int>) {
        guard let id = state.activeLayerID else { return }
        commitTranslation(of: id, by: offset, actionName: "Nudge")
    }

    private func commitTranslation(of id: UUID, by offset: SIMD2<Int>, actionName: String) {
        guard offset != .zero, let metal,
              let layer = state.layers.first(where: { $0.id == id }) else { return }
        do {
            let moved = try TileOperations.translate(layer.tiles, by: offset, context: metal)
            edit(actionName) { $0.updateLayer(id) { $0.tiles = moved } }
        } catch {
            report(error)
        }
    }

    // MARK: Placing images

    func choosePlaceImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = true
        panel.message = "Choose images to place as new layers"
        panel.prompt = "Place"
        panel.begin { [weak self] response in
            guard response == .OK else { return }
            let urls = panel.urls
            Task { @MainActor in self?.place(urls: urls) }
        }
    }

    func place(urls: [URL]) {
        for url in urls {
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            do {
                let image = try ImageImporter.image(contentsOf: url)
                try place(image, name: url.deletingPathExtension().lastPathComponent)
            } catch {
                report(error)
            }
        }
    }

    /// Adds `image` as a new layer centred on the document.
    func place(_ image: CGImage, name: String) throws {
        let origin = SIMD2((state.width - image.width) / 2, (state.height - image.height) / 2)
        let tiles = try ImageImporter.tiles(from: image, origin: origin)
        edit("Place Image") { $0.insertLayerAboveActive(Layer(name: name, content: .raster(tiles))) }
    }

    /// Places images from a pasteboard (files or image data). Returns false if there were none.
    @discardableResult
    func place(from pasteboard: NSPasteboard) -> Bool {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [
            .urlReadingContentsConformToTypes: [UTType.image.identifier],
        ]
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL], !urls.isEmpty {
            place(urls: urls)
            return true
        }
        for type in [NSPasteboard.PasteboardType.png, .tiff, NSPasteboard.PasteboardType(UTType.jpeg.identifier)] {
            if let data = pasteboard.data(forType: type) {
                do {
                    try place(try ImageImporter.image(from: data), name: "Pasted Layer")
                } catch {
                    report(error)
                }
                return true
            }
        }
        return false
    }

    // MARK: Export

    func export(options: ExportOptions) {
        guard let metal else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [options.format.contentType]
        panel.nameFieldStringValue = "Untitled.\(options.format.contentType.preferredFilenameExtension ?? "png")"
        panel.canCreateDirectories = true
        let snapshot = state
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in
                guard let self else { return }
                self.isExporting = true
                defer { self.isExporting = false }
                do {
                    try await Task.detached(priority: .userInitiated) {
                        try ImageExporter.export(snapshot, options: options, to: url, context: metal)
                    }.value
                } catch {
                    self.report(error)
                }
            }
        }
    }
}

extension FocusedValues {
    @Entry var editorSession: EditorSession?
}
