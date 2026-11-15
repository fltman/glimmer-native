import AppIntents
import CoreGraphics
import Foundation
import GlimmerAI
import GlimmerCore
import GlimmerRender
import UniformTypeIdentifiers

// MARK: Headless editing (no window)

/// Document operations for Shortcuts: open an image or .glimmer file, edit, export.
enum HeadlessEditor {
    struct Failure: Error, CustomLocalizedStringResourceConvertible {
        let message: String
        var localizedStringResource: LocalizedStringResource { "\(message)" }
    }

    static var metal: MetalContext {
        get throws {
            guard let m = MetalContext.shared else { throw Failure(message: "This Mac has no Metal GPU available.") }
            return m
        }
    }

    /// A document from an image file or a .glimmer package.
    static func document(from file: IntentFile) throws -> DocumentState {
        if file.type?.conforms(to: .glimmerDocument) == true || file.filename.lowercased().hasSuffix(".glimmer") {
            guard let url = file.fileURL else { throw Failure(message: "Couldn't read the Glimmer document.") }
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            return try GlimmerPackage.state(from: FileWrapper(url: url))
        }
        return try document(imageData: file.data, filename: file.filename)
    }

    /// A document from a file on disk (for batch processing).
    static func document(contentsOf url: URL) throws -> DocumentState {
        if url.pathExtension.lowercased() == "glimmer" {
            return try GlimmerPackage.state(from: FileWrapper(url: url))
        }
        return try document(imageData: Data(contentsOf: url), filename: url.lastPathComponent)
    }

    static func document(imageData: Data, filename: String) throws -> DocumentState {
        let image = try ImageImporter.image(from: imageData)
        let tiles = try ImageImporter.tiles(from: image)
        let name = (filename as NSString).deletingPathExtension
        return DocumentState(width: image.width, height: image.height,
                             layers: [Layer(name: name.isEmpty ? "Image" : name, content: .raster(tiles))])
    }

    /// Auto Color: a Color Balance layer that removes the cast, if there is one.
    static func autoColor(_ state: DocumentState) throws -> DocumentState {
        let image = try ImageExporter.flattenedSRGB(state, context: metal)
        guard let cast = SmartAnalysis.colorCast(image), SmartAnalysis.isNoticeableCast(cast, threshold: 0.012) else { return state }
        var state = state
        state.activeLayerID = state.layers.last?.id
        state.insertLayerAboveActive(Layer(name: "Auto Color", content: .adjustment(SmartAnalysis.castCorrection(cast))))
        return state
    }

    /// Auto Enhance as editable adjustment layers. Returns the state unchanged
    /// when the image needs nothing.
    static func autoEnhance(_ state: DocumentState) throws -> DocumentState {
        let image = try ImageExporter.flattenedSRGB(state, context: metal)
        let recipe = SmartAnalysis.enhanceRecipe(for: image)
        guard recipe.isNoticeable else { return state }
        var state = state
        let children = recipe.adjustments.map { Layer(name: $0.kind.title, content: .adjustment($0)) }
        state.activeLayerID = state.layers.last?.id
        state.insertLayerAboveActive(Layer(name: "Auto Enhance", blendMode: .passThrough,
                                           content: .group(LayerGroup(children: children, isExpanded: false))))
        return state
    }

    /// The topmost visible pixel layer.
    static func pixelLayer(_ state: DocumentState) throws -> Layer {
        guard let layer = state.allLayers.reversed().first(where: { $0.isRaster && $0.isVisible && !$0.tiles.isEmpty }) else {
            throw Failure(message: "The image has no pixel layer to work on.")
        }
        return layer
    }

    static func removeBackground(_ state: DocumentState) throws -> DocumentState {
        var state = state
        let layer = try pixelLayer(state)
        let image = try ImageExporter.layerImageSRGB(layer, in: state, context: metal)
        let mask = try SubjectSegmentation.subjectMask(of: image)
        let selection = Selection.from(mask: mask.values.map { $0 / 255 }, rect: state.bounds)
        state.updateLayer(layer.id) { $0.mask = selection.asMask }
        return state
    }

    static func applyFilter(_ settings: FilterSettings, to state: DocumentState) throws -> DocumentState {
        var state = state
        let layer = try pixelLayer(state)
        let result = try FilterEngine(context: metal).apply(settings, to: layer.tiles, frame: state.bounds, selection: nil)
        state.updateLayer(layer.id) { $0.tiles = result }
        return state
    }

