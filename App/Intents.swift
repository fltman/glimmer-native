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
        let image = try ImageImporter.image(from: file.data)
        let tiles = try ImageImporter.tiles(from: image)
        let name = (file.filename as NSString).deletingPathExtension
        return DocumentState(width: image.width, height: image.height,
                             layers: [Layer(name: name.isEmpty ? "Image" : name, content: .raster(tiles))])
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

// MARK: Intents

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
        AppShortcut(intent: ApplyPresetIntent(),
                    phrases: ["Apply a \(.applicationName) preset", "Apply \(\.$preset) in \(.applicationName)"],
                    shortTitle: "Apply Preset", systemImageName: "camera.filters")
        AppShortcut(intent: ApplyFilterIntent(),
                    phrases: ["Apply a \(.applicationName) filter"],
                    shortTitle: "Apply Filter", systemImageName: "camera.aperture")
        AppShortcut(intent: ExportImageIntent(),
                    phrases: ["Export with \(.applicationName)"],
                    shortTitle: "Export Image", systemImageName: "square.and.arrow.up")
    }
}
