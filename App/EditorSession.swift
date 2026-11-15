import AppKit
import GlimmerAI
import GlimmerCore
import GlimmerRender
import GlimmerTools
import SwiftUI
import simd
import UniformTypeIdentifiers

/// Per-window editing state: the active tool, transient previews, panels and
/// every user command. Owns the document's undo registration.
@MainActor
@Observable
final class EditorSession {
    let document: GlimmerDocument
    let canvas = CanvasController()

    @ObservationIgnored weak var undoManager: UndoManager?

    var tool: ToolID = .move {
        didSet {
            guard oldValue != tool else { return }
            if oldValue == .magicSelect { ai?.resetMagicSelect() }
            if oldValue == .freeTransform { commitTransform() }
            if oldValue == .crop { cropSession = nil }
            if oldValue == .pen { finishPathSegment() }
            if tool == .freeTransform { beginTransform() }
            if tool == .crop { beginCrop() }
        }
    }
    /// Space held: the Hand tool takes over temporarily.
    var temporaryHand = false
    var effectiveTool: ToolID { temporaryHand ? .hand : tool }

    /// Non-undoable preview of an in-progress tool action.
    var overrides = LayerOverrides.none

    enum InspectorTab: String, CaseIterable {
        case layers = "Layers"
        case paths = "Paths"
        case channels = "Channels"
        case history = "History"
        case ai = "AI"
    }

    enum AISection: String {
        case assistant, generate, fill, expand, colorMatch, relight, reflections, harmonize, upscale, cleanup, presets, lensBlur
    }

    var inspectorTab = InspectorTab.layers
    /// The AI panel section to reveal (set by menu commands).
    var aiSection = AISection.assistant
    @ObservationIgnored private(set) var ai: AIController!

    /// The marquee being dragged (document coordinates).
    struct Marquee: Equatable {
        var start: SIMD2<Double>
        var current: SIMD2<Double>
        var ellipse: Bool
        var operation: Selection.Operation
        /// ⌥ while dragging: the press point is the centre.
        var fromCentre = false
        var rect: CGRectLike {
            fromCentre ? CGRectLike(x0: 2 * start.x - current.x, y0: 2 * start.y - current.y, x1: current.x, y1: current.y)
                       : CGRectLike(x0: start.x, y0: start.y, x1: current.x, y1: current.y)
        }
    }
    var marquee: Marquee?

    // MARK: Painting and selection-tool state

    var brush = BrushSettings()
    var foreground = SRGBColor(0, 0, 0)
    var background = SRGBColor(1, 1, 1)
    /// Alpha of the foreground and background colours (the colour wells' opacity).
    var foregroundOpacity = 1.0
    var backgroundOpacity = 1.0
    /// Paint into the active layer's mask instead of its pixels.
    var editingMask = false
    var wandTolerance = 32.0
    var wandContiguous = true
    var sampleAllLayers = true
    var gradientStyle = GradientStyle.linear
    var gradientToTransparent = false
    var gradientReverse = false
    /// Custom stops for the Gradient tool; nil = foreground to background.
    var gradientStops: [GradientStop]?
    /// Feather applied to selections as the marquee, lasso and wand make them (pixels).
    var selectionFeather = 0.0
    /// Tab hides every panel for a clean view of the image.
    var interfaceHidden = false
    /// Lasso being drawn (document points) and whether it's polygonal.
    var lasso: [SIMD2<Double>]?
    var lassoOperation = Selection.Operation.replace
    /// Gradient drag in progress (document points).
    var gradientDrag: (start: SIMD2<Double>, end: SIMD2<Double>)?
    /// Pointer position over the canvas, for the brush cursor (view points).
    var hoverPoint: SIMD2<Double>?
    var selectionDialog: CommandID?

    // Phase 6 tools
    var transformSession: TransformSession?
    var cropSession: CropSession?
    var editingText: UUID?
    var textDefaults: (fontName: String, size: Double, alignment: GlimmerCore.TextAlignment) = ("HelveticaNeue-Bold", 96, .left)
    var activePathID: UUID?
    @ObservationIgnored var penDrag: (Int, Int, Int)?
    var penOpen = false
    var shapeKind = ShapeKind.rectangle
    var shapeLineWidth = 8.0
    /// Crop throws away pixels outside the new canvas (as in the web app and Photoshop).
    static let cropDeletesKey = "crop.deletePixels"
    var cropDeletesPixels = UserDefaults.standard.object(forKey: EditorSession.cropDeletesKey) as? Bool ?? true {
        didSet { UserDefaults.standard.set(cropDeletesPixels, forKey: Self.cropDeletesKey) }
    }
    var shapeCornerRadius = 32.0
    var shapeStrokeWidth = 0.0
    /// Fill of new shapes; nil follows the foreground colour.
    var shapeFillColor: SRGBColor?
    var shapeStrokeColor = SRGBColor(0, 0, 0)
    @ObservationIgnored var originalShapeState: DocumentState?
    var shapeDrag: (start: SIMD2<Double>, end: SIMD2<Double>)?
    var guideDrag: (id: UUID?, axis: Guide.Axis, position: Double)?