    static func applyPreset(_ preset: Preset, to state: DocumentState) throws -> DocumentState {
        var state = state
        for (id, params) in preset.filterSteps {
            if let f = FilterSettings(id: id, params) { state = try applyFilter(f, to: state) }
        }
        state.activeLayerID = state.layers.last?.id
        state.insertLayerAboveActive(preset.makeGroup())
        return state
    }

    /// Runs a saved assistant action without a window. Steps that need the
    /// interactive editor or a paid AI job aren't available here.
    static func run(_ action: SavedAction, on state: DocumentState) throws -> DocumentState {
        var state = state
        for step in action.steps {
            switch step.op {
            case "add_adjustment":
                guard let kind = AdjustmentKind(rawValue: step.string("type") ?? "") else { throw Failure(message: "Unknown adjustment.") }
                state.activeLayerID = state.layers.last?.id
                state.insertLayerAboveActive(Layer(name: kind.title, content: .adjustment(AIController.adjustment(kind, step.object("params")))))
            case "apply_filter":
                guard let kind = FilterKind(rawValue: step.string("type") ?? "") else { throw Failure(message: "Unknown filter.") }
                var values: [String: Double] = [:]
                for (k, v) in step.object("params") { if let n = v.number { values[k] = n } }
                state = try applyFilter(FilterSettings(kind, values), to: state)
            case "apply_preset":
                let name = (step.string("name") ?? "").lowercased()
                guard let preset = Preset.all.first(where: { $0.name.lowercased() == name || $0.id == name }) else {
                    throw Failure(message: "Unknown preset.")
                }
                state = try applyPreset(preset, to: state)
            case "add_layer_effect":
                let layer = try pixelLayer(state)
                let effects = try AIController.patched(layer.effects, type: step.string("type") ?? "", step.object("params"))
                state.updateLayer(layer.id) { $0.effects = effects }
            case "add_text":
                let size = step.number("size") ?? max(Double(state.height) * 0.08, 12)
                var text = TextLayer(string: step.string("text") ?? "Text", size: size,
                                     color: parseHexColor(step.string("color")) ?? .black, alignment: .center, origin: .zero)
                let layout = text.layoutSize
                let y: Double = switch step.string("position") {
                case "top": Double(state.height) * 0.08
                case "bottom": Double(state.height) * 0.92 - layout.height
                default: (Double(state.height) - layout.height) / 2
                }
                text.origin = SIMD2((Double(state.width) - layout.width) / 2, y)
                state.activeLayerID = state.layers.last?.id
                state.insertLayerAboveActive(Layer(name: String(text.string.prefix(32)), content: .text(text)))
            case "auto_enhance":
                state = try autoEnhance(state)
            case "auto_color":
                state = try autoColor(state)
            case "remove_background":
                state = try removeBackground(state)
            case "select_all", "deselect", "set_foreground", "new_layer":
                continue  // no effect on the exported image
            default:
                throw Failure(message: "The step “\(step.op)” needs the Glimmer window (or a paid AI job) and can't run from Shortcuts.")
            }
        }
        return state
    }

    static func export(_ state: DocumentState, format: ExportOptions.Format, name: String) throws -> IntentFile {
        let options = ExportOptions(format: format)
        let image = try ImageExporter.convert(try ImageExporter.flatten(state, context: metal), options: options)
        let data = try ImageExporter.encode(image, options: options)
        let ext = format.contentType.preferredFilenameExtension ?? format.rawValue
        return IntentFile(data: data, filename: "\(name).\(ext)", type: format.contentType)
    }

    static func baseName(_ file: IntentFile) -> String {
        let n = (file.filename as NSString).deletingPathExtension
        return n.isEmpty ? "Glimmer" : n
    }
}

extension UTType {
    static let glimmerDocument = UTType(exportedAs: "com.brattoo.glimmer.document")
}

// MARK: Parameters

enum ImageFormatOption: String, AppEnum {
    case png = "png"
    case jpeg = "jpeg"
    case heic = "heic"
    case tiff = "tiff"
    case webp = "webp"

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Image Format"
    static let caseDisplayRepresentations: [ImageFormatOption: DisplayRepresentation] = [
        .png: "PNG", .jpeg: "JPEG", .heic: "HEIC", .tiff: "TIFF", .webp: "WebP",
    ]

    var format: ExportOptions.Format { ExportOptions.Format(rawValue: rawValue) ?? .png }
}

