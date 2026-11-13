import AppKit
import GlimmerAI
import GlimmerCore
import GlimmerRender
import SwiftUI

/// Runs AI jobs for one document window. Every result lands as a new layer (or
/// a mask/selection), so the original pixels are never touched.
@MainActor
@Observable
final class AIController {
    struct Job: Identifiable {
        enum Status: Equatable {
            case running
            case done
            case failed(String)
            case cancelled
        }

        let id = UUID()
        let title: String
        var status: Status = .running
        var cost: Double?
        @ObservationIgnored var task: Task<Void, Never>?
    }

    struct Message: Identifiable {
        let id = UUID()
        let fromUser: Bool
        let text: String
        /// The assistant's plan, shown as a checklist under the message.
        var plan: AgentPlan?
    }

    enum StepStatus: Equatable {
        case pending, running, done
        case failed(String)
        case skipped
    }

    enum PlanStatus: Equatable { case proposed, running, finished, failed, cancelled }

    private(set) var jobs: [Job] = []
    var messages: [Message] = []
    var stepStatus: [UUID: StepStatus] = [:]
    var planStatus: [UUID: PlanStatus] = [:]
    var isPlanning = false
    @ObservationIgnored var agentHistory: [(user: String, reply: String)] = []
    @ObservationIgnored var planTask: Task<Void, Never>?
    var totalCost: Double { jobs.compactMap(\.cost).reduce(0, +) }
    var isBusy: Bool { jobs.contains { $0.status == .running } }

    @ObservationIgnored unowned let session: EditorSession

    init(session: EditorSession) {
        self.session = session
    }

    // MARK: Setup

    var hasAPIKey: Bool { (try? Self.apiKey()) != nil }

    /// The OpenRouter key from the Keychain. Debug builds also accept the
    /// `OPENROUTER_API_KEY` environment variable, so test runs never store a key.
    static func apiKey() throws -> String? {
        if let key = try KeychainSecretStore.openRouterAPIKey.read(), !key.isEmpty { return key }
        #if DEBUG
        if let key = ProcessInfo.processInfo.environment["OPENROUTER_API_KEY"], !key.isEmpty { return key }
        #endif
        return nil
    }

    private func imageModel() throws -> ImageModel {
        guard let key = try Self.apiKey() else {
            throw OpenRouterError.missingAPIKey
        }
        let model = UserDefaults.standard.string(forKey: AIDefaults.imageModelKey) ?? AIDefaults.imageModel
        return OpenRouterImageModel(client: OpenRouterClient(apiKey: key), model: model)
    }

    private var metal: MetalContext {
        get throws {
            guard let m = MetalContext.shared else { throw RenderError.noMetalDevice }
            return m
        }
    }

    // MARK: Jobs

    /// Runs `work` off the main actor; `apply` lands the result on the main actor.
    private func run<T: Sendable>(_ title: String,
                                  _ work: @escaping @Sendable () async throws -> (T, Double?),
                                  apply: @escaping @MainActor (T) throws -> Void) {
        var job = Job(title: title)
        let id = job.id
        job.task = Task { [weak self] in
            do {
                let (value, cost) = try await Task.detached(priority: .userInitiated) { try await work() }.value
                try Task.checkCancellation()
                try apply(value)
                self?.finish(id, .done, cost: cost)
            } catch is CancellationError {
                self?.finish(id, .cancelled)
            } catch {
                let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                self?.finish(id, .failed(message))
                self?.session.report(error)
            }
        }
        jobs.insert(job, at: 0)
        if jobs.count > 30 { jobs.removeLast() }
    }

    private func finish(_ id: UUID, _ status: Job.Status, cost: Double? = nil) {
        if status != .done { isSegmenting = false }
        guard let i = jobs.firstIndex(where: { $0.id == id }) else { return }
        jobs[i].status = status
        jobs[i].cost = cost
    }

    func cancel(_ id: UUID) {
        jobs.first { $0.id == id }?.task?.cancel()
    }

    func clearFinished() {
        jobs.removeAll { $0.status != .running }
    }

    // MARK: Inputs

