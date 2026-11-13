import AppKit
import GlimmerAI
import GlimmerCore
import GlimmerRender
import SwiftUI
import UniformTypeIdentifiers

struct AIPanel: View {
    @Bindable var session: EditorSession
    let ai: AIController

    @State private var expanded: Set<String> = ["assistant"]

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if !ai.hasAPIKey {
                        KeyBanner()
                    }
                    section("Assistant", id: EditorSession.AISection.assistant.rawValue, symbol: "sparkles") {
                        AssistantView(ai: ai)
                    }
                    section("Generate", id: EditorSession.AISection.generate.rawValue, symbol: "photo.badge.plus") {
                        GenerateView(ai: ai, documentSize: SIMD2(session.state.width, session.state.height))
                    }
                    section("Generative Fill", id: EditorSession.AISection.fill.rawValue, symbol: "paintbrush.pointed") {
                        FillView(ai: ai, hasSelection: session.state.selection != nil)
                    }
                    section("Expand", id: EditorSession.AISection.expand.rawValue, symbol: "arrow.up.left.and.arrow.down.right") {
                        ExpandView(ai: ai, size: SIMD2(session.state.width, session.state.height))
                    }
                    section("Match Color", id: EditorSession.AISection.colorMatch.rawValue, symbol: "eyedropper.halffull") {
                        ColorMatchView(ai: ai)
                    }
                    section("Relight", id: EditorSession.AISection.relight.rawValue, symbol: "lightbulb.max") {
                        RelightView(ai: ai)
                    }
                    section("Clean Up", id: EditorSession.AISection.cleanup.rawValue, symbol: "eraser.line.dashed") {
                        CleanupView(ai: ai)
                    }
                    section("Remove Reflections", id: EditorSession.AISection.reflections.rawValue, symbol: "sun.max.trianglebadge.exclamationmark") {
                        StrengthAction(ai: ai, note: "Removes glare from glass, water and screens — in the selection, or the whole image.",
                                       button: "Remove Reflections", initial: 0.7) { ai.removeReflections(strength: $0) }
                    }
                    section("Harmonize", id: EditorSession.AISection.harmonize.rawValue, symbol: "wand.and.rays") {
                        StrengthAction(ai: ai, note: "Relights and grades the active layer so it sits naturally in the scene below.",
                                       button: "Harmonize Layer", initial: 0.6) { ai.harmonize(strength: $0) }
                    }
                    section("Upscale", id: EditorSession.AISection.upscale.rawValue, symbol: "arrow.up.backward.and.arrow.down.forward") {
                        UpscaleView(ai: ai, size: SIMD2(session.state.width, session.state.height))
                    }
                    section("Presets", id: EditorSession.AISection.presets.rawValue, symbol: "camera.filters") {
                        PresetsView(ai: ai)
                    }
                    section("Lens Blur", id: EditorSession.AISection.lensBlur.rawValue, symbol: "camera.aperture") {
                        LensBlurView(ai: ai)
                    }
                    section("On This Mac", id: "local", symbol: "cpu") {
                        VStack(alignment: .leading, spacing: 8) {
                            Button("Remove Background", systemImage: "person.crop.rectangle") { ai.removeBackground() }
                                .help("Masks the active layer to its subject. Runs on this Mac, free.")
                            Button("Select Subject", systemImage: "person.and.background.dotted") { ai.selectSubject() }
                                .help("Selects the main subject. Runs on this Mac, free.")
                            Button("Magic Select Tool (A)", systemImage: "wand.and.sparkles") { session.tool = .magicSelect }
                                .help("Click an object to select it; ⌥-click to exclude. Return keeps, Esc cancels.")
                        }
                    }
                    JobsView(ai: ai)
                }
                .padding(12)
            }
            .onChange(of: session.aiSection, initial: true) { _, section in
                expanded.insert(section.rawValue)
                withAnimation { proxy.scrollTo(section.rawValue, anchor: .top) }
            }
        }
    }

    private func section<Content: View>(_ title: String, id: String, symbol: String,
                                        @ViewBuilder content: () -> Content) -> some View {
        let body = content()
        return DisclosureGroup(isExpanded: Binding(
            get: { expanded.contains(id) },
            set: { if $0 { expanded.insert(id) } else { expanded.remove(id) } }
        )) {
            body.padding(.top, 6)
        } label: {
            Label(LocalizedStringKey(title), systemImage: symbol).font(.headline)
        }
        .id(id)
    }
}

