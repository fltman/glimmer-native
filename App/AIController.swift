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
    }

    private(set) var jobs: [Job] = []
    private(set) var messages: [Message] = []
    var totalCost: Double { jobs.compactMap(\.cost).reduce(0, +) }
    var isBusy: Bool { jobs.contains { $0.status == .running } }

    @ObservationIgnored unowned let session: EditorSession

    init(session: EditorSession) {
        self.session = session
    }

    // MARK: Setup

    var hasAPIKey: Bool {
        ((try? KeychainSecretStore.openRouterAPIKey.read()) ?? nil)?.isEmpty == false
    }

    private func imageModel() throws -> ImageModel {
        guard let key = try KeychainSecretStore.openRouterAPIKey.read(), !key.isEmpty else {
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

    // MARK: Assistant

    private static let generateVerbs = ["add", "insert", "generate", "create", "draw", "place", "put", "make a", "make an"]

    /// Routes plain language: "add a red bird" generates a layer, anything else
    /// edits the whole image. (The planning agent arrives in phase 8.)
    func ask(_ text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        messages.append(Message(fromUser: true, text: text))
        let lower = text.lowercased()
        let isEmptyCanvas = session.state.allLayers.allSatisfy { layer in
            if case .raster(let g) = layer.content { return g.isEmpty || g.tiles.values.allSatisfy { if case .solid = $0 { true } else { false } } }
            return true
        }
        if isEmptyCanvas || Self.generateVerbs.contains(where: { lower.hasPrefix($0) }) {
            messages.append(Message(fromUser: false, text: "Generating a new layer…"))
            generate(prompt: text, negative: "", width: session.state.width, height: session.state.height)
        } else if session.state.selection != nil {
            messages.append(Message(fromUser: false, text: "Filling the selection…"))
            fill(mode: .fill, prompt: text, reference: nil)
        } else {
            messages.append(Message(fromUser: false, text: "Editing the image…"))
            editImage(instruction: text)
        }
    }
}
