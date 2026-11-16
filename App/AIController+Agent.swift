import AppKit
import GlimmerAI
import GlimmerCore
import GlimmerRender
import ImageIO

/// The assistant: plans with the text model, shows the plan, runs it step by step.
extension AIController {
    static let autoRunKey = "ai.autoRunPlans"
    static let onDeviceRoutingKey = "ai.routeOnDevice"
    static let showImageKey = "ai.assistantSeesImage"
    static let reviewKey = "ai.reviewResults"

    /// The planner gets a small picture of the document (default on).
    var assistantSeesImage: Bool { UserDefaults.standard.object(forKey: Self.showImageKey) as? Bool ?? true }
    /// After a plan ran, the model compares before and after and may adjust once (default on).
    var reviewsResults: Bool { UserDefaults.standard.object(forKey: Self.reviewKey) as? Bool ?? true }

    /// The document as a JPEG of at most 1024 px, for the text model to look at.
    nonisolated static func snapshotJPEG(_ state: DocumentState, metal: MetalContext) -> Data? {
        guard let full = try? ImageExporter.flatten(state, context: metal),
              let flat = try? ImageExporter.convert(full, options: ExportOptions(format: .jpeg)),
              let small = EditorSession.downscaled(flat, maxSide: 1024) else { return nil }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, small, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        return CGImageDestinationFinalize(dest) ? data as Data : nil
    }

    /// Try Apple's on-device model first: one-command requests and "make a
    /// picture of …" don't need the paid planner.
    var routesOnDevice: Bool {
        OnDeviceRouter.isAvailable && (UserDefaults.standard.object(forKey: Self.onDeviceRoutingKey) as? Bool ?? true)
    }

    /// Runs plans without asking first. Plans that only use the editor's own
    /// tools always run straight away; this setting covers plans with AI jobs.
    var autoRunAIPlans: Bool {
        get { UserDefaults.standard.bool(forKey: Self.autoRunKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.autoRunKey) }
    }

    private var agentContext: AgentContext {
        let state = session.state
        let layer = state.activeLayer
        let kind: String = switch layer?.content {
        case .raster where layer?.raw != nil: "raw"   // a RAW layer: `develop_raw` is offered for it
        case .raster: "raster"
        case .adjustment: "adjustment"
        case .group: "group"
        case .fill: "fill"
        case .smart: "smart object"
        case .text: "text"
        case nil: "none"
        }
        return AgentContext(width: state.width, height: state.height, layerCount: state.allLayers.count,
                            hasSelection: state.selection != nil, activeLayerKind: kind, activeLayerName: layer?.name ?? "—")
    }

    /// Palette items the on-device router must never pick for a request.
    nonisolated static func notRoutable(_ item: PaletteItem) -> Bool {
        guard case .command(let id) = item.action else { return false }
        if id == .toggleGammaBlending || id == .batchProcess { return true }
        guard let category = CommandRegistry.standard.descriptor(for: id)?.category else { return false }
        return category == .view || category == .file
    }