    private func composite(_ state: DocumentState) throws -> RGBAImage {
        RGBAImage(try ImageExporter.flattenedSRGB(state, context: metal))
    }

    private func addLayer(_ image: RGBAImage, name: String, origin: SIMD2<Int>, action: String) throws {
        let tiles = try ImageImporter.tiles(from: image.cgImage, origin: origin)
        session.document.edit(action, undoManager: session.undoManager) {
            $0.insertLayerAboveActive(Layer(name: name, content: .raster(tiles)))
        }
    }

    // MARK: Capabilities

    func generate(prompt: String, negative: String, width: Int, height: Int) {
        let prompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { return }
        do {
            let model = try imageModel()
            let docSize = SIMD2(session.state.width, session.state.height)
            run("Generate “\(prompt.prefix(40))”", {
                let r = try await AIPipelines.generate(prompt: prompt, negative: negative, width: width, height: height, model: model)
                return (r.image, r.cost)
            }, apply: { [weak self] image in
                // Fit inside the document, centred.
                let k = min(1, Double(docSize.x) / Double(image.width), Double(docSize.y) / Double(image.height))
                let fitted = k < 1 ? image.resized(width: Int(Double(image.width) * k), height: Int(Double(image.height) * k)) : image
                let origin = SIMD2((docSize.x - fitted.width) / 2, (docSize.y - fitted.height) / 2)
                try self?.addLayer(fitted, name: "Generated", origin: origin, action: "Generate Image")
            })
        } catch {
            session.report(error)
        }
    }

    func editImage(instruction: String) {
        let instruction = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !instruction.isEmpty else { return }
        do {
            let model = try imageModel()
            let source = try composite(session.state)
            run("Edit “\(instruction.prefix(40))”", {
                let r = try await AIPipelines.edit(source, instruction: instruction, model: model)
                return (r.image, r.cost)
            }, apply: { [weak self] image in
                try self?.addLayer(image, name: "Edited", origin: .zero, action: "Edit Image")
            })
        } catch {
            session.report(error)
        }
    }

    /// Generative fill / remove over the current selection.
    func fill(mode: AIPipelines.InpaintMode, prompt: String, reference: URL?) {
        let state = session.state
        guard let selection = state.selection, let bounds = selection.bounds(in: state.bounds) else {
            session.errorMessage = "Make a selection first (M), then try again."
            return
        }
        do {
            let model = try imageModel()
            let source = try composite(state)
            let maskValues = selection.values(in: state.bounds).map { $0 * 255 }
            let mask = GrayImage(width: state.width, height: state.height, values: maskValues)
            let ref = try reference.map { url -> RGBAImage in
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                return RGBAImage(try ImageImporter.image(contentsOf: url))
            }
            let title = mode == .remove ? "Remove object" : (prompt.isEmpty ? "Generative fill" : "Fill “\(prompt.prefix(40))”")
            run(title, {
                let r = try await AIPipelines.inpaint(image: source, mask: mask, selectionBounds: bounds, mode: mode,
                                                      prompt: prompt, reference: ref, model: model)
                return ((r.image, r.origin), r.cost)
            }, apply: { [weak self] result in
                try self?.addLayer(result.0, name: mode == .remove ? "Removed" : "Generative Fill",
                                   origin: result.1, action: title)
            })
        } catch {
            session.report(error)
        }
    }

    func expand(margins: AIPipelines.Margins, prompt: String) {
        guard !margins.isEmpty else { return }
        do {
            let model = try imageModel()
            let source = try composite(session.state)
            run("Expand", {
                let r = try await AIPipelines.expand(source, margins: margins, prompt: prompt, model: model)
                return (r.image, r.cost)
            }, apply: { [weak self] image in
                try self?.applyExpansion(image, margins: margins)
            })
        } catch {
            session.report(error)
        }
    }