enum FilterOption: String, AppEnum {
    case gaussianBlur = "gaussian_blur"
    case lensBlur = "lens_blur"
    case motionBlur = "motion_blur"
    case sharpen = "sharpen"
    case unsharpMask = "unsharp_mask"
    case clarity = "clarity"
    case addNoise = "add_noise"
    case pixelate = "pixelate"
    case findEdges = "find_edges"
    case emboss = "emboss"
    case oilPaint = "oil_paint"
    case halftone = "halftone"
    case vignette = "vignette"
    case chromaticAberration = "chromatic_aberration"

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Filter"
    static let caseDisplayRepresentations: [FilterOption: DisplayRepresentation] = [
        .gaussianBlur: "Gaussian Blur", .lensBlur: "Lens Blur", .motionBlur: "Motion Blur", .sharpen: "Sharpen",
        .unsharpMask: "Unsharp Mask", .clarity: "Clarity", .addNoise: "Add Noise", .pixelate: "Pixelate",
        .findEdges: "Find Edges", .emboss: "Emboss", .oilPaint: "Oil Paint", .halftone: "Halftone",
        .vignette: "Vignette", .chromaticAberration: "Chromatic Aberration",
    ]

    var kind: FilterKind { FilterKind(rawValue: rawValue)! }
}

struct PresetEntity: AppEntity {
    let id: String
    let name: String

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Preset"
    static let defaultQuery = PresetQuery()
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }

    init(_ preset: Preset) {
        id = preset.id
        name = preset.name
    }
}

struct PresetQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [PresetEntity] {
        Preset.all.filter { identifiers.contains($0.id) }.map(PresetEntity.init)
    }

    func suggestedEntities() async throws -> [PresetEntity] {
        Preset.all.map(PresetEntity.init)
    }
}

struct SavedActionEntity: AppEntity {
    let id: String
    let name: String

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Glimmer Action"
    static let defaultQuery = SavedActionQuery()
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }

    init(_ action: SavedAction) {
        id = action.id.uuidString
        name = action.name
    }
}

struct SavedActionQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [SavedActionEntity] {
        SavedAction.load().filter { identifiers.contains($0.id.uuidString) }.map(SavedActionEntity.init)
    }

    func suggestedEntities() async throws -> [SavedActionEntity] {
        SavedAction.load().map(SavedActionEntity.init)
    }
}

// MARK: Intents

struct RunActionIntent: AppIntent {
    static let title: LocalizedStringResource = "Run Glimmer Action"
    static let description = IntentDescription("Runs an action you saved from the Glimmer assistant on an image. Repeat it over a folder to edit many photos the same way.")
    static var supportedModes: IntentModes { .background }

    @Parameter(title: "Image", supportedContentTypes: [.image])
    var image: IntentFile

    @Parameter(title: "Action")
    var action: SavedActionEntity

    @Parameter(title: "Format", default: .jpeg)
    var format: ImageFormatOption

    static var parameterSummary: some ParameterSummary {
        Summary("Run \(\.$action) on \(\.$image)") { \.$format }
    }

    func perform() async throws -> some IntentResult & ReturnsValue<IntentFile> {
        guard let saved = SavedAction.load().first(where: { $0.id.uuidString == action.id }) else {
            throw HeadlessEditor.Failure(message: "That action no longer exists.")
        }
        let state = try HeadlessEditor.run(saved, on: try HeadlessEditor.document(from: image))
        return .result(value: try HeadlessEditor.export(state, format: format.format, name: HeadlessEditor.baseName(image)))
    }
}

struct AutoEnhanceIntent: AppIntent {
    static let title: LocalizedStringResource = "Auto Enhance Image"
    static let description = IntentDescription("Corrects tone and colour automatically on this Mac, like Image › Auto Enhance.")
    static var supportedModes: IntentModes { .background }

    @Parameter(title: "Image", supportedContentTypes: [.image])
    var image: IntentFile

    @Parameter(title: "Format", default: .jpeg)
    var format: ImageFormatOption

    static var parameterSummary: some ParameterSummary {
        Summary("Auto enhance \(\.$image)") { \.$format }
    }

    func perform() async throws -> some IntentResult & ReturnsValue<IntentFile> {
        let state = try HeadlessEditor.autoEnhance(try HeadlessEditor.document(from: image))
        return .result(value: try HeadlessEditor.export(state, format: format.format, name: HeadlessEditor.baseName(image)))
    }
}

struct RemoveBackgroundIntent: AppIntent {
    static let title: LocalizedStringResource = "Remove Background"
    static let description = IntentDescription("Cuts the main subject out of an image on this Mac and returns a PNG with a transparent background.")
    static var supportedModes: IntentModes { .background }

    @Parameter(title: "Image", supportedContentTypes: [.image])
    var image: IntentFile

    static var parameterSummary: some ParameterSummary { Summary("Remove the background from \(\.$image)") }