private struct KeyBanner: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Add your OpenRouter key", systemImage: "key")
                .font(.headline)
            Text("Generative tools call OpenRouter with your own key. On-device tools work without one.")
                .font(.callout)
                .foregroundStyle(.secondary)
            SettingsLink { Text("Open Settings…") }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.yellow.opacity(0.15), in: .rect(cornerRadius: 8))
    }
}

private struct AssistantView: View {
    let ai: AIController
    @State private var text = ""
    @State private var autoRun = UserDefaults.standard.bool(forKey: AIController.autoRunKey)
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(ai.messages.suffix(10)) { message in
                VStack(alignment: .leading, spacing: 6) {
                    Text(message.text)
                        .font(.callout)
                        .textSelection(.enabled)
                    if let plan = message.plan { PlanView(ai: ai, messageID: message.id, plan: plan) }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(message.fromUser ? Color.accentColor.opacity(0.15) : Color.secondary.opacity(0.1),
                            in: .rect(cornerRadius: 8))
                .frame(maxWidth: .infinity, alignment: message.fromUser ? .trailing : .leading)
            }
            if ai.isPlanning {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Planning…").font(.callout).foregroundStyle(.secondary)
                }
            }
            HStack(alignment: .bottom) {
                TextField("Ask for an edit: “moody black & white with a vignette”", text: $text, axis: .vertical)
                    .lineLimit(1...4)
                    .textFieldStyle(.roundedBorder)
                    .focused($focused)
                    .onSubmit(send)
                Button(action: send) {
                    Image(systemName: "arrow.up.circle.fill").font(.title2)
                }
                .buttonStyle(.borderless)
                .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty || ai.isPlanning)
                .keyboardShortcut(.return, modifiers: .command)
                .accessibilityLabel("Send")
            }
            Toggle("Run AI steps without asking", isOn: $autoRun)
                .font(.caption)
                .onChange(of: autoRun) { _, on in ai.autoRunAIPlans = on }
                .help("Plans that only use the editor's own tools always run straight away. Plans with AI jobs (which cost credits) wait for Run unless this is on.")
        }
    }

    private func send() {
        ai.ask(text)
        text = ""
    }
}

/// The assistant's plan as a checklist, with Run / Stop.
private struct PlanView: View {
    let ai: AIController
    let messageID: UUID
    let plan: AgentPlan

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(plan.steps) { step in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    statusIcon(ai.stepStatus[step.id] ?? .pending)
                        .frame(width: 14)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(Self.describe(step)).font(.callout)
                        if case .failed(let message)? = ai.stepStatus[step.id] {
                            Text(message).font(.caption).foregroundStyle(.red)
                        } else if let r = step.rationale {
                            Text(r).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            switch ai.planStatus[messageID] {
            case .proposed?:
                HStack {
                    if plan.usesAI {
                        Label("Uses AI credits", systemImage: "sparkles").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Dismiss") { ai.cancelPlan(messageID) }
                    Button("Run") { ai.runPlan(messageID) }.buttonStyle(.borderedProminent)
                }
                .controlSize(.small)
            case .running?:
                HStack {
                    Spacer()
                    Button("Stop") { ai.cancelPlan(messageID) }.controlSize(.small)
                }
            default: EmptyView()
            }
        }
    }

    @ViewBuilder private func statusIcon(_ status: AIController.StepStatus) -> some View {
        switch status {
        case .pending: Image(systemName: "circle").foregroundStyle(.tertiary)
        case .running: ProgressView().controlSize(.mini)
        case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed: Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red)
        case .skipped: Image(systemName: "minus.circle").foregroundStyle(.tertiary)
        }
    }

    static func describe(_ step: AgentStep) -> String {
        func title(_ s: String?) -> String { (s ?? "").replacingOccurrences(of: "_", with: " ").capitalized }
        return switch step.op {
        case "add_adjustment": AdjustmentKind(rawValue: step.string("type") ?? "")?.title ?? "Adjustment"
        case "apply_filter": FilterKind(rawValue: step.string("type") ?? "")?.title ?? "Filter"
        case "add_layer_effect":
            "Layer style: " + (["dropShadow": "Drop Shadow", "innerShadow": "Inner Shadow", "outerGlow": "Outer Glow",
                                "stroke": "Stroke", "colorOverlay": "Color Overlay"][step.string("type") ?? ""] ?? "Effect")
        case "apply_preset": "Preset: \(step.string("name") ?? "")"
        case "add_text": "Text “\(step.string("text") ?? "")”"
        case "image_edit_composite": "AI edit: \(step.string("instruction") ?? "")"
        case "generate_layer": "Generate: \(step.string("prompt") ?? "")"
        case "remove_background": "Remove background"
        case "select_subject": "Select subject"
        case "inpaint_selection": step.string("mode") == "remove" ? "Remove selected object" : "Fill selection: \(step.string("prompt") ?? "")"
        case "upscale": "Upscale \(Int(step.number("scale") ?? 2))×"
        case "fill": "Fill with \(step.string("color") ?? "")"
        case "set_foreground": "Foreground \(step.string("color") ?? "")"
        case "run_command":
            CommandRegistry.standard.descriptor(for: CommandID(rawValue: step.string("id") ?? ""))?.title ?? title(step.string("id"))
        default: title(step.op)
        }
    }
}