    func ask(_ text: String) {
        let goal = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !goal.isEmpty, !isPlanning else { return }
        messages.append(Message(fromUser: true, text: goal))
        #if DEBUG
        // Development hook: a raw JSON plan runs without the network (exercises the executor).
        if goal.hasPrefix("{"), let plan = try? AgentPlanner.parsePlan(goal) {
            receive(plan, goal: goal)
            return
        }
        #endif
        if routesOnDevice {
            isPlanning = true
            planTask = Task { [weak self] in
                guard let self else { return }
                // Commands that only open a dialog ("Vignette…") don't carry out a request by themselves,
                // and settings, views and files never do ("fix the colors" is not "Blend Colors in Gamma Space").
                let candidates = CommandSearch.candidates(for: goal, in: Palette.allItems).filter {
                    !$0.title.hasSuffix("…") && !Self.notRoutable($0)
                }.map {
                    OnDeviceRouter.Candidate(id: $0.id, title: $0.title, subtitle: $0.subtitle)
                }
                let decision = (try? await OnDeviceRouter.route(goal, candidates: candidates)) ?? .assistant
                if Task.isCancelled { self.isPlanning = false; return }
                switch decision {
                case .run(let id):
                    // A command the request doesn't name is shown and waits for Run (PlanCheck).
                    if let item = Palette.allItems.first(where: { $0.id == id }), !Self.requestNames(goal, item) {
                        self.isPlanning = false
                        var message = Message(fromUser: false, text: String(localized: "I think you mean \(String(localized: String.LocalizationValue(item.title))). You didn't name it, so it waits for you."))
                        message.pendingCommand = item.id
                        self.messages.append(message)
                        self.agentHistory.append((goal, "Suggested \(item.title)."))
                        return
                    }
                    if let item = Palette.allItems.first(where: { $0.id == id }), self.session.runPaletteItem(item) {
                        self.isPlanning = false
                        self.messages.append(Message(fromUser: false, text: String(localized: "Done: \(String(localized: String.LocalizationValue(item.title))) (on this Mac, no AI cost).")))
                        self.agentHistory.append((goal, "Ran \(item.title)."))
                        return
                    }
                case .generate(let prompt):
                    if self.hasAPIKey {
                        self.isPlanning = false
                        self.messages.append(Message(fromUser: false, text: String(localized: "Generating “\(prompt)” as a new layer.")))
                        self.agentHistory.append((goal, "Generated a new layer: \(prompt)"))
                        self.generate(prompt: prompt, negative: "", width: self.session.state.width, height: self.session.state.height)
                        return
                    }
                case .assistant:
                    break
                }
                self.isPlanning = false
                self.planWithOpenRouter(goal)
            }
            return
        }
        planWithOpenRouter(goal)
    }

    /// Sends the goal to the text model for a plan.
    private func planWithOpenRouter(_ goal: String) {
        gateTextRequest(needsPicture: false) { [weak self] in self?.sendPlanRequest(goal) }
    }

