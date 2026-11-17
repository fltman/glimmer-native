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
        /// A service bills for this job (a picture service, or a text service that isn't on this Mac).
        var paid = false
        @ObservationIgnored var task: Task<Void, Never>?
    }

    struct Message: Identifiable {
        let id = UUID()
        let fromUser: Bool
        var text: String
        /// The assistant's plan, shown as a checklist under the message.
        var plan: AgentPlan?
        /// A single command the on-device model chose for a request that doesn't name it: it
        /// waits for Run. The palette entry's id; nil once it has been run or dismissed.
        var pendingCommand: String?
        /// The exact words of a refusal, as the agent API gives them: shown on request under a message that says the same thing plainly.
        var exactWords: String?
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
    /// Edits proposed for the current image, and whether they're being fetched.
    var suggestions: [AgentPlanner.Suggestion] = []
    var isSuggesting = false
    /// On-device analysis of the open image (see AIController+Smart).
    var insights: SmartAnalysis.Insights?
    @ObservationIgnored var insightsKey: Int?
    @ObservationIgnored var insightsTask: Task<Void, Never>?
    var savedActions = SavedAction.load() { didSet { SavedAction.store(savedActions) } }
    @ObservationIgnored var agentHistory: [(user: String, reply: String)] = []
    @ObservationIgnored var planTask: Task<Void, Never>?
    var totalCost: Double { jobs.compactMap(\.cost).reduce(0, +) }
    /// Finished paid jobs whose service's answer carried no cost: never summed as if they had one, and counted beside the sum.
    var jobsWithoutPrice: Int { jobs.filter { $0.paid && $0.status == .done && ($0.cost ?? 0) <= 0 }.count }
    var isBusy: Bool { jobs.contains { $0.status == .running } }

    @ObservationIgnored unowned let session: EditorSession
    /// What the step being run reports in its API result (`info`); reset before each step.
    @ObservationIgnored var stepInfo: [String: Any]?

    init(session: EditorSession) {
        self.session = session
    }

    // MARK: Setup

    var hasAPIKey: Bool { (try? Self.apiKey()) != nil }
    /// Said once per window: the chosen text model can't take pictures.
    @ObservationIgnored var saidModelCantSee = false

    /// The OpenRouter key from the Keychain. Debug builds also accept the
    /// `OPENROUTER_API_KEY` environment variable, so test runs never store a key.
    static func apiKey() throws -> String? {
        if let key = try ProviderKeys.keychain.key(for: "openrouter") { return key }
        #if DEBUG
        if let key = ProcessInfo.processInfo.environment["OPENROUTER_API_KEY"], !key.isEmpty { return key }
        #endif
        return nil
    }

    // MARK: Text: which service and model (the register is `AIProvider`)

    static let textProviderKey = "ai.textProvider"
    static func textModelKey(_ slug: String) -> String { slug == "openrouter" ? AIDefaults.textModelKey : "ai.textModel.\(slug)" }

    /// The service chosen for text in Settings, if it is offered; otherwise OpenRouter.
    static var textProvider: AIProvider {
        let slug = UserDefaults.standard.string(forKey: textProviderKey) ?? "openrouter"
        if let p = AIProvider.named(slug), p.offers(.text) { return p }
        return .openRouter
    }

    /// The model chosen for `provider`, and what its service's list said it can do (nil: the list didn't say).
    static func chosenTextModel(for provider: AIProvider) -> (id: String, tools: Bool?, vision: Bool?) {
        let d = UserDefaults.standard, key = textModelKey(provider.slug)
        let id = d.string(forKey: key) ?? (provider.slug == "openrouter" ? AIDefaults.textModel : "")
        // `bool(forKey:)` also reads a value given as a launch argument ("NO"); nil means the list didn't say.
        func flag(_ name: String) -> Bool? { d.object(forKey: key + name) == nil ? nil : d.bool(forKey: key + name) }
        return (id, flag(".tools"), flag(".vision"))
    }

    struct TextSetupError: LocalizedError { let errorDescription: String? }

    /// The model every text request goes to (the Assistant, suggestions, Find Distractions).
    /// The one place a text service is chosen; nothing else constructs one.
    func textModel() throws -> any TextModel { try Self.textModel(for: Self.textProvider) }

    /// The model chosen in Settings for `provider`, with its key read for this one use.
    static func textModel(for provider: AIProvider) throws -> any TextModel {
        if provider.slug == "ollama" {
            let chosen = chosenTextModel(for: provider).id
            guard !chosen.isEmpty else { throw TextSetupError(errorDescription: String(localized: "Choose a \(provider.name) model in Settings › AI.")) }
            let address = UserDefaults.standard.string(forKey: "ai.address.ollama").flatMap(URL.init) ?? URL(string: provider.baseURL)!
            guard let made = provider.textModel(key: "", model: chosen, baseURL: address) else {
                throw TextSetupError(errorDescription: String(localized: "Glimmer can't use \(provider.name) for text yet."))
            }
            return made
        }
        let key: String?
        if provider.slug == "openrouter" {
            key = try apiKey()
        } else {
            key = provider.needsKey ? try ProviderKeys.keychain.key(for: provider.slug) : ""
        }
        guard let key else {
            if provider.slug == "openrouter" { throw OpenRouterError.missingAPIKey }
            throw TextSetupError(errorDescription: provider.missingKeyMessage)
        }
        let model = chosenTextModel(for: provider).id
        guard !model.isEmpty else {
            throw TextSetupError(errorDescription: String(localized: "Choose a \(provider.name) model in Settings › AI."))
        }
        // OpenRouter keeps its endpoint setting; the others go to their own address.
        guard let made = provider.textModel(key: key, model: model, baseURL: provider.slug == "openrouter" ? AIDefaults.endpoint : nil) else {
            throw TextSetupError(errorDescription: String(localized: "Glimmer can't use \(provider.name) for text yet."))
        }
        return made
    }

    /// Whether a text request can be made at all (a key where one is needed, and a model).
    var hasTextModel: Bool { (try? textModel()) != nil }

    static let imageProviderKey = "ai.imageProvider"
    static func imageModelKey(_ slug: String) -> String { "ai.imageModel.\(slug)" }
    static func imageEditModelKey(_ slug: String) -> String { "ai.imageEditModel.\(slug)" }
    /// Set when the person has agreed to what the picture features send to this service.
    static func imageToldKey(_ slug: String) -> String { "ai.imageNoticeShown.\(slug)" }

    /// What the picture features send to `provider`, said before it is used (the-apps/PROVIDERS.md, rule 7).
    static func imageNotice(for provider: AIProvider) -> String {
        var parts = [String(localized: "Generate, Edit with Prompt, Generative Fill and the other picture features send your prompt and the pictures they work on (the document or the selected part of it, and any reference pictures) to \(provider.name) (\(provider.host)).")]
        if let note = provider.termsNote { parts.append(note) }
        parts.append(String(localized: "\(provider.name) bills your key for each picture."))
        return parts.joined(separator: " ")
    }

    // MARK: Unknown price (the-apps/SIBLINGS.md, "Okänt pris")

    /// The service the picture features go to.
    static var imageProvider: AIProvider {
        if let slug = UserDefaults.standard.string(forKey: imageProviderKey), let p = AIProvider.named(slug), p.offers(.image) { return p }
        return .openRouter
    }

    /// Set when the person has ticked, once for this service, that it states no price in advance. Taken back in Settings › AI.
    static func unknownPriceKey(_ slug: String) -> String { "ai.unknownPriceAgreed.\(slug)" }

    /// Whether a paid picture job may start from the window: the price is known, or the person has made the tick for this service.
    static var unknownPriceAgreed: Bool {
        let p = imageProvider
        return PaidPrice.knownInAdvance(service: p.slug) || UserDefaults.standard.bool(forKey: unknownPriceKey(p.slug))
    }

    /// True while steps from the agent API run with `"allowUnknownPrice": true`: that call's own word, never remembered.
    @ObservationIgnored var agentAllowsUnknownPrice = false

    private func imageModel() throws -> ImageModel {
        // The last stop before a paid picture job; the buttons that lead here are grey until the tick is made.
        guard Self.unknownPriceAgreed || agentAllowsUnknownPrice else {
            let name = Self.imageProvider.name
            throw TextSetupError(errorDescription: String(localized: "\(name) does not state a price in advance. Tick that you know in Settings › AI, and run it again."))
        }
        // Another image service, when one is chosen. For a test:
        // `-ai.imageProvider openai -ai.imageModel.openai <id>` (fal: also `-ai.imageEditModel.fal <id>`).
        let d = UserDefaults.standard
        if let slug = d.string(forKey: Self.imageProviderKey), slug != "openrouter", let provider = AIProvider.named(slug) {
            if provider.offers(.image) {
                // What goes to the service was said, and agreed to, when it was chosen in Settings.
                guard d.bool(forKey: Self.imageToldKey(slug)) else {
                    throw TextSetupError(errorDescription: String(localized: "Choose \(provider.name) again in Settings › AI and confirm what is sent to it."))
                }
                guard let key = try ProviderKeys.keychain.key(for: slug) else { throw TextSetupError(errorDescription: provider.missingKeyMessage) }
                guard let id = d.string(forKey: Self.imageModelKey(slug)), !id.isEmpty,
                      let model = provider.imageModel(key: key, model: id, editModel: d.string(forKey: Self.imageEditModelKey(slug))) else {
                    throw TextSetupError(errorDescription: String(localized: "Choose a \(provider.name) model in Settings › AI."))
                }
                return model
            }
        }
        guard let key = try Self.apiKey() else {
            throw OpenRouterError.missingAPIKey
        }
        let model = UserDefaults.standard.string(forKey: AIDefaults.imageModelKey) ?? AIDefaults.imageModel
        // The documented Image API is built and tested against made-up answers; it is switched on
        // by a setting (`-ai.openRouterImageRoute images`) until a real call through it has been made.
        let route = OpenRouterImageModel.Route(rawValue: UserDefaults.standard.string(forKey: "ai.openRouterImageRoute") ?? "") ?? .chat
        return OpenRouterImageModel(client: OpenRouterClient(apiKey: key), model: model, route: route)
    }

    var metal: MetalContext {
        get throws {
            guard let m = MetalContext.shared else { throw RenderError.noMetalDevice }
            return m
        }
    }

    // MARK: Jobs

    /// Runs `work` off the main actor; `apply` lands the result on the main actor.
    func run<T: Sendable>(paid: Bool = false, _ title: String,
                                  _ work: @escaping @Sendable () async throws -> (T, Double?),
                                  apply: @escaping @MainActor (T) throws -> Void) {
        var job = Job(title: title)
        job.paid = paid
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

    #if DEBUG
    /// For `showFixture("jobs")`: a job list with every state in it.
    func showFixtureJobs() {
        var running = Job(title: "Heal Selection"), failed = Job(title: "Generate"), done = Job(title: "Remove Background"), cancelled = Job(title: "Upscale")
        // A paid job whose service's answer carried no cost: not in the sum, counted beside it.
        var unpriced = Job(title: "Relight"); unpriced.status = .done; unpriced.paid = true
        running.status = .running
        failed.status = .failed("OpenRouter rejected the API key.")
        done.status = .done; done.cost = 0.134
        cancelled.status = .cancelled
        jobs = [running, failed, done, unpriced, cancelled]
    }

    /// Takes the fixture's jobs away again (they are not real: nothing is running).
    func clearFixtureJobs() { jobs = [] }
    #endif

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
        // The job finishes outside any user event: an undo step of its own.
        session.document.edit(action, undoManager: session.undoManager, separateStep: true) {
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
            run(paid: true, String(localized: "Generate “\(String(prompt.prefix(40)))”"), {
                // A fresh seed each time: the result cache keys on it, so the same prompt gives a new picture.
                let r = try await AIPipelines.generate(prompt: prompt, negative: negative, width: width, height: height,
                                                       seed: Int.random(in: 1..<Int(Int32.max)), model: model)
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
            run(paid: true, String(localized: "Edit “\(String(instruction.prefix(40)))”"), {
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
            let title = mode == .remove ? "Remove object" : (prompt.isEmpty ? "Generative fill" : String(localized: "Fill “\(String(prompt.prefix(40)))”"))
            run(paid: true, title, {
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
            run(paid: true, "Expand", {
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
            let layer = Layer(name: layerName("Expanded"), content: .raster(tiles))
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
            run(paid: true, String(localized: "Relight (\(direction.title.lowercased()))"), {
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
            run(paid: true, "Remove reflections", {
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
            run(paid: true, String(localized: "Harmonize “\(name)”"), {
                let r = try await AIPipelines.harmonize(foreground: fg, background: bg, strength: strength, model: model)
                return (r.image, r.cost)
            }, apply: { [weak self] image in
                guard let self else { return }
                let tiles = try ImageImporter.tiles(from: image.cgImage, origin: SIMD2(roi.x, roi.y))
                self.session.document.edit("Harmonize", undoManager: self.session.undoManager) {
                    $0.updateLayer(id) { $0.isVisible = false }
                    $0.insertLayerAboveActive(Layer(name: String(localized: "\(name) (harmonized)"), content: .raster(tiles)))
                }
            })
        } catch {
            session.report(error)
        }
    }

    /// Opens an upscaled copy as a new document: Lanczos on the GPU or
    /// Real-ESRGAN on this Mac, optionally followed by an AI detail pass.
    func upscale(scale: Int, neural: Bool = false, enhance: Bool, creativity: Double) {
        let state = session.state
        do {
            let metal = try metal
            let title = neural ? String(localized: "Upscale \(scale)× (Real-ESRGAN)") : String(localized: "Upscale \(scale)×")
            if !enhance && !neural {
                run(title, {
                    (try DocumentEffects.upscale(state, scale: scale, context: metal), nil)
                }, apply: { grid in
                    let layer = Layer(name: String(localized: "Upscaled \(scale)×"), content: .raster(grid))
                    DocumentOpener.shared.createDocument(DocumentState(width: state.width * scale, height: state.height * scale,
                                                                       layers: [layer]))
                })
                return
            }
            let model = enhance ? try imageModel() : nil
            let source = try composite(state)
            run(paid: enhance, enhance ? title + " with AI detail" : title, {
                let base = neural
                    ? try await RealESRGAN.upscale(source, scale: scale)
                    : source.resized(width: source.width * scale, height: source.height * scale)
                guard let model else { return (base, nil) }
                let r = try await AIPipelines.enhance(base, creativity: creativity, model: model)
                return (r.image, r.cost)
            }, apply: { image in
                let tiles = try ImageImporter.tiles(from: image.cgImage)
                DocumentOpener.shared.createDocument(DocumentState(width: image.width, height: image.height,
                                                                   layers: [Layer(name: String(localized: "Upscaled \(scale)×"), content: .raster(tiles))]))
            })
        } catch {
            session.report(error)
        }
    }

    private(set) var distractions: [AIPipelines.Distraction] = []
    private(set) var distractionMessage: String?

    func findDistractions() {
        gateTextRequest(needsPicture: true) { [weak self] in self?.sendDistractionRequest() }
    }

    private func sendDistractionRequest() {
        do {
            let model = try textModel()
            let source = try composite(session.state)
            distractions = []
            distractionMessage = nil
            run(paid: Self.textProvider.slug != "ollama", "Find distractions", {
                let r = try await AIPipelines.findDistractions(source, model: model)
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

    func documentKey(_ state: DocumentState) -> Int {
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
                    $0.insertLayerAboveActive(Layer(name: layerName("Lens Blur"), content: .raster(result.0)))
                }
            })
        } catch {
            session.report(error)
        }
    }

    // MARK: Live lens blur

    /// A lens blur being tuned: the sliders re-render a preview layer until Apply or Cancel.
    private(set) var lensBlurLive: (previewID: UUID, base: DocumentState, depth: [Float])?
    private(set) var isPreparingLensBlur = false
    @ObservationIgnored private var lensBlurTask: Task<Void, Never>?

    var isLensBlurLive: Bool { lensBlurLive != nil }

    /// Estimates depth (once per image), then shows the blur on the canvas.
    func beginLensBlur(_ parameters: DocumentEffects.LensBlurParameters) {
        guard lensBlurLive == nil, !isPreparingLensBlur else { return }
        session.commitLiveEdit()
        let state = session.state
        do {
            let metal = try metal
            let image = try ImageExporter.flattenedSRGB(state, context: metal)
            let key = documentKey(state)
            let cached = depthCache?.key == key ? depthCache?.depth : nil
            isPreparingLensBlur = true
            run("Estimating depth", {
                if let cached { return (cached, nil) }
                return (try await DepthEstimator.depth(of: image).values.map { $0 / 255 }, nil)
            }, apply: { [weak self] depth in
                guard let self else { return }
                self.isPreparingLensBlur = false
                self.depthCache = (key, depth)
                // The image changed while the depth was being estimated: start over rather than blur stale pixels.
                guard self.documentKey(self.session.state) == key else { return }
                let id = UUID()
                self.lensBlurLive = (id, self.session.state, depth)
                // A preview layer outside the undo history; Apply turns it into a real step.
                self.session.document.state.layers.append(Layer(id: id, name: "Lens Blur", content: .raster(TileGrid())))
                self.updateLensBlur(parameters, showDepth: false)
            })
        } catch {
            isPreparingLensBlur = false
            session.report(error)
        }
    }

    /// Re-renders the preview for new settings, or shows the depth map instead.
    func updateLensBlur(_ parameters: DocumentEffects.LensBlurParameters, showDepth: Bool) {
        guard let live = lensBlurLive, let metal = try? metal else { return }
        lensBlurTask?.cancel()
        lensBlurTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(60))
            guard !Task.isCancelled else { return }
            let grid = await Task.detached(priority: .userInitiated) { () -> TileGrid? in
                if showDepth { return Self.depthTiles(live.depth, width: live.base.width, height: live.base.height) }
                return try? DocumentEffects.lensBlur(live.base, depth: live.depth, parameters: parameters, context: metal)
            }.value
            guard !Task.isCancelled, let self, let grid, self.lensBlurLive?.previewID == live.previewID else { return }
            self.session.document.state.updateLayer(live.previewID) { $0.content = .raster(grid) }
        }
    }

    /// The depth map as a grey image: white is near, black is far.
    private nonisolated static func depthTiles(_ depth: [Float], width: Int, height: Int) -> TileGrid? {
        guard depth.count == width * height else { return nil }
        var rgba = [UInt8](repeating: 255, count: width * height * 4)
        for i in 0..<(width * height) {
            let v = UInt8(min(max(depth[i], 0), 1) * 255)
            rgba[i * 4] = v; rgba[i * 4 + 1] = v; rgba[i * 4 + 2] = v
        }
        guard let provider = CGDataProvider(data: Data(rgba) as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else { return nil }
        return try? ImageImporter.tiles(from: image, origin: .zero)
    }

    /// Keeps the blur as a new layer (one undo step) or throws the preview away.
    func endLensBlur(apply: Bool, parameters: DocumentEffects.LensBlurParameters) {
        guard let live = lensBlurLive else { return }
        lensBlurTask?.cancel()
        lensBlurLive = nil
        _ = session.document.state.removeLayer(live.previewID)
        guard apply, let metal = try? metal else { return }
        // Render with the final settings: the preview may have been a step behind, or showing depth.
        run("Lens blur", {
            (try DocumentEffects.lensBlur(live.base, depth: live.depth, parameters: parameters, context: metal), nil)
        }, apply: { [weak self] grid in
            guard let self else { return }
            self.session.document.edit("Lens Blur", undoManager: self.session.undoManager) {
                $0.insertLayerAboveActive(Layer(name: layerName("Lens Blur"), content: .raster(grid)))
            }
        })
    }

    // MARK: Magic Select

    @ObservationIgnored let selector = MagicSelector()
    private(set) var magicPoints: [MagicSelector.Point] = []
    var isSegmenting = false

    func magicSelect(at point: SIMD2<Double>, positive: Bool) {
        let state = session.state
        guard state.bounds.intersection(PixelRect(x: Int(point.x), y: Int(point.y), width: 1, height: 1)).width > 0 else { return }
        if magicPoints.isEmpty { selectionBeforeMagic = state.selection }
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
        selectionBeforeMagic = nil
    }

    /// Esc: forget the points and put back the selection that was there before Magic Select.
    func cancelMagicSelect() {
        let before = selectionBeforeMagic
        resetMagicSelect()
        session.document.edit("Cancel Magic Select", undoManager: session.undoManager) { $0.selection = before }
    }

    @ObservationIgnored private var selectionBeforeMagic: Selection?

    // MARK: Assistant (see AIController+Agent.swift)
}