private struct GenerateView: View {
    let ai: AIController
    let documentSize: SIMD2<Int>
    @State private var prompt = ""
    @State private var negative = ""
    @State private var size = "document"

    private var dimensions: (Int, Int) {
        switch size {
        case "square": (1024, 1024)
        case "portrait": (832, 1216)
        case "landscape": (1216, 832)
        default: (documentSize.x, documentSize.y)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("A lighthouse at dusk, film photo", text: $prompt, axis: .vertical)
                .lineLimit(2...5)
                .textFieldStyle(.roundedBorder)
            TextField("Avoid (optional)", text: $negative)
                .textFieldStyle(.roundedBorder)
            Picker("Size", selection: $size) {
                Text("Document").tag("document")
                Text("Square").tag("square")
                Text("Portrait").tag("portrait")
                Text("Landscape").tag("landscape")
            }
            Button("Generate Layer") {
                let (w, h) = dimensions
                ai.generate(prompt: prompt, negative: negative, width: w, height: h)
            }
            .disabled(prompt.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }
}

private struct FillView: View {
    let ai: AIController
    let hasSelection: Bool
    @State private var prompt = ""
    @State private var mode = AIPipelines.InpaintMode.fill
    @State private var reference: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !hasSelection {
                Text("Select an area first with the marquee (M), or Select › Subject.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Picker("Mode", selection: $mode) {
                Text("Fill").tag(AIPipelines.InpaintMode.fill)
                Text("Remove").tag(AIPipelines.InpaintMode.remove)
            }
            .pickerStyle(.segmented)
            if mode == .fill {
                TextField("What should appear? (empty = blend in)", text: $prompt, axis: .vertical)
                    .lineLimit(1...4)
                    .textFieldStyle(.roundedBorder)
                HStack {
                    Button(reference == nil ? "Reference Image…" : "Change Reference…") { chooseReference() }
                    if let reference {
                        Text(reference.lastPathComponent).lineLimit(1).foregroundStyle(.secondary)
                        Button("Clear", systemImage: "xmark.circle.fill") { self.reference = nil }
                            .labelStyle(.iconOnly)
                            .buttonStyle(.borderless)
                    }
                }
                .controlSize(.small)
            }
            Button(mode == .remove ? "Remove Object" : "Fill Selection") {
                ai.fill(mode: mode, prompt: prompt, reference: mode == .fill ? reference : nil)
            }
            .disabled(!hasSelection)
        }
    }

    private func chooseReference() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.begin { response in
            if response == .OK { reference = panel.url }
        }
    }
}

private struct ExpandView: View {
    let ai: AIController
    let size: SIMD2<Int>
    @State private var factor = 1.5
    @State private var custom = false
    @State private var top = 0
    @State private var right = 256
    @State private var bottom = 0
    @State private var left = 256
    @State private var prompt = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Grow", selection: $custom) {
                Text("Evenly").tag(false)
                Text("Per Side").tag(true)
            }
            .pickerStyle(.segmented)
            if custom {
                Grid(alignment: .leading) {
                    GridRow { side("Top", $top); side("Bottom", $bottom) }
                    GridRow { side("Left", $left); side("Right", $right) }
                }
            } else {
                Picker("Size", selection: $factor) {
                    Text("125 %").tag(1.25)
                    Text("150 %").tag(1.5)
                    Text("200 %").tag(2.0)
                }
                .pickerStyle(.segmented)
            }
            TextField("What's beyond the edges? (optional)", text: $prompt)
                .textFieldStyle(.roundedBorder)
            Button("Expand Canvas") { ai.expand(margins: margins, prompt: prompt) }
                .disabled(margins.isEmpty)
            Text("New size: \(size.x + margins.left + margins.right) × \(size.y + margins.top + margins.bottom) px")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var margins: AIPipelines.Margins {
        custom ? AIPipelines.Margins(top: top, right: right, bottom: bottom, left: left)
               : .scaled(width: size.x, height: size.y, factor: factor)
    }

    private func side(_ label: String, _ value: Binding<Int>) -> some View {
        LabeledContent(LocalizedStringKey(label)) {
            TextField(label, value: value, format: .number.grouping(.never))
                .textFieldStyle(.roundedBorder)
                .frame(width: 64)
        }
        .font(.callout)
    }
}