    private func sendPlanRequest(_ goal: String) {
        let model: any TextModel
        do {
            model = try textModel()
        } catch {
            let why = error is OpenRouterError ? String(localized: "Add your OpenRouter API key in Settings › AI to use the assistant.")
                : (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            messages.append(Message(fromUser: false, text: why))
            return
        }
        // What the service's own list says the model can't do is said before anything is sent.
        let provider = Self.textProvider
        let abilities = Self.chosenTextModel(for: provider)
        if abilities.tools == false {
            messages.append(Message(fromUser: false, text: String(localized: "\(provider.name) lists \(abilities.id) as a model without tool calls, and the Assistant works by calling Glimmer's tools. Choose another model in Settings › AI.")))
            return
        }
        let canSee = abilities.vision != false
        if !canSee, !saidModelCantSee {
            saidModelCantSee = true
            messages.append(Message(fromUser: false, text: String(localized: "\(abilities.id) can't take pictures, so the Assistant plans without looking at the document.")))
        }
        let context = agentContext
        let history = agentHistory
        let state = session.state
        let metal = assistantSeesImage ? MetalContext.shared : nil
        isPlanning = true
        // The reply streams into this message; `receive` then attaches the plan.
        let placeholder = Message(fromUser: false, text: "")
        let messageID = placeholder.id
        planTask = Task { [weak self] in
            do {
                let image = canSee ? await Task.detached { metal.flatMap { Self.snapshotJPEG(state, metal: $0) } }.value : nil
                // Running siblings (Jämmer, Flimmer) add their operations as tools; found off the main thread.
                let siblings = await SiblingClient.shared.toolbox()
                let (plan, _) = try await AgentPlanner.plan(goal: goal, context: context, history: history, image: image,
                                                            siblings: siblings.tools, siblingContext: siblings.context,
                                                            model: model) { text in
                    Task { @MainActor in
                        guard let self else { return }
                        if let i = self.messages.firstIndex(where: { $0.id == messageID }) {
                            self.messages[i].text = text
                        } else if self.isPlanning {
                            var m = placeholder
                            m.text = text
                            self.messages.append(m)
                        }
                    }
                }
                // Let queued text updates land before the final message replaces them.
                await Task.yield()
                self?.messages.removeAll { $0.id == messageID }
                self?.receive(plan, goal: goal)
            } catch is CancellationError {
                self?.messages.removeAll { $0.id == messageID }
            } catch {
                self?.messages.removeAll { $0.id == messageID }
                let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                self?.messages.append(Message(fromUser: false, text: "I couldn't plan that: \(message)"))
            }
            self?.isPlanning = false
        }
    }

    /// Whether the request names this palette entry (its title, a search word of its command).
    nonisolated static func requestNames(_ goal: String, _ item: PaletteItem) -> Bool {
        var keywords: [String] = []
        if case .command(let id) = item.action { keywords = CommandRegistry.standard.descriptor(for: id)?.keywords ?? [] }
        if case .command(.autoEnhance) = item.action { keywords += PlanCheck.words["auto_enhance"] ?? [] }
        return PlanCheck.namesCommand(goal, title: item.title, keywords: keywords)
            || PlanCheck.namesCommand(goal, title: String(localized: String.LocalizationValue(item.title)), keywords: [])
    }

    static func commandTitle(_ id: String) -> String? { CommandRegistry.standard.descriptor(for: CommandID(rawValue: id))?.title }

    /// Runs the command a message is holding for confirmation.
    func runPendingCommand(_ messageID: UUID) {
        guard let i = messages.firstIndex(where: { $0.id == messageID }), let id = messages[i].pendingCommand else { return }
        messages[i].pendingCommand = nil
        if let item = Palette.allItems.first(where: { $0.id == id }), session.runPaletteItem(item) {
            messages[i].text = String(localized: "Done: \(String(localized: String.LocalizationValue(item.title))) (on this Mac, no AI cost).")
        } else {
            messages[i].text = String(localized: "That isn't available right now.")
        }
    }

    func dismissPendingCommand(_ messageID: UUID) {
        guard let i = messages.firstIndex(where: { $0.id == messageID }) else { return }
        messages[i].pendingCommand = nil
    }

    private func receive(_ plan: AgentPlan, goal: String) {
        let summary = plan.message ?? (plan.steps.isEmpty ? "I'm not sure how to do that." : "Here's the plan.")
        var text = summary
        if !plan.removedFigures.isEmpty { text += " " + String(localized: "Glimmer left out a figure it could not verify.") }
        if !plan.droppedOps.isEmpty {
            text += " (Skipped steps the editor can't do: \(plan.droppedOps.joined(separator: ", ")).)"
        }
        // A plan runs at once only when the request names every step that changes the document.
        var plan = plan
        var named = PlanCheck.runsAtOnce(plan, request: goal, commandTitle: Self.commandTitle)
        // An extra that stands by itself (Auto Enhance beside what was asked) is held back as
        // an offer, and what was asked runs.
        var offered: [AgentStep] = []
        if !named, let split = PlanCheck.withoutExtras(plan, request: goal, commandTitle: Self.commandTitle) {
            plan = split.runs
            offered = split.offered
            named = true
        }
        // A step with a parameter its operation doesn't have would be refused part-way: the plan is shown and none of it runs.
        let refused = plan.strayParameters.first ?? plan.steps.lazy.compactMap { StepParameters.stray(in: $0)?.message }.first
        if let refused {
            text += " " + String(localized: "This plan can't run: \(refused) Nothing was changed. Ask again, perhaps in other words.")
        } else if !named, !plan.usesAI { text += " " + String(localized: "Some of these steps aren't named in what you asked, so the plan waits for Run.") }
        let message = Message(fromUser: false, text: text, plan: plan.steps.isEmpty ? nil : plan)
        messages.append(message)
        agentHistory.append((goal, summary + (plan.steps.isEmpty ? "" : " Steps: " + plan.steps.map(\.op).joined(separator: ", "))))
        guard !plan.steps.isEmpty else { return }
        if refused != nil {
            for step in plan.steps { stepStatus[step.id] = .skipped }
            planStatus[message.id] = .failed
            return
        }
        for step in plan.steps { stepStatus[step.id] = .pending }
        planStatus[message.id] = .proposed
        if named, !plan.usesAI || autoRunAIPlans { runPlan(message.id) }
        // Each held extra is a plan of its own that waits: it is run only if the person says so,
        // and then on the picture as it is by then.
        for step in offered {
            let title = AgentPlanner.op(named: step.op).map { $0.name.replacingOccurrences(of: "_", with: " ").capitalized } ?? step.op
            let offer = Message(fromUser: false, text: String(localized: "The assistant also suggests \(title), which you didn't ask for. Run it now on the picture as it is?"),
                                plan: AgentPlan(steps: [step]))
            messages.append(offer)
            stepStatus[step.id] = .pending
            planStatus[offer.id] = .proposed
        }
    }

    func runPlan(_ messageID: UUID) {
        guard let plan = messages.first(where: { $0.id == messageID })?.plan, planStatus[messageID] == .proposed else { return }
        planStatus[messageID] = .running
        // The whole plan is one undo step, named after the request.
        let index = messages.firstIndex { $0.id == messageID } ?? messages.endIndex
        let goal = messages[..<index].last(where: \.fromUser)?.text ?? ""
        session.document.beginTransaction(Self.undoName(for: goal))
        let before = session.state
        planTask = Task { [weak self] in
            guard let self else { return }
            // Corrections from the quality check land in the same undo step.
            defer { self.session.document.endTransaction(undoManager: self.session.undoManager) }
            let failed = await self.run(plan.steps)
            self.planStatus[messageID] = Task.isCancelled ? .cancelled : (failed ? .failed : .finished)
            if !failed, !Task.isCancelled { await self.review(goal: goal, steps: plan.steps, before: before) }
        }
    }

    /// Runs steps in order; returns true when one failed (the rest are skipped).
    private func run(_ steps: [AgentStep]) async -> Bool {
        var failed = false
        for step in steps {
            if Task.isCancelled || failed {
                stepStatus[step.id] = .skipped
                continue
            }
            stepStatus[step.id] = .running
            do {
                try await execute(step)
                stepStatus[step.id] = .done
            } catch {
                failed = true
                stepStatus[step.id] = .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
                noteSiblingFailure(error)
            }
        }
        return failed
    }

    // MARK: Agent API

    struct APIStepResult {
        let op: String
        let status: String  // done, failed, skipped
        let error: String?
        var reason: String? = nil
        var hard = false
        /// Facts a step reports about what it did (style_text: matches and ranges).
        var info: [String: Any]? = nil
    }

    /// Runs steps from the local agent API as one undo step. Stops at the first
    /// failure and reports the rest as skipped.
    func runAPISteps(_ steps: [AgentStep], progress: ((Int) -> Void)? = nil) async -> [APIStepResult] {
        session.commitLiveEdit()
        session.document.beginTransaction(String(localized: "Agent Edit"))
        defer { session.document.endTransaction(undoManager: session.undoManager) }
        var results: [APIStepResult] = []
        var stopped = false
        for (i, step) in steps.enumerated() {
            if stopped || Task.isCancelled {
                stopped = true
                results.append(APIStepResult(op: step.op, status: Task.isCancelled ? "cancelled" : "skipped", error: nil))
                continue
            }
            do {
                stepInfo = nil
                try await execute(step)
                results.append(APIStepResult(op: step.op, status: "done", error: nil, info: stepInfo))
            } catch is CancellationError {
                stopped = true
                results.append(APIStepResult(op: step.op, status: "cancelled", error: nil))
            } catch {
                stopped = true
                results.append(APIStepResult(op: step.op, status: "failed",
                                             error: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription,
                                             reason: (error as? StepError)?.reason, hard: (error as? StepError)?.hard ?? false))
            }
            progress?(i + 1)
        }
        return results
    }

    /// Cancels the AI jobs this window is running (used when an API job is cancelled).
    func cancelRunningJobs() {
        for job in jobs where job.status == .running { cancel(job.id) }
    }

    /// The quality check: the model compares before and after and may adjust once.
    private func review(goal: String, steps: [AgentStep], before: DocumentState) async {
        guard reviewsResults, !goal.isEmpty, let metal = MetalContext.shared,
              let model = try? textModel() else { return }
        let after = session.state
        isPlanning = true
        defer { isPlanning = false }
        let images = await Task.detached {
            (Self.snapshotJPEG(before, metal: metal), Self.snapshotJPEG(after, metal: metal))
        }.value
        guard let b = images.0, let a = images.1,
              let plan = try? await AgentPlanner.review(goal: goal, steps: steps, before: b, after: a,
                                                        model: model),
              !Task.isCancelled else { return }
        guard !plan.steps.isEmpty else {
            // Approved: nothing to add to the conversation.
            return
        }
        let message = Message(fromUser: false, text: plan.message ?? String(localized: "Adjusting the result."), plan: plan)
        messages.append(message)
        agentHistory.append((goal, "Adjusted: " + plan.steps.map(\.op).joined(separator: ", ")))
        for step in plan.steps { stepStatus[step.id] = .pending }
        planStatus[message.id] = .running
        let failed = await run(plan.steps)
        planStatus[message.id] = Task.isCancelled ? .cancelled : (failed ? .failed : .finished)
    }

    // MARK: Suggestions

    /// Asks the model to look at the image and propose three edits.
    func suggestEdits() {
        gateTextRequest(needsPicture: true) { [weak self] in self?.sendSuggestionRequest() }
    }

    private func sendSuggestionRequest() {
        guard !isSuggesting, let metal = MetalContext.shared, let model = try? textModel() else { return }
        let state = session.state
        let language = Locale.current.language.languageCode?.identifier ?? "en"
        isSuggesting = true
        Task { [weak self] in
            let image = await Task.detached { Self.snapshotJPEG(state, metal: metal) }.value
            var found: [AgentPlanner.Suggestion] = []
            if let image {
                found = (try? await AgentPlanner.suggestions(image: image, language: language,
                                                             model: model)) ?? []
            }
            self?.suggestions = found
            self?.isSuggesting = false
        }
    }

    // MARK: Saved actions

    /// Keeps a finished plan (and any corrections that followed it) as a reusable action.
    /// Whether this plan is the quality check's follow-up to the plan before it. It is saved
    /// together with that plan, not by itself.
    func isCorrection(_ messageID: UUID) -> Bool {
        guard let index = messages.firstIndex(where: { $0.id == messageID }), index > 0 else { return false }
        let previous = messages[index - 1]
        return !previous.fromUser && previous.plan != nil
    }

    func saveAction(from messageID: UUID) {
        guard let index = messages.firstIndex(where: { $0.id == messageID }), let plan = messages[index].plan else { return }
        var steps = plan.steps
        // Corrections from the quality check directly after belong to the same result.
        for later in messages[(index + 1)...] {
            guard !later.fromUser, let extra = later.plan else { break }
            steps += extra.steps
        }
        let goal = messages[..<index].last(where: \.fromUser)?.text ?? plan.message ?? "Action"
        let name = goal.count > 48 ? String(goal.prefix(47)) + "…" : goal
        savedActions.removeAll { $0.name == name }
        savedActions.append(SavedAction(name: name, steps: steps))
    }

    /// Runs a saved action again: no planning, one undo step.
    func run(_ action: SavedAction) {
        guard !isPlanning else { return }
        let steps = action.steps.map { AgentStep(op: $0.op, params: $0.params, rationale: $0.rationale) }
        messages.append(Message(fromUser: true, text: action.name))
        let plan = AgentPlan(steps: steps)
        let message = Message(fromUser: false, text: String(localized: "Running the saved action."), plan: plan)
        messages.append(message)
        for step in steps { stepStatus[step.id] = .pending }
        planStatus[message.id] = .running
        session.document.beginTransaction(action.name)
        planTask = Task { [weak self] in
            guard let self else { return }
            defer { self.session.document.endTransaction(undoManager: self.session.undoManager) }
            let failed = await self.run(steps)
            self.planStatus[message.id] = Task.isCancelled ? .cancelled : (failed ? .failed : .finished)
        }
    }

    /// "Assistant: make it warmer" (shortened).
    static func undoName(for goal: String) -> String {
        let short = goal.count > 40 ? String(goal.prefix(39)) + "…" : goal
        return short.isEmpty ? String(localized: "Assistant") : String(localized: "Assistant: \(short)")
    }

    func cancelPlan(_ messageID: UUID) {
        if planStatus[messageID] == .running {
            planTask?.cancel()
            for job in jobs where job.status == .running { cancel(job.id) }
        }
        if planStatus[messageID] == .proposed { planStatus[messageID] = .cancelled }
    }

    // MARK: Executor

    struct StepError: LocalizedError {
        let errorDescription: String?
        /// A machine-readable reason (the API adds it to its 422 step_failed answer).
        var reason: String?
        /// True when no parameter of the step lifts the refusal (the API passes it on as `hard`).
        var hard = false
        init(_ message: String, reason: String? = nil) {
            errorDescription = message
            self.reason = reason
        }
    }

    /// Runs one step; AI steps wait until their job has finished.
    private func execute(_ step: AgentStep) async throws {
        // Refused before anything is applied, whoever sent the step (the API checks a whole request first; a plan says it in the step).
        if let stray = StepParameters.stray(in: step) { throw StepError(stray.message, reason: "unknown_parameter") }
        let s = session
        let before = jobs.first?.id
        switch step.op {
        case "add_adjustment":
            guard let kind = AdjustmentKind(rawValue: step.string("type") ?? "") else { throw StepError("Unknown adjustment.") }
            let adjustment = Self.adjustment(kind, step.object("params"))
            s.addLayer(Layer(name: layerName(kind.title), content: .adjustment(adjustment)), actionName: String(localized: "New \(String(localized: String.LocalizationValue(kind.title)))"))
        case "apply_filter":
            guard let kind = FilterKind(rawValue: step.string("type") ?? "") else { throw StepError("Unknown filter.") }
            try ensurePixelLayer()
            var values: [String: Double] = [:]
            for (k, v) in step.object("params") { if let n = v.number { values[k] = n } }
            s.applyFilter(FilterSettings(kind, values))
        case "add_layer_effect":
            try addLayerEffect(step.string("type") ?? "", step.object("params"))
        case "apply_preset":
            let name = (step.string("name") ?? "").lowercased()
            guard let preset = Preset.all.first(where: { $0.name.lowercased() == name || $0.id == name }) else {
                throw StepError("Unknown preset “\(name)”.")
            }
            applyPreset(preset)
        case "add_text":
            try addText(step)
        case "image_edit_composite":
            editImage(instruction: step.string("instruction") ?? "")
        case "generate_layer":
            generate(prompt: step.string("prompt") ?? "", negative: "", width: s.state.width, height: s.state.height)
        case "auto_enhance":
            try await performAutoEnhance()
        case "auto_color":
            try await performAutoColor()
        case "select_people":
            try await performSelectPeople()
        case "select_sky":
            guard try await performSelectSky() else { throw StepError("No sky found along the top of the image.") }
        case "remove_background":
            // A smart object (an image an agent just added) is cut out as it is; only a layer
            // without a picture of its own sends the step to the nearest pixel layer.
            if case .smart = s.state.activeLayer?.content {} else { try ensurePixelLayer() }
            removeBackground()
        case "select_subject":
            selectSubject()
        case "inpaint_selection":
            guard s.state.selection != nil else { throw StepError("This step needs a selection.") }
            fill(mode: step.string("mode") == "remove" ? .remove : .fill, prompt: step.string("prompt") ?? "", reference: nil)
        case "upscale":
            let scale = (step.number("scale") ?? 2) >= 3 ? 4 : 2
            upscale(scale: scale, neural: max(s.state.width, s.state.height) * scale <= 16_384, enhance: false, creativity: 0)
        case "fill":
            guard let color = parseHexColor(step.string("color")) else { throw StepError("Invalid colour.") }
            try ensurePixelLayer()
            try fillSelection(color)
        case "set_foreground":
            guard let color = parseHexColor(step.string("color")) else { throw StepError("Invalid colour.") }
            s.foreground = color
        case "select_all": s.perform(.selectAll)
        case "deselect": s.perform(.deselect)
        case "invert_selection": s.perform(.invertSelection)
        case "feather_selection":
            guard s.state.selection != nil else { throw StepError("There's no selection to feather.") }
            s.modifySelection(.featherSelection, radius: step.number("radius") ?? 10)
        case "select_layer":
            let key = (step.string("name") ?? "").trimmingCharacters(in: .whitespaces)
            guard let layer = s.state.allLayers.reversed().first(where: {
                $0.id.uuidString.caseInsensitiveCompare(key) == .orderedSame || $0.name.caseInsensitiveCompare(key) == .orderedSame
            }) else { throw StepError("No layer named “\(key)”.") }
            s.setActiveLayer(layer.id)
        case "new_layer":
            s.perform(.newLayer)
            if let name = step.string("name"), let id = s.state.activeLayerID { s.rename(id, to: name) }
        case "add_waveform":
            try await performAddWaveform(step)
        case "transform_layer":
            try performTransformLayer(step)
        case "style_text":
            try performStyleText(step)
        case "crop":
            try performCrop(step)
        case "resize_image":
            try performResizeImage(step)
        case "resize_canvas":
            try performResizeCanvas(step)
        case "select_rect":
            try performSelectRect(step)
        case "set_layer":
            try performSetLayer(step)
        #if GLIMMER_RAW
        case "develop_raw":
            try await performDevelopRaw(step)
        #endif
        #if GLIMMER_HEAL
        case "heal_selection":
            try await performHealSelection(step)
        #endif
        case let op where SiblingApp.split(tool: op) != nil:
            try await performSiblingTool(step)
        case "run_command":
            let id = CommandID(rawValue: step.string("id") ?? "")
            guard AgentPlanner.runnableCommands.contains(where: { $0.id == id }) else { throw StepError("Unknown command.") }
            guard s.canPerform(id) else { throw StepError("“\(id.rawValue)” isn't available right now.") }
            s.perform(id)
        default:
            throw StepError("Unknown step.")
        }
        // Wait for any AI job the step started.
        if jobs.first?.id != before, let job = jobs.first {
            while let current = jobs.first(where: { $0.id == job.id }), current.status == .running {
                try await Task.sleep(for: .milliseconds(200))
            }
            if case .failed(let message)? = jobs.first(where: { $0.id == job.id })?.status { throw StepError(message) }
            if jobs.first(where: { $0.id == job.id })?.status == .cancelled { throw CancellationError() }
        }
    }

    /// Filters and fills need pixels: fall back to the topmost visible pixel layer.
    private func ensurePixelLayer() throws {
        if session.state.activeLayer?.isRaster == true { return }
        guard let layer = session.state.allLayers.reversed().first(where: { $0.isRaster && $0.isVisible && !$0.tiles.isEmpty }) else {
            throw StepError("There's no pixel layer to work on.")
        }
        session.setActiveLayer(layer.id)
    }

    private func fillSelection(_ color: SRGBColor) throws {
        guard let metal = MetalContext.shared, let layer = session.state.activeLayer else { return }
        let bounds = session.state.selection?.bounds(in: session.state.bounds) ?? session.state.bounds
        let tiles = try PixelOps(context: metal).run(.paint, on: layer.tiles, selection: session.state.selection,
                                                     coords: bounds.tileCoords, color: SIMD4(color.linear, 1))
        session.edit("Fill") { $0.updateLayer(layer.id) { $0.tiles = tiles } }
    }

    private func addText(_ step: AgentStep) throws {
        let state = session.state
        let size = step.number("size") ?? max(Double(state.height) * 0.08, 12)
        var text = TextLayer(string: step.string("text") ?? "Text", size: size,
                             color: parseHexColor(step.string("color")) ?? session.foreground, alignment: .center, origin: .zero)
        if let font = step.string("fontName")?.trimmingCharacters(in: .whitespaces), !font.isEmpty {
            guard TextLayer.fontExists(font) else {
                throw StepError("No font named “\(font)” is installed (use its PostScript name).", reason: "unknown_font")
            }
            text.fontName = font
        }
        if step.params["bold"]?.bool == true { text.setBold(true, in: NSRange(location: 0, length: (text.string as NSString).length)) }
        let layout = text.layoutSize
        let y: Double = switch step.string("position") {
        case "top": Double(state.height) * 0.08
        case "bottom": Double(state.height) * 0.92 - layout.height
        default: (Double(state.height) - layout.height) / 2
        }
        text.origin = SIMD2(step.number("x") ?? (Double(state.width) - layout.width) / 2, step.number("y") ?? y)
        let name = String(text.string.prefix(32))
        let layer = Layer(name: name, content: .text(text))
        session.addLayer(layer, actionName: "Add Text")
        var info: [String: Any] = ["layer": layer.id.uuidString]
        if let b = AgentRouter.layerBounds(layer) { info["bounds"] = ["x": b.x, "y": b.y, "width": b.width, "height": b.height] }
        stepInfo = info
    }

    nonisolated static func adjustment(_ kind: AdjustmentKind, _ params: [String: JSONValue]) -> Adjustment {
        var adjustment = Adjustment(kind)
        for (k, v) in params {
            if case .bool(let b) = v { adjustment.flags[k] = b } else if let n = v.number { adjustment.numbers[k] = n }
            if let c = parseHexColor(v.string) { adjustment.colors[k] = c }
        }
        return adjustment
    }

    /// Applies a web-style effect patch to a layer's styles: `enabled` → isEnabled, hex colours → SRGBColor.
    nonisolated static func patched(_ effects: LayerEffects, type: String, _ params: [String: JSONValue]) throws -> LayerEffects {
        var effects = effects
        func patch<T: Codable>(_ value: T) throws -> T {
            var dict = (try JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any]) ?? [:]
            for (key, v) in params {
                let k = key == "enabled" ? "isEnabled" : key
                if let c = parseHexColor(v.string) {
                    dict[k] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(c))
                } else {
                    dict[k] = v.any
                }
            }
            let data = try JSONSerialization.data(withJSONObject: dict)
            return (try? JSONDecoder().decode(T.self, from: data)) ?? value
        }
        switch type {
        case "dropShadow": effects.dropShadow = try patch(effects.dropShadow ?? ShadowEffect())
        case "innerShadow": effects.innerShadow = try patch(effects.innerShadow ?? ShadowEffect())
        case "outerGlow": effects.outerGlow = try patch(effects.outerGlow ?? GlowEffect())
        case "stroke": effects.stroke = try patch(effects.stroke ?? StrokeEffect())
        case "colorOverlay": effects.colorOverlay = try patch(effects.colorOverlay ?? ColorOverlayEffect())
        default: throw StepError("Unknown layer effect.")
        }
        return effects
    }

    private func addLayerEffect(_ type: String, _ params: [String: JSONValue]) throws {
        guard let layer = session.state.activeLayer else { throw StepError("Select a layer first.") }
        let effects = try Self.patched(layer.effects, type: type, params)
        session.edit("Layer Style") { $0.updateLayer(layer.id) { $0.effects = effects } }
    }
}