    /// Grows the canvas, shifts every layer and adds the expanded image on top.
    private func applyExpansion(_ image: RGBAImage, margins m: AIPipelines.Margins) throws {
        let metal = try metal
        let offset = SIMD2(m.left, m.top)
        let shifted = try session.state.layers.map { try TileOperations.translate($0, by: offset, context: metal) }
        let tiles = try ImageImporter.tiles(from: image.cgImage, origin: .zero)
        session.document.edit("Expand", undoManager: session.undoManager) { state in
            state.width = image.width
            state.height = image.height
            state.layers = shifted
            state.selection = nil
            let layer = Layer(name: "Expanded", content: .raster(tiles))
            state.layers.append(layer)
            state.activeLayerID = layer.id
        }
    }

    /// Lab colour transfer of the active layer toward a reference image (new layer).
    func matchColor(reference url: URL, strength: Double) {
        guard let layer = session.activeLayer, layer.isRaster || {
            if case .smart = layer.content { return true } else { return false }
        }() else {
            session.errorMessage = "Select a pixel layer to match."
            return
        }
        do {
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            let reference = RGBAImage(try ImageImporter.image(contentsOf: url))
            let source = RGBAImage(try ImageExporter.layerImageSRGB(layer, in: session.state, context: metal))
            let name = layer.name
            run("Match color", {
                (Imaging.labColorTransfer(source, reference: reference.limited(toMaxSide: 1024), strength: strength), nil)
            }, apply: { [weak self] image in
                try self?.addLayer(image, name: "\(name) (matched)", origin: .zero, action: "Match Color")
            })
        } catch {
            session.report(error)
        }
    }

    /// On-device: masks the active layer to its subject (non-destructive layer mask).
    func removeBackground() {
        guard let layer = session.activeLayer, !layer.isAdjustment, !layer.isGroup else {
            session.errorMessage = "Select a pixel layer first."
            return
        }
        do {
            let image = try ImageExporter.layerImageSRGB(layer, in: session.state, context: metal)
            let id = layer.id
            let bounds = session.state.bounds
            run("Remove background", {
                let mask = try SubjectSegmentation.subjectMask(of: image)
                return (Selection.from(mask: mask.values.map { $0 / 255 }, rect: bounds), nil)
            }, apply: { [weak self] selection in
                self?.session.document.edit("Remove Background", undoManager: self?.session.undoManager) {
                    $0.updateLayer(id) { $0.mask = selection.asMask }
                }
            })
        } catch {
            session.report(error)
        }
    }

    /// On-device: selects the main subject of the whole image.
    func selectSubject() {
        do {
            let image = try ImageExporter.flattenedSRGB(session.state, context: metal)
            let bounds = session.state.bounds
            run("Select subject", {
                let mask = try SubjectSegmentation.subjectMask(of: image)
                return (Selection.from(mask: mask.values.map { $0 / 255 }, rect: bounds), nil)
            }, apply: { [weak self] selection in
                self?.session.document.edit("Select Subject", undoManager: self?.session.undoManager) {
                    $0.selection = selection
                }
            })
        } catch {
            session.report(error)
        }
    }

    // MARK: Phase 4 capabilities

    func relight(direction: AIPipelines.LightDirection, color: SRGBColor, intensity: Double, environment: String) {
        do {
            let model = try imageModel()
            let source = try composite(session.state)
            run("Relight (\(direction.title.lowercased()))", {
                let r = try await AIPipelines.relight(source, direction: direction, color: color, intensity: intensity,
                                                      environment: environment, model: model)
                return (r.image, r.cost)
            }, apply: { [weak self] image in
                try self?.addLayer(image, name: "Relit (\(direction.title.lowercased()))", origin: .zero, action: "Relight")
            })
        } catch {
            session.report(error)
        }
    }

    func removeReflections(strength: Double) {
        do {
            let model = try imageModel()
            let state = session.state
            let source = try composite(state)
            let roi = state.selection?.bounds(in: state.bounds)
            run("Remove reflections", {
                let r = try await AIPipelines.removeReflections(source, roi: roi, strength: strength, model: model)
                return ((r.image, r.origin), r.cost)
            }, apply: { [weak self] result in
                try self?.addLayer(result.0, name: "Reflections Removed", origin: result.1, action: "Remove Reflections")
            })
        } catch {
            session.report(error)
        }
    }