    // Phase 7: filters, retouching, liquify, channels
    var filterDialog: FilterSettings?
    var lastFilter: FilterSettings?
    var isPreviewingFilter = false
    @ObservationIgnored var filterEngineCache: FilterEngine?
    @ObservationIgnored var filterPreviewTask: Task<Void, Never>?
    /// While previewing a smart filter: the state to restore on Cancel, and the filter being edited.
    @ObservationIgnored var smartFilterPreviewBase: DocumentState?
    @ObservationIgnored var smartFilterEditIndex: Int?
    var cloneSource: SIMD2<Double>?
    var cloneAligned = true
    @ObservationIgnored var cloneOffset: SIMD2<Double>?
    var retouchStrength = 0.5
    var patternKind = PatternKind.checkerboard
    var patternScale = 32.0
    var dodgeExposure = 0.5
    var dodgeRange = 1
    @ObservationIgnored var smudge: (engine: SmudgeEngine, sampler: StrokeSampler, layer: UUID, last: SIMD2<Double>)?
    var liquify: LiquifySession?
    var liquifyMode = LiquifyEngine.Mode.forward
    var liquifySize = 150.0
    var liquifyPressure = 0.5
    /// Which channels the canvas shows: bits 1 red, 2 green, 4 blue, 8 alpha (15 = the normal view).
    var channelMask = 15
    var isPaletteOpen = false
    var showNavigator = false {
        didSet { if showNavigator { scheduleNavigatorRefresh(delay: 0) } }
    }
    var navigatorImage: CGImage?
    @ObservationIgnored var navigatorTask: Task<Void, Never>?
    /// Histogram of what the Levels layer being edited receives (the layers below it).
    var levelsHistogram: (layerID: UUID, histogram: Histogram)?

    @ObservationIgnored var stroke: (engine: StrokeEngine, sampler: StrokeSampler, layer: UUID, mask: Bool)?
    @ObservationIgnored var lastStrokePoint: SIMD2<Double>?
    @ObservationIgnored var clipboard: (grid: TileGrid, changeCount: Int)?

    /// The floating side panel (layers and friends, or the assistant) and the tool rail.
    var showLayersPanel = false
    var showTools = true
    /// Classic layout docks the panel at the right edge and keeps it open (the web app's "Classic").
    static let classicLayoutKey = "ui.classicLayout"
    var classicLayout = UserDefaults.standard.bool(forKey: EditorSession.classicLayoutKey) {
        didSet { UserDefaults.standard.set(classicLayout, forKey: Self.classicLayoutKey) }
    }
    /// The start card on an untouched blank document can be put away.
    var startCardDismissed = CommandLine.arguments.contains("-uiTestingNewDocument")
    /// The window title (document name), shown in the chip at the top left.
    var documentName = "Untitled"
    var isExportSheetPresented = false
    var isLayerStylePresented = false
    var exportOptions = ExportOptions()
    var isExporting = false
    var errorMessage: String?
    var isBatchSheetPresented = false
    /// A short message shown over the canvas for a few seconds.
    private(set) var toast: String?
    @ObservationIgnored private var toastTask: Task<Void, Never>?