private struct ColorMatchView: View {
    let ai: AIController
    @State private var strength = 1.0

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Gives the active layer the colour grade of a reference image. Runs on this Mac.")
                .font(.callout)
                .foregroundStyle(.secondary)
            ParameterSlider(label: "Strength", value: strength * 100, range: 0...100, step: 1,
                            format: { "\(Int($0)) %" }, set: { strength = $0 / 100 }, commit: {})
            Button("Choose Reference…") {
                let panel = NSOpenPanel()
                panel.allowedContentTypes = [.image]
                panel.begin { response in
                    if response == .OK, let url = panel.url { ai.matchColor(reference: url, strength: strength) }
                }
            }
        }
    }
}

private struct JobsView: View {
    let ai: AIController

    var body: some View {
        if !ai.jobs.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Activity").font(.headline)
                    Spacer()
                    if ai.totalCost > 0 {
                        Text(ai.totalCost, format: .currency(code: "USD").precision(.fractionLength(3)))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .help("OpenRouter cost of this window's jobs")
                    }
                    Button("Clear") { ai.clearFinished() }
                        .controlSize(.small)
                        .disabled(ai.jobs.allSatisfy { $0.status == .running })
                }
                ForEach(ai.jobs) { job in
                    HStack(spacing: 6) {
                        switch job.status {
                        case .running: ProgressView().controlSize(.small)
                        case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        case .failed: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        case .cancelled: Image(systemName: "xmark.circle").foregroundStyle(.secondary)
                        }
                        VStack(alignment: .leading, spacing: 1) {
                            Text(job.title).lineLimit(1).font(.callout)
                            if case .failed(let message) = job.status {
                                Text(message).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                            }
                        }
                        Spacer(minLength: 0)
                        if let cost = job.cost, cost > 0 {
                            Text(cost, format: .currency(code: "USD").precision(.fractionLength(3)))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        if job.status == .running {
                            Button("Cancel", systemImage: "stop.circle") { ai.cancel(job.id) }
                                .labelStyle(.iconOnly)
                                .buttonStyle(.borderless)
                        }
                    }
                }
            }
            .padding(.top, 6)
        }
    }
}


private struct StrengthAction: View {
    let ai: AIController
    let note: String
    let button: String
    let initial: Double
    let action: (Double) -> Void
    @State private var strength: Double?

    var body: some View {
        let value = strength ?? initial
        VStack(alignment: .leading, spacing: 8) {
            Text(note).font(.callout).foregroundStyle(.secondary)
            ParameterSlider(label: "Strength", value: value * 100, range: 0...100, step: 1,
                            format: { "\(Int($0)) %" }, set: { strength = $0 / 100 }, commit: {})
            Button(button) { action(value) }
        }
    }
}

private struct RelightView: View {
    let ai: AIController
    @State private var direction = AIPipelines.LightDirection.left
    @State private var color = SRGBColor(1, 0.9, 0.75)
    @State private var intensity = 0.6
    @State private var environment = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Light from", selection: $direction) {
                ForEach(AIPipelines.LightDirection.allCases, id: \.self) { Text(LocalizedStringKey($0.title)).tag($0) }
            }
            ColorWell(label: "Light color", color: color) { color = $0 }
            ParameterSlider(label: "Intensity", value: intensity * 100, range: 0...100, step: 1,
                            format: { "\(Int($0)) %" }, set: { intensity = $0 / 100 }, commit: {})
            TextField("Environment (optional), e.g. a neon-lit street", text: $environment)
                .textFieldStyle(.roundedBorder)
            Button("Relight") { ai.relight(direction: direction, color: color, intensity: intensity, environment: environment) }
        }
    }
}