    func perform() async throws -> some IntentResult & ReturnsValue<IntentFile> {
        let state = try HeadlessEditor.removeBackground(try HeadlessEditor.document(from: image))
        return .result(value: try HeadlessEditor.export(state, format: .png, name: HeadlessEditor.baseName(image) + " cutout"))
    }
}

struct ApplyPresetIntent: AppIntent {
    static let title: LocalizedStringResource = "Apply Glimmer Preset"
    static let description = IntentDescription("Applies one of Glimmer's photo looks to an image.")
    static var supportedModes: IntentModes { .background }

    @Parameter(title: "Image", supportedContentTypes: [.image])
    var image: IntentFile

    @Parameter(title: "Preset")
    var preset: PresetEntity

    @Parameter(title: "Format", default: .jpeg)
    var format: ImageFormatOption

    static var parameterSummary: some ParameterSummary {
        Summary("Apply \(\.$preset) to \(\.$image)") { \.$format }
    }

    func perform() async throws -> some IntentResult & ReturnsValue<IntentFile> {
        guard let p = Preset.all.first(where: { $0.id == preset.id }) else {
            throw HeadlessEditor.Failure(message: "That preset no longer exists.")
        }
        let state = try HeadlessEditor.applyPreset(p, to: try HeadlessEditor.document(from: image))
        return .result(value: try HeadlessEditor.export(state, format: format.format, name: "\(HeadlessEditor.baseName(image)) \(p.name)"))
    }
}

struct ApplyFilterIntent: AppIntent {
    static let title: LocalizedStringResource = "Apply Glimmer Filter"
    static let description = IntentDescription("Runs a Glimmer filter with its default settings on an image.")
    static var supportedModes: IntentModes { .background }

    @Parameter(title: "Image", supportedContentTypes: [.image])
    var image: IntentFile

    @Parameter(title: "Filter", default: .vignette)
    var filter: FilterOption

    @Parameter(title: "Format", default: .jpeg)
    var format: ImageFormatOption

    static var parameterSummary: some ParameterSummary {
        Summary("Apply \(\.$filter) to \(\.$image)") { \.$format }
    }

    func perform() async throws -> some IntentResult & ReturnsValue<IntentFile> {
        let state = try HeadlessEditor.applyFilter(FilterSettings(filter.kind), to: try HeadlessEditor.document(from: image))
        return .result(value: try HeadlessEditor.export(state, format: format.format, name: HeadlessEditor.baseName(image)))
    }
}

struct ExportImageIntent: AppIntent {
    static let title: LocalizedStringResource = "Export Glimmer Document"
    static let description = IntentDescription("Flattens a Glimmer document (or converts an image) to PNG, JPEG, HEIC, TIFF or WebP.")
    static var supportedModes: IntentModes { .background }

    @Parameter(title: "Document", supportedContentTypes: [.package, .image])
    var document: IntentFile

    @Parameter(title: "Format", default: .png)
    var format: ImageFormatOption

    static var parameterSummary: some ParameterSummary { Summary("Export \(\.$document) as \(\.$format)") }

    func perform() async throws -> some IntentResult & ReturnsValue<IntentFile> {
        let state = try HeadlessEditor.document(from: document)
        return .result(value: try HeadlessEditor.export(state, format: format.format, name: HeadlessEditor.baseName(document)))
    }
}

struct GlimmerShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: RemoveBackgroundIntent(),
                    phrases: ["Remove the background with \(.applicationName)", "Cut out an image with \(.applicationName)"],
                    shortTitle: "Remove Background", systemImageName: "person.crop.rectangle")
        AppShortcut(intent: AutoEnhanceIntent(),
                    phrases: ["Auto enhance a photo with \(.applicationName)", "Fix a photo with \(.applicationName)"],
                    shortTitle: "Auto Enhance", systemImageName: "wand.and.sparkles")
        AppShortcut(intent: ApplyPresetIntent(),
                    phrases: ["Apply a \(.applicationName) preset", "Apply \(\.$preset) in \(.applicationName)"],
                    shortTitle: "Apply Preset", systemImageName: "camera.filters")
        AppShortcut(intent: ApplyFilterIntent(),
                    phrases: ["Apply a \(.applicationName) filter"],
                    shortTitle: "Apply Filter", systemImageName: "camera.aperture")
        AppShortcut(intent: RunActionIntent(),
                    phrases: ["Run a \(.applicationName) action"],
                    shortTitle: "Run Action", systemImageName: "bookmark")
        AppShortcut(intent: ExportImageIntent(),
                    phrases: ["Export with \(.applicationName)"],
                    shortTitle: "Export Image", systemImageName: "square.and.arrow.up")
    }
}
