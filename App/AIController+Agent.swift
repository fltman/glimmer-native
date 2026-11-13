import AppKit
import GlimmerAI
import GlimmerCore
import GlimmerRender

/// The assistant: plans with the text model, shows the plan, runs it step by step.
extension AIController {
    static let autoRunKey = "ai.autoRunPlans"

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
        guard let key = try? KeychainSecretStore.openRouterAPIKey.read(), !key.isEmpty else {
            messages.append(Message(fromUser: false, text: "Add your OpenRouter API key in Settings › AI to use the assistant."))
            return
        }
        let model = UserDefaults.standard.string(forKey: AIDefaults.textModelKey) ?? AIDefaults.textModel
        let context = agentContext
        let history = agentHistory
        isPlanning = true
        planTask = Task { [weak self] in
            do {
                let (plan, _) = try await AgentPlanner.plan(goal: goal, context: context, history: history,
                                                            client: OpenRouterClient(apiKey: key), model: model)
                self?.receive(plan, goal: goal)
            } catch {
                let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                self?.messages.append(Message(fromUser: false, text: "I couldn't plan that: \(message)"))
            }
            self?.isPlanning = false
        }
    }

    private func receive(_ plan: AgentPlan, goal: String) {
        let summary = plan.message ?? (plan.steps.isEmpty ? "I'm not sure how to do that." : "Here's the plan.")
        var text = summary
        if !plan.droppedOps.isEmpty {
            text += " (Skipped steps the editor can't do: \(plan.droppedOps.joined(separator: ", ")).)"
        }
        let message = Message(fromUser: false, text: text, plan: plan.steps.isEmpty ? nil : plan)
        messages.append(message)
        agentHistory.append((goal, summary + (plan.steps.isEmpty ? "" : " Steps: " + plan.steps.map(\.op).joined(separator: ", "))))
        guard !plan.steps.isEmpty else { return }
        for step in plan.steps { stepStatus[step.id] = .pending }
        planStatus[message.id] = .proposed
        if !plan.usesAI || autoRunAIPlans { runPlan(message.id) }
    }

    func runPlan(_ messageID: UUID) {
        guard let plan = messages.first(where: { $0.id == messageID })?.plan, planStatus[messageID] == .proposed else { return }
        planStatus[messageID] = .running
        planTask = Task { [weak self] in
            guard let self else { return }
            var failed = false
            for step in plan.steps {
                if Task.isCancelled || failed {
                    self.stepStatus[step.id] = .skipped
                    continue
                }
                self.stepStatus[step.id] = .running
                do {
                    try await self.execute(step)
                    self.stepStatus[step.id] = .done
                } catch {
                    failed = true
                    self.stepStatus[step.id] = .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
                }
            }
            self.planStatus[messageID] = Task.isCancelled ? .cancelled : (failed ? .failed : .finished)
        }
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
        init(_ message: String) { errorDescription = message }
    }

    /// Runs one step; AI steps wait until their job has finished.
    private func execute(_ step: AgentStep) async throws {
        let s = session
        let before = jobs.first?.id
        switch step.op {
        case "add_adjustment":
            guard let kind = AdjustmentKind(rawValue: step.string("type") ?? "") else { throw StepError("Unknown adjustment.") }
            var adjustment = Adjustment(kind)
            for (k, v) in step.object("params") {
                if case .bool(let b) = v { adjustment.flags[k] = b } else if let n = v.number { adjustment.numbers[k] = n }
                if let c = parseHexColor(v.string) { adjustment.colors[k] = c }
            }
            s.addLayer(Layer(name: kind.title, content: .adjustment(adjustment)), actionName: "New \(kind.title)")
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
            addText(step)
        case "image_edit_composite":
            editImage(instruction: step.string("instruction") ?? "")
        case "generate_layer":
            generate(prompt: step.string("prompt") ?? "", negative: "", width: s.state.width, height: s.state.height)
        case "remove_background":
            try ensurePixelLayer()
            removeBackground()
        case "select_subject":
            selectSubject()
        case "inpaint_selection":
            guard s.state.selection != nil else { throw StepError("This step needs a selection.") }
            fill(mode: step.string("mode") == "remove" ? .remove : .fill, prompt: step.string("prompt") ?? "", reference: nil)
        case "upscale":
            upscale(scale: (step.number("scale") ?? 2) >= 3 ? 4 : 2, enhance: false, creativity: 0)
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
        case "new_layer":
            s.perform(.newLayer)
            if let name = step.string("name"), let id = s.state.activeLayerID { s.rename(id, to: name) }
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

    private func addText(_ step: AgentStep) {
        let state = session.state
        let size = step.number("size") ?? max(Double(state.height) * 0.08, 12)
        var text = TextLayer(string: step.string("text") ?? "Text", size: size,
                             color: parseHexColor(step.string("color")) ?? session.foreground, alignment: .center, origin: .zero)
        let layout = text.layoutSize
        let y: Double = switch step.string("position") {
        case "top": Double(state.height) * 0.08
        case "bottom": Double(state.height) * 0.92 - layout.height
        default: (Double(state.height) - layout.height) / 2
        }
        text.origin = SIMD2((Double(state.width) - layout.width) / 2, y)
        let name = String(text.string.prefix(32))
        session.addLayer(Layer(name: name, content: .text(text)), actionName: "Add Text")
    }

    /// Applies a web-style effect patch: `enabled` → isEnabled, hex colours → SRGBColor.
    private func addLayerEffect(_ type: String, _ params: [String: JSONValue]) throws {
        guard let layer = session.state.activeLayer else { throw StepError("Select a layer first.") }
        var effects = layer.effects
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
        session.edit("Layer Style") { $0.updateLayer(layer.id) { $0.effects = effects } }
    }
}