    /// Re-grades the active layer to sit naturally in what's below it.
    func harmonize(strength: Double) {
        let state = session.state
        guard let layer = state.activeLayer, let path = state.path(of: layer.id), !layer.isAdjustment else {
            session.errorMessage = "Select the pasted-in layer to harmonize."
            return
        }
        do {
            let model = try imageModel()
            let fgFull = RGBAImage(try ImageExporter.layerImageSRGB(layer, in: state, context: metal))
            var below = state
            below.layers = Array(state.layers.prefix(path[0]))  // everything under the layer's root ancestor
            let bgFull = try composite(below)
            let bounds = (layer.tiles.tileBounds ?? state.bounds).intersection(state.bounds)
            guard !bounds.isEmpty else { return }
            let roi = Imaging.clampROI(bounds, width: state.width, height: state.height, padding: 0.1)
            let fg = fgFull.cropped(to: roi), bg = bgFull.cropped(to: roi)
            let id = layer.id, name = layer.name
            run("Harmonize “\(name)”", {
                let r = try await AIPipelines.harmonize(foreground: fg, background: bg, strength: strength, model: model)
                return (r.image, r.cost)
            }, apply: { [weak self] image in
                guard let self else { return }
                let tiles = try ImageImporter.tiles(from: image.cgImage, origin: SIMD2(roi.x, roi.y))
                self.session.document.edit("Harmonize", undoManager: self.session.undoManager) {
                    $0.updateLayer(id) { $0.isVisible = false }
                    $0.insertLayerAboveActive(Layer(name: "\(name) (harmonized)", content: .raster(tiles)))
                }
            })
        } catch {
            session.report(error)
        }
    }

    /// Opens an upscaled copy as a new document (Lanczos on the GPU, optionally an AI detail pass).
    func upscale(scale: Int, enhance: Bool, creativity: Double) {
        let state = session.state
        do {
            let metal = try metal
            if !enhance {
                run("Upscale \(scale)×", {
                    (try DocumentEffects.upscale(state, scale: scale, context: metal), nil)
                }, apply: { grid in
                    let layer = Layer(name: "Upscaled \(scale)×", content: .raster(grid))
                    DocumentOpener.shared.createDocument(DocumentState(width: state.width * scale, height: state.height * scale,
                                                                       layers: [layer]))
                })
                return
            }
            let model = try imageModel()
            let source = try composite(state)
            run("Upscale \(scale)× with AI detail", {
                let base = source.resized(width: source.width * scale, height: source.height * scale)
                let r = try await AIPipelines.enhance(base, creativity: creativity, model: model)
                return (r.image, r.cost)
            }, apply: { image in
                let tiles = try ImageImporter.tiles(from: image.cgImage)
                DocumentOpener.shared.createDocument(DocumentState(width: image.width, height: image.height,
                                                                   layers: [Layer(name: "Upscaled \(scale)×", content: .raster(tiles))]))
            })
        } catch {
            session.report(error)
        }
    }

    private(set) var distractions: [AIPipelines.Distraction] = []
    private(set) var distractionMessage: String?

    func findDistractions() {
        do {
            guard let key = try Self.apiKey() else { throw OpenRouterError.missingAPIKey }
            let model = UserDefaults.standard.string(forKey: AIDefaults.textModelKey) ?? AIDefaults.textModel
            let source = try composite(session.state)
            distractions = []
            distractionMessage = nil
            run("Find distractions", {
                let r = try await AIPipelines.findDistractions(source, client: OpenRouterClient(apiKey: key), model: model)
                return ((r.items, r.message), r.cost)
            }, apply: { [weak self] result in
                self?.distractions = result.0
                self?.distractionMessage = result.1 ?? (result.0.isEmpty ? "No obvious distractions found." : nil)
            })
        } catch {
            session.report(error)
        }
    }

    func dismissDistraction(_ id: String) {
        distractions.removeAll { $0.id == id }
    }