    func showToast(_ message: String) {
        toast = message
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                             userInfo: [.announcement: message, .priority: NSAccessibilityPriorityLevel.high.rawValue])
        toastTask?.cancel()
        toastTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3.5))
            guard !Task.isCancelled else { return }
            self?.toast = nil
        }
    }

    private(set) var thumbnails: [UUID: CGImage] = [:]
    private(set) var maskThumbnails: [UUID: CGImage] = [:]

    @ObservationIgnored let metal = MetalContext.shared
    @ObservationIgnored private lazy var thumbnailRenderer = metal.flatMap { try? ThumbnailRenderer(context: $0) }
    @ObservationIgnored private var thumbnailKeys: [String: Int] = [:]
    @ObservationIgnored private var thumbnailTask: Task<Void, Never>?
    @ObservationIgnored private var move: (layer: UUID, start: SIMD2<Double>, bounds: PixelRect?)?

    init(document: GlimmerDocument) {
        self.document = document
        canvas.documentSize = document.state.size
        ai = AIController(session: self)
        observeDocument()
        refreshThumbnails()
    }

    var state: DocumentState { document.state }
    var activeLayer: Layer? { state.activeLayer }

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
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            refreshThumbnails()
        }
        if showNavigator { scheduleNavigatorRefresh(delay: 400) }
    }

    /// The navigator shows a small flattened preview; it's rebuilt off the main
    /// thread once edits pause (longer pauses for very large documents).
    func scheduleNavigatorRefresh(delay: Int) {
        navigatorTask?.cancel()
        guard let metal else { return }
        let snapshot = state
        let pixels = snapshot.width * snapshot.height
        navigatorTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(delay + (pixels > 36_000_000 ? 1200 : 0)))
            guard !Task.isCancelled else { return }
            let image = await Task.detached(priority: .utility) { () -> CGImage? in
                guard let full = try? ImageExporter.flattenedSRGB(snapshot, context: metal) else { return nil }
                return Self.downscaled(full, maxSide: 480)
            }.value
            guard !Task.isCancelled, let self, let image else { return }
            self.navigatorImage = image
        }
    }

    /// Recomputes `levelsHistogram` for `layerID` off the main thread.
    func refreshLevelsHistogram(for layerID: UUID) async {
        guard let metal else { return }
        let below = state.below(layerID)
        try? await Task.sleep(for: .milliseconds(150))
        guard !Task.isCancelled else { return }
        let histogram = await Task.detached(priority: .utility) { () -> Histogram? in
            guard let full = try? ImageExporter.flattenedSRGB(below, context: metal) else { return nil }
            return Histogram(image: full)
        }.value
        guard !Task.isCancelled, let histogram else { return }
        levelsHistogram = (layerID, histogram)
    }

    nonisolated static func downscaled(_ image: CGImage, maxSide: Int) -> CGImage? {
        let scale = Double(maxSide) / Double(max(image.width, image.height))
        guard scale < 1 else { return image }
        let w = max(1, Int(Double(image.width) * scale)), h = max(1, Int(Double(image.height) * scale))
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }

    private func refreshThumbnails() {
        guard let renderer = thumbnailRenderer else { return }
        var next: [UUID: CGImage] = [:]
        var nextMasks: [UUID: CGImage] = [:]
        var keys: [String: Int] = [:]
        let bounds = state.bounds

        func cached(_ key: String, _ signature: Int, _ old: CGImage?, _ make: () -> CGImage?) -> CGImage? {
            var h = Hasher()
            h.combine(signature)
            h.combine(bounds)
            let k = h.finalize()
            keys[key] = k
            if thumbnailKeys[key] == k, let old { return old }
            return make()
        }

        for layer in state.allLayers {
            let id = layer.id
            switch layer.content {
            case .raster(let grid):
                next[id] = cached("\(id)", grid.contentSignature, thumbnails[id]) {
                    renderer.thumbnail(of: grid, documentBounds: bounds, maxPixels: 96)
                }
            case .smart(let smart):
                let src = PixelRect(x: 0, y: 0, width: smart.width, height: smart.height)
                next[id] = cached("\(id)", smart.source.contentSignature, thumbnails[id]) {
                    renderer.thumbnail(of: smart.source, documentBounds: src, maxPixels: 96)
                }
            default:
                break
            }
            if let mask = layer.mask {
                var h = Hasher()
                h.combine(mask.tiles.contentSignature)
                h.combine(mask.defaultValue)
                nextMasks[id] = cached("\(id).mask", h.finalize(), maskThumbnails[id]) {
                    renderer.thumbnail(of: mask.tiles, documentBounds: bounds, maxPixels: 96, background: mask.defaultValue)
                }
            }
        }
        thumbnailKeys = keys
        thumbnails = next
        maskThumbnails = nextMasks
    }

    // MARK: Editing helpers

    func edit(_ name: String, _ change: (inout DocumentState) throws -> Void) {
        commitLiveEdit()
        do {
            try document.edit(name, undoManager: undoManager, change)
        } catch {
            report(error)
        }
    }

    func report(_ error: Error) {
        errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }

    // MARK: Live edits (sliders, colour wells)

    @ObservationIgnored private var liveEdit: (name: String, before: DocumentState)?
    @ObservationIgnored private var liveEditCommit: Task<Void, Never>?

    /// Applies a change immediately and records one undo step once the control
    /// goes quiet (or `commitLiveEdit()` is called, e.g. when a drag ends).
    func live(_ name: String, _ change: (inout DocumentState) -> Void) {
        if liveEdit == nil || liveEdit?.name != name {
            commitLiveEdit()
            liveEdit = (name, state)
        }
        change(&document.state)
        liveEditCommit?.cancel()
        liveEditCommit = Task {
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            commitLiveEdit()
        }
    }

    func commitLiveEdit() {
        liveEditCommit?.cancel()
        liveEditCommit = nil
        guard let edit = liveEdit else { return }
        liveEdit = nil
        document.commitInteractiveEdit(edit.name, undoManager: undoManager, before: edit.before)
    }

    /// Discards an in-progress live edit (e.g. Cancel in a dialog).
    func revertLiveEdit(to snapshot: DocumentState) {
        liveEditCommit?.cancel()
        liveEdit = nil
        document.state = snapshot
    }

    /// Live change to the active layer.
    func liveLayer(_ name: String, _ change: @escaping (inout Layer) -> Void) {
        guard let id = state.activeLayerID else { return }
        live(name) { $0.updateLayer(id, change) }
    }

    // MARK: Commands

    func canPerform(_ id: CommandID) -> Bool {
        let path = state.path(of: state.activeLayerID)
        let layer = state.activeLayer
        if id.adjustmentKind != nil { return true }
        if id.filterKind != nil {
            if case .smart? = layer?.content { return true }
            return layer?.isRaster == true && !(layer?.tiles.isEmpty ?? true)
        }
        if id == .liquify { return layer?.isRaster == true && !(layer?.tiles.isEmpty ?? true) }
        switch id {
        case .repeatFilter:
            if case .smart? = layer?.content { return lastFilter != nil }
            return lastFilter != nil && layer?.isRaster == true
        case .duplicateLayer, .deleteLayer, .groupLayers, .layerStyle:
            return layer != nil
        case .bringLayerForward, .bringLayerToFront:
            guard let path else { return false }
            return path.last! < state.children(of: Array(path.dropLast())).count - 1
        case .sendLayerBackward, .sendLayerToBack:
            return (path?.last ?? 0) > 0
        case .ungroupLayers:
            return layer?.isGroup == true
        case .toggleClipping:
            guard let path else { return false }
            return layer?.isClipped == true || path.last! > 0
        case .addMaskRevealAll, .addMaskHideAll:
            return layer != nil && layer?.mask == nil
        case .toggleMask, .deleteMask:
            return layer?.mask != nil
        case .convertToSmartObject:
            return (layer?.isRaster == true && !(layer?.tiles.isEmpty ?? true)) || layer?.isText == true
        case .rasterizeLayer:
            guard let layer else { return false }
            return !layer.isRaster && !layer.isAdjustment
        case .export, .exportPNG:
            return !isExporting
        case .autoEnhance, .autoStraighten, .suggestCrop, .autoColor, .selectPeople, .copyImageText, .textToLayers,
             .selectSky, .straightenDocument:
            return !isUntouchedBlank
        case .exportForWeb:
            return !isExporting
        case .deselect, .invertSelection, .aiRemoveObject, .featherSelection, .growSelection, .shrinkSelection:
            return state.selection != nil
        case .copy, .cut:
            // Without a selection they take the whole layer.
            return activeLayer?.isRaster ?? false
        case .clearPixels:
            return state.selection != nil && (activeLayer?.isRaster ?? false)
        case .fillForeground, .fillBackground, .fillPattern:
            return activeLayer?.isRaster ?? false
        case .layerViaCopy:
            return activeLayer?.isRaster ?? false
        case .freeTransform:
            return activeLayer.map { $0.isRaster || $0.isText || $0.vectorMask != nil || { if case .smart = $0.content { true } else { false } }($0) } ?? false
        case .zoomIn, .zoomOut, .fitToWindow, .actualSize, .rotateViewLeft, .rotateViewRight, .resetViewRotation:
            return canvas.canPerform(id)
        default:
            return true
        }
    }

    func isChecked(_ id: CommandID) -> Bool {
        switch id {
        case .toggleGammaBlending: state.blendSpace == .gamma
        case .toggleClipping: activeLayer?.isClipped == true
        case .toggleRulers: state.aids.rulersVisible
        case .toggleGrid: state.aids.grid.isVisible
        case .toggleSnap: state.aids.snap
        case .toggleNavigator: showNavigator
        case .toggleClassicLayout: classicLayout
        case .hideInterface: interfaceHidden
        case .toggleMask: activeLayer?.mask?.isEnabled == false
        default: false
        }
    }

    func perform(_ id: CommandID) {
        guard canPerform(id) else { return }
        if let kind = id.adjustmentKind {
            addLayer(Layer(name: kind.title, content: .adjustment(Adjustment(kind))), actionName: String(localized: "New \(String(localized: String.LocalizationValue(kind.title)))"))
            return
        }
        if let kind = id.filterKind {
            openFilter(kind)
            return
        }
        switch id {
        case .commandPalette:
            isPaletteOpen.toggle()
        case .toggleClassicLayout:
            classicLayout.toggle()
            // The canvas just changed width: fit the image to it again.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.canvas.perform(.fitToWindow) }
        case .toggleNavigator:
            showNavigator.toggle()
        case .hideInterface:
            interfaceHidden.toggle()
        case .fillForeground: fill(with: foreground, opacity: foregroundOpacity, name: "Fill")
        case .fillBackground: fill(with: background, opacity: backgroundOpacity, name: "Fill")
        case .fillPattern: fillWithPattern()
        case .exportWebProject: exportWebProject()
        case .exportPNG: export(options: ExportOptions(format: .png))
        case .autoEnhance: ai.autoEnhance()
        case .autoStraighten: ai.autoStraighten()
        case .suggestCrop: ai.suggestCrop()
        case .batchProcess: isBatchSheetPresented = true
        case .autoColor: ai.autoColor()
        case .selectPeople: ai.selectPeople()
        case .copyImageText: ai.copyImageText()
        case .textToLayers: ai.textToLayers()
        case .selectSky: ai.selectSky()
        case .straightenDocument: ai.straightenDocument()
        case .exportForWeb:
            var web = ExportOptions.web
            web.colorSpace = .sRGB
            exportOptions = web
            isExportSheetPresented = true
        case .newDocument: DocumentOpener.shared.showNewDocumentWindow()
        case .openDocument: DocumentOpener.shared.showOpenPanel()
        case .showLayers, .showPaths, .showChannels, .showHistory:
            showLayersPanel = true
            inspectorTab = id == .showLayers ? .layers : id == .showPaths ? .paths : id == .showChannels ? .channels : .history
        case .repeatFilter:
            if let f = lastFilter { applyFilter(f) }
        case .liquify:
            beginLiquify()
        case .newLayer:
            addLayer(Layer(name: state.nextLayerName(), content: .raster(TileGrid())), actionName: "New Layer")
        case .newGroup:
            addLayer(Layer(name: state.nextLayerName(prefix: "Group"), blendMode: .passThrough,
                           content: .group(LayerGroup())), actionName: "New Group")
        case .newSolidFill:
            addLayer(Layer(name: "Color Fill", content: .fill(.solid(SRGBColor(0.2, 0.45, 0.9)))), actionName: "New Fill Layer")
        case .newGradientFill:
            let w = Double(state.width), h = Double(state.height)
            addLayer(Layer(name: "Gradient Fill", content: .fill(.gradient(
                GradientFill(start: SIMD2(0, h / 2), end: SIMD2(w, h / 2))))), actionName: "New Fill Layer")
        case .newPatternFill:
            addLayer(Layer(name: "Pattern Fill", content: .fill(.pattern(PatternFill()))), actionName: "New Fill Layer")
        case .duplicateLayer:
            edit("Duplicate Layer") { $0.duplicateActiveLayer() }
        case .deleteLayer:
            edit("Delete Layer") { $0.deleteActiveLayer() }
        case .bringLayerForward:
            edit("Bring Forward") { $0.moveActiveLayer(by: 1) }
        case .sendLayerBackward:
            edit("Send Backward") { $0.moveActiveLayer(by: -1) }
        case .bringLayerToFront:
            edit("Bring to Front") { $0.moveActiveLayer(by: Int.max / 2) }
        case .sendLayerToBack:
            edit("Send to Back") { $0.moveActiveLayer(by: -Int.max / 2) }
        case .groupLayers:
            edit("Group Layer") { $0.groupActiveLayer(name: $0.nextLayerName(prefix: "Group")) }
        case .ungroupLayers:
            edit("Ungroup") { $0.ungroupActiveLayer() }
        case .toggleClipping:
            let clipped = activeLayer?.isClipped == true
            editActive(clipped ? "Release Clipping Mask" : "Create Clipping Mask") { $0.isClipped = !clipped }
        case .addMaskRevealAll:
            if let selection = state.selection, let id = state.activeLayerID {
                edit("Add Layer Mask") {
                    $0.updateLayer(id) { $0.mask = selection.asMask }
                    $0.selection = nil
                }
            } else {
                editActive("Add Layer Mask") { $0.mask = .revealAll }
            }
        case .addMaskHideAll:
            editActive("Add Layer Mask") { $0.mask = .hideAll }
        case .toggleMask:
            let enabled = activeLayer?.mask?.isEnabled == true
            editActive(enabled ? "Disable Layer Mask" : "Enable Layer Mask") { $0.mask?.isEnabled = !enabled }
        case .deleteMask:
            editActive("Delete Layer Mask") { $0.mask = nil; $0.vectorMask = nil }
        case .convertToSmartObject:
            convertToSmartObject()
        case .rasterizeLayer:
            rasterizeActiveLayer()
        case .layerStyle:
            isLayerStylePresented = true
        case .toggleGammaBlending:
            let gamma = state.blendSpace == .gamma
            edit(gamma ? "Blend in Linear Light" : "Blend in Gamma Space") { $0.blendSpace = gamma ? .linear : .gamma }
        case .toggleLayersPanel:
            showLayersPanel.toggle()
        case .selectAll:
            edit("Select All") { $0.selection = .all() }
        case .deselect:
            edit("Deselect") { $0.selection = nil }
        case .invertSelection:
            edit("Select Inverse") { $0.selection = $0.selection?.inverted() }
        case .selectSubject:
            ai.selectSubject()
        case .featherSelection, .growSelection, .shrinkSelection:
            selectionDialog = id
        case .copy:
            copySelection(cut: false)
        case .cut:
            copySelection(cut: true)
        case .clearPixels:
            clearSelectedPixels()
        case .layerViaCopy:
            layerViaCopy()
        case .freeTransform:
            tool = .freeTransform
        case .flipHorizontal: flipCanvas(.horizontal)
        case .flipVertical: flipCanvas(.vertical)
        case .rotateRight: flipCanvas(.rotateRight)
        case .rotateLeft: flipCanvas(.rotateLeft)
        case .rotate180: flipCanvas(.rotate180)
        case .crop:
            tool = .crop
        case .toggleRulers:
            edit(state.aids.rulersVisible ? "Hide Rulers" : "Show Rulers") { $0.aids.rulersVisible.toggle() }
        case .toggleGrid:
            edit(state.aids.grid.isVisible ? "Hide Grid" : "Show Grid") { $0.aids.grid.isVisible.toggle() }
        case .toggleSnap:
            edit("Snap") { $0.aids.snap.toggle() }
        case .clearGuides:
            edit("Clear Guides") { $0.aids.guides = [] }
        case .aiRemoveBackground:
            ai.removeBackground()
        case .aiRemoveObject:
            ai.fill(mode: .remove, prompt: "", reference: nil)
        case .showAssistant:
            showAI(.assistant)
        case .aiGenerate:
            showAI(.generate)
        case .aiEditImage:
            showAI(.assistant)
        case .aiGenerativeFill:
            showAI(.fill)
        case .aiExpand:
            showAI(.expand)
        case .aiColorMatch:
            showAI(.colorMatch)
        case .aiRelight: showAI(.relight)
        case .aiReflections: showAI(.reflections)
        case .aiHarmonize: showAI(.harmonize)
        case .aiUpscale: showAI(.upscale)
        case .aiDistractions: showAI(.cleanup)
        case .aiPresets: showAI(.presets)
        case .aiLensBlur: showAI(.lensBlur)
        case .placeImage:
            choosePlaceImage()
        case .export:
            isExportSheetPresented = true
        default:
            canvas.perform(id)
        }
    }

    func showAI(_ section: AISection) {
        showLayersPanel = true
        inspectorTab = .ai
        aiSection = section
    }

    // MARK: Marquee tools

    func beginMarquee(at point: SIMD2<Double>, modifiers: NSEvent.ModifierFlags) {
        commitLiveEdit()
        let op: Selection.Operation = switch (modifiers.contains(.shift), modifiers.contains(.option)) {
        case (true, true): .intersect
        case (true, false): .add
        case (false, true): .subtract
        default: .replace
        }
        marquee = Marquee(start: point, current: point, ellipse: tool == .ellipseMarquee, operation: op)
    }

    func updateMarquee(to point: SIMD2<Double>) {
        marquee?.current = point
    }

    func endMarquee() {
        guard let m = marquee else { return }
        marquee = nil
        let r = m.rect
        if r.width < 1 || r.height < 1 {
            // A click without a drag deselects (replace mode only).
            if m.operation == .replace, state.selection != nil { edit("Deselect") { $0.selection = nil } }
            return
        }
        let shape = m.ellipse ? Selection.ellipse(in: r) : Selection.rectangle(r)
        applySelection(shape, operation: m.operation, name: m.ellipse ? "Elliptical Marquee" : "Rectangular Marquee")
    }

    func addLayer(_ layer: Layer, actionName: String) {
        edit(actionName) { $0.insertLayerAboveActive(layer) }
    }

    private func editActive(_ name: String, _ change: @escaping (inout Layer) -> Void) {
        guard let id = state.activeLayerID else { return }
        edit(name) { $0.updateLayer(id, change) }
    }

    // MARK: Smart objects

    private func convertToSmartObject() {
        guard let layer = activeLayer, let metal else { return }
        // Text becomes a smart object of its rendered pixels (no longer editable as text).
        let grid: TileGrid
        switch layer.content {
        case .raster(let tiles): grid = tiles
        case .text(let text): grid = DocumentCompositor.rasterize(text)
        default: return
        }
        guard let bounds = grid.tileBounds else { return }
        do {
            let source = try TileOperations.translate(grid, by: SIMD2(-bounds.x, -bounds.y), context: metal)
            let smart = SmartObject(source: source, width: bounds.width, height: bounds.height,
                                    transform: GlimmerCore.AffineTransform(tx: Double(bounds.x), ty: Double(bounds.y)))
            editActive("Convert to Smart Object") { $0.content = .smart(smart) }
        } catch {
            report(error)
        }
    }

    private func rasterizeActiveLayer() {
        guard let layer = activeLayer, let metal else { return }
        do {
            let bounds = rasterizeBounds(of: layer) ?? state.bounds
            let tiles = try DocumentCompositor.rasterize(layer, bounds: bounds, blendSpace: state.blendSpace, context: metal)
            editActive(layer.isGroup ? "Merge Group" : "Rasterize Layer") {
                $0.content = .raster(tiles)
                if $0.blendMode == .passThrough { $0.blendMode = .normal }
            }
        } catch {
            report(error)
        }
    }

    /// The area worth rasterizing: the document, plus content hanging outside it.
    private func rasterizeBounds(of layer: Layer) -> PixelRect? {
        switch layer.content {
        case .smart(let s): return s.bounds.intersection(PixelRect(x: -8192, y: -8192, width: 16384 + state.width, height: 16384 + state.height))
        default: return state.bounds
        }
    }

    // MARK: Layer panel actions

    func setActiveLayer(_ id: UUID?) {
        guard let id, id != state.activeLayerID else { return }
        commitLiveEdit()
        // Selection is not an undoable edit.
        document.state.activeLayerID = id
    }

    func setVisibility(_ id: UUID, _ visible: Bool) {
        edit(visible ? "Show Layer" : "Hide Layer") { $0.updateLayer(id) { $0.isVisible = visible } }
    }

    func setExpanded(_ id: UUID, _ expanded: Bool) {
        // Disclosure state is saved with the document but isn't an undoable edit.
        document.state.updateLayer(id) { layer in
            if case .group(var g) = layer.content {
                g.isExpanded = expanded
                layer.content = .group(g)
            }
        }
    }

    func rename(_ id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, state.layer(id: id)?.name != trimmed else { return }
        edit("Rename Layer") { $0.updateLayer(id) { $0.name = trimmed } }
    }

    func setBlendMode(_ mode: GlimmerCore.BlendMode) {
        guard let id = state.activeLayerID, activeLayer?.blendMode != mode else { return }
        edit("Change Blend Mode") { $0.updateLayer(id) { $0.blendMode = mode } }
    }

    /// Live opacity change during a slider drag; one undo step on release.
    func setOpacity(_ value: Double) {
        liveLayer("Change Opacity") { $0.opacity = min(max(value, 0), 1) }
    }

    /// Moves `id` so it appears directly above the row `target` (nil = bottom of the stack).
    func moveLayer(_ id: UUID, above target: UUID?) {
        edit("Reorder Layers") { $0.moveLayer(id, above: target) }
    }

    func moveLayer(_ id: UUID, intoGroup group: UUID) {
        edit("Move Into Group") { $0.moveLayer(id, intoTopOf: group) }
    }

    // MARK: Move tool

    func beginMove(at point: SIMD2<Double>) {
        guard let layer = activeLayer, !layer.isAdjustment else { return }
        commitLiveEdit()
        move = (layer.id, point, state.aids.snap ? snapBounds(of: layer) : nil)
    }

    /// What the Move tool snaps: the layer's visible extent.
    private func snapBounds(of layer: Layer) -> PixelRect? {
        switch layer.content {
        case .raster(let grid): return grid.tileBounds.flatMap { contentBounds(of: grid, within: $0) }
        case .text(let t): return t.bounds
        case .smart(let s): return s.bounds
        default:
            guard let r = layer.vectorMask?.controlBounds else { return nil }
            return PixelRect(x: Int(r.minX.rounded()), y: Int(r.minY.rounded()), width: Int(r.width.rounded()), height: Int(r.height.rounded()))
        }
    }

    func updateMove(to point: SIMD2<Double>) {
        guard let move else { return }
        var d = point - move.start
        if let b = move.bounds {
            d += snapOffset(forBoxAt: SIMD2(Double(b.x), Double(b.y)) + d, size: SIMD2(Double(b.width), Double(b.height)))
        }
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
        guard offset != .zero, let metal, let layer = state.layer(id: id) else { return }
        do {
            let moved = try TileOperations.translate(layer, by: offset, context: metal)
            edit(actionName) { $0.updateLayer(id) { $0 = moved } }
        } catch {
            report(error)
        }
    }

    /// A new document nobody has drawn in or changed.
    var isUntouchedBlank: Bool {
        document.history.isEmpty && state.textureTileIDs.isEmpty && state.allLayers.count <= 1
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
        if isUntouchedBlank {
            // Nothing here yet: the image becomes the document, at its own size.
            let tiles = try ImageImporter.tiles(from: image, origin: .zero)
            let layer = Layer(name: name, content: .raster(tiles))
            edit("Open Image") {
                $0.width = image.width
                $0.height = image.height
                $0.layers = [layer]
                $0.activeLayerID = layer.id
                $0.selection = nil
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in self?.canvas.perform(.fitToWindow) }
            return
        }
        let origin = SIMD2((state.width - image.width) / 2, (state.height - image.height) / 2)
        let tiles = try ImageImporter.tiles(from: image, origin: origin)
        let layer = Layer(name: name, content: .raster(tiles))
        edit("Place Image") { $0.insertLayerAboveActive(layer) }
        nameByContent(layer.id, image: image, currentName: name)
    }

    /// Gives a layer with a camera or clipboard name ("IMG_1234", "Pasted Layer")
    /// a name that says what it shows, found on this Mac. Not an undo step: it
    /// only replaces a name nobody chose.
    func nameByContent(_ id: UUID, image: CGImage, currentName: String) {
        guard ImageLabel.isGeneric(currentName) else { return }
        Task { [weak self] in
            let label = await Task.detached(priority: .utility) { () -> String? in
                ImageLabel.name(for: Self.downscaled(image, maxSide: 512) ?? image)
            }.value
            guard let self, let label, self.state.allLayers.first(where: { $0.id == id })?.name == currentName else { return }
            self.document.state.updateLayer(id) { $0.name = label }
        }
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

    /// Saves the document as a project for Glimmer for the web.
    func exportWebProject() {
        guard let metal else { return }
        commitLiveEdit()
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.aipsProject]
        panel.nameFieldStringValue = "\(documentName).aips"
        panel.canCreateDirectories = true
        panel.message = "Fill layers, shapes and smart filters are saved as pixels; the web app has no equivalent."
        let snapshot = state
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in
                guard let self else { return }
                self.isExporting = true
                defer { self.isExporting = false }
                do {
                    try await Task.detached(priority: .userInitiated) {
                        try AipsExporter.exportProject(snapshot, context: metal).write(to: url, options: .atomic)
                    }.value
                } catch {
                    self.report(error)
                }
            }
        }
    }

    func export(options: ExportOptions) {
        guard let metal else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [options.format.contentType]
        let ext = options.format == .jpeg ? "jpg" : options.format.contentType.preferredFilenameExtension ?? "png"
        panel.nameFieldStringValue = "Untitled.\(ext)"
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
                    let bytes = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                    self.showToast(String(localized: "Exported \(url.lastPathComponent) (\(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)))."))
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