private struct CleanupView: View {
    let ai: AIController

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Finds photobombers, litter, signs, cables and dust spots to remove.")
                .font(.callout).foregroundStyle(.secondary)
            Button("Find Distractions") { ai.findDistractions() }
            if let message = ai.distractionMessage {
                Text(message).font(.callout)
            }
            ForEach(ai.distractions) { d in
                HStack {
                    Circle()
                        .fill(d.severity == "high" ? Color.red : (d.severity == "low" ? Color.yellow : Color.orange))
                        .frame(width: 8, height: 8)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(d.label.capitalized).font(.callout)
                        if let r = d.rationale { Text(r).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
                    }
                    Spacer()
                    Button("Select") { ai.selectDistractions([d]) }
                    Button("Remove") { ai.removeDistractions([d]) }
                    Button("Dismiss", systemImage: "xmark") { ai.dismissDistraction(d.id) }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                }
                .controlSize(.small)
            }
            if ai.distractions.count > 1 {
                Button("Remove All") { ai.removeDistractions(ai.distractions) }
            }
        }
    }
}

private struct UpscaleView: View {
    let ai: AIController
    let size: SIMD2<Int>
    @State private var scale = 2
    @State private var enhance = false
    @State private var creativity = 0.3

    var body: some View {
        let out = SIMD2(size.x * scale, size.y * scale)
        let tiles = AIPipelines.enhanceTiles(width: out.x, height: out.y).count
        VStack(alignment: .leading, spacing: 8) {
            Picker("Scale", selection: $scale) {
                Text("2×").tag(2)
                Text("4×").tag(4)
            }
            .pickerStyle(.segmented)
            Text("Result: \(out.x) × \(out.y) px, opened as a new document.")
                .font(.caption).foregroundStyle(.secondary)
            Toggle("Add AI detail", isOn: $enhance)
            if enhance {
                ParameterSlider(label: "Creativity", value: creativity * 100, range: 0...100, step: 1,
                                format: { "\(Int($0)) %" }, set: { creativity = $0 / 100 }, commit: {})
                Text("Runs the image model on \(tiles) tile\(tiles == 1 ? "" : "s").")
                    .font(.caption)
                    .foregroundStyle(tiles > 16 ? .orange : .secondary)
            }
            Button("Upscale") { ai.upscale(scale: scale, enhance: enhance, creativity: creativity) }
                .disabled(enhance && max(out.x, out.y) > 8192)
        }
    }
}

private struct PresetsView: View {
    let ai: AIController

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 8)], spacing: 8) {
            ForEach(Preset.all) { preset in
                Button {
                    ai.applyPreset(preset)
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        LinearGradient(colors: [Color(hex: preset.swatch.0), Color(hex: preset.swatch.1)],
                                       startPoint: .leading, endPoint: .trailing)
                            .frame(height: 28)
                            .clipShape(.rect(cornerRadius: 4))
                        Text(preset.name).font(.caption).lineLimit(1)
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .help(preset.description)
            }
        }
    }
}

private struct LensBlurView: View {
    let ai: AIController
    @State private var p = DocumentEffects.LensBlurParameters()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Estimates depth on this Mac and blurs what's out of focus. The first run downloads a 48 MB model.")
                .font(.callout).foregroundStyle(.secondary)
            ParameterSlider(label: "Focus distance", value: p.focus * 100, range: 0...100, step: 1,
                            format: { $0 > 66 ? "Near" : ($0 < 33 ? "Far" : "Middle") }, set: { p.focus = $0 / 100 }, commit: {})
            ParameterSlider(label: "Focus range", value: p.focusRange * 100, range: 0...60, step: 1,
                            format: { "\(Int($0)) %" }, set: { p.focusRange = $0 / 100 }, commit: {})
            ParameterSlider(label: "Blur", value: p.amount * 1000, range: 2...60, step: 1,
                            format: { String(format: "%.1f %%", $0 / 10) }, set: { p.amount = $0 / 1000 }, commit: {})
            ParameterSlider(label: "Bokeh", value: p.bokeh * 100, range: 0...100, step: 1,
                            format: { "\(Int($0)) %" }, set: { p.bokeh = $0 / 100 }, commit: {})
            Button("Apply Lens Blur") { ai.lensBlur(p) }
        }
    }
}

extension Color {
    init(hex: String) {
        let v = UInt32(hex.trimmingCharacters(in: CharacterSet(charactersIn: "#")), radix: 16) ?? 0
        self.init(.sRGB, red: Double((v >> 16) & 0xff) / 255, green: Double((v >> 8) & 0xff) / 255, blue: Double(v & 0xff) / 255)
    }
}