    /// Selects the given distractions (boxes) so they can be refined or removed.
    func selectDistractions(_ items: [AIPipelines.Distraction]) {
        let state = session.state
        let shapes = items.map { d -> Selection in
            let r = d.pixelRect(width: state.width, height: state.height)
            return Selection.rectangle(CGRectLike(x0: Double(r.x), y0: Double(r.y), x1: Double(r.maxX), y1: Double(r.maxY)))
        }
        guard var combined = shapes.first else { return }
        for s in shapes.dropFirst() { combined = combined.combined(with: s, .add) }
        session.document.edit("Select Distractions", undoManager: session.undoManager) { $0.selection = combined }
    }

    func removeDistractions(_ items: [AIPipelines.Distraction]) {
        selectDistractions(items)
        fill(mode: .remove, prompt: "", reference: nil)
        let ids = Set(items.map(\.id))
        distractions.removeAll { ids.contains($0.id) }
    }

    func applyPreset(_ preset: Preset) {
        // Like the web app, filter steps (grain, clarity, vignette …) bake into the active pixel layer;
        // the adjustments go in a group above it.
        if !preset.filterSteps.isEmpty, !session.applyFilterSteps(preset.filterSteps) {
            messages.append(Message(fromUser: false, text: "“\(preset.name)” also uses filters (\(preset.filterSteps.map(\.0).joined(separator: ", "))). Select a pixel layer and apply it again to include them."))
        }
        session.document.edit(String(localized: "Apply \(preset.name)"), undoManager: session.undoManager) {
            $0.insertLayerAboveActive(preset.makeGroup())
        }
    }

    // MARK: Depth lens blur

    @ObservationIgnored private var depthCache: (key: Int, depth: [Float])?

    private func documentKey(_ state: DocumentState) -> Int {
        var h = Hasher()
        h.combine(state.width); h.combine(state.height)
        for layer in state.allLayers {
            h.combine(layer.id); h.combine(layer.isVisible); h.combine(layer.opacity)
            h.combine(layer.tiles.contentSignature)
        }
        return h.finalize()
    }

    func lensBlur(_ parameters: DocumentEffects.LensBlurParameters) {
        let state = session.state
        do {
            let metal = try metal
            let image = try ImageExporter.flattenedSRGB(state, context: metal)
            let key = documentKey(state)
            let cached = depthCache?.key == key ? depthCache?.depth : nil
            run("Lens blur", {
                let depth: [Float]
                if let cached {
                    depth = cached
                } else {
                    depth = try await DepthEstimator.depth(of: image).values.map { $0 / 255 }
                }
                return ((try DocumentEffects.lensBlur(state, depth: depth, parameters: parameters, context: metal), depth), nil)
            }, apply: { [weak self] result in
                guard let self else { return }
                self.depthCache = (key, result.1)
                self.session.document.edit("Lens Blur", undoManager: self.session.undoManager) {
                    $0.insertLayerAboveActive(Layer(name: "Lens Blur", content: .raster(result.0)))
                }
            })
        } catch {
            session.report(error)
        }
    }

    // MARK: Magic Select

    @ObservationIgnored private let selector = MagicSelector()
    private(set) var magicPoints: [MagicSelector.Point] = []
    private(set) var isSegmenting = false

    func magicSelect(at point: SIMD2<Double>, positive: Bool) {
        let state = session.state
        guard state.bounds.intersection(PixelRect(x: Int(point.x), y: Int(point.y), width: 1, height: 1)).width > 0 else { return }
        magicPoints.append(MagicSelector.Point(point, positive: positive))
        let points = magicPoints
        do {
            let image = try ImageExporter.flattenedSRGB(state, context: metal)
            let key = documentKey(state)
            let selector = selector
            let bounds = state.bounds
            isSegmenting = true
            run(points.count == 1 ? "Magic Select" : "Magic Select (refine)", {
                try await selector.prepare(image, key: key)
                let mask = try await selector.segment(points)
                return (Selection.from(mask: mask.values.map { $0 / 255 }, rect: bounds), nil)
            }, apply: { [weak self] selection in
                guard let self else { return }
                self.isSegmenting = false
                self.session.document.edit("Magic Select", undoManager: self.session.undoManager) { $0.selection = selection }
            })
        } catch {
            isSegmenting = false
            session.report(error)
        }
    }

    func resetMagicSelect() {
        magicPoints = []
    }

    // MARK: Assistant (see AIController+Agent.swift)
}
