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
                            Button("Auto Enhance", systemImage: "wand.and.rays") { ai.autoEnhance() }
                                .help("Corrects tone and colour as editable adjustment layers. Runs on this Mac, free. ⇧⌘L")
                            Button("Auto Color", systemImage: "eyedropper.halffull") { ai.autoColor() }
                                .help("Removes a colour cast with a Color Balance layer. Runs on this Mac, free. ⇧⌘B")
                            Button("Auto Straighten", systemImage: "level") { ai.autoStraighten() }
                                .help("Finds a tilted horizon and opens Crop, levelled. Runs on this Mac, free.")
                            Button("Suggest Crop", systemImage: "crop") { ai.suggestCrop() }
                                .help("Frames the subject at the crop's aspect ratio. Runs on this Mac, free.")
                            Divider()
                            Button("Remove Background", systemImage: "person.crop.rectangle") { ai.removeBackground() }
                                .help("Masks the active layer to its subject. Runs on this Mac, free.")
                            Button("Select Subject", systemImage: "person.and.background.dotted") { ai.selectSubject() }
                                .help("Selects the main subject. Runs on this Mac, free.")
                            Button("Select People", systemImage: "person.2") { ai.selectPeople() }
                                .help("Selects every person, with finer edges than Select Subject. Runs on this Mac, free.")
                            Button("Select Sky", systemImage: "cloud.sun") { ai.selectSky() }
                                .help("Selects the sky with the depth map and Segment Anything. Runs on this Mac, free.")
                            Button("Straighten Document", systemImage: "doc.viewfinder") { ai.straightenDocument() }
                                .help("Flattens a document, sign or screen seen at an angle into a new document. Runs on this Mac, free.")
                            Button("Image Text to Layers", systemImage: "text.viewfinder") { ai.textToLayers() }
                                .help("Turns the text in the image into editable text layers. Runs on this Mac, free.")
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
                .accessibilityAddTraits(.isHeader)
            Text("Generative tools call OpenRouter with your own key. On-device tools work without one.")
                .font(.callout)
                .foregroundStyle(.primary)  // .secondary is 4.4 : 1 on the yellow
            SettingsLink { Text("Open Settings…") }
                .simultaneousGesture(TapGesture().onEnded { UserDefaults.standard.set("ai", forKey: SettingsView.tabKey) })
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
            HStack(alignment: .top) {
                Text("Chat to edit the whole image, or say “add a …” to generate a layer.")
                    .font(.caption)
                    .foregroundStyle(Theme.muted)
                Spacer(minLength: 8)
                Button(autoRun ? "AUTO-EDIT ON" : "AUTO-EDIT OFF") { autoRun.toggle() }
                    .buttonStyle(.plain)
                    .font(.caption2.weight(.semibold))
                    .kerning(0.6)
                    .padding(.horizontal, 8)
                    .frame(minHeight: 22)
                    .foregroundStyle(autoRun ? Theme.ink : Theme.muted)
                    .background(autoRun ? Theme.accent.opacity(0.35) : Theme.raised, in: .rect(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(autoRun ? Theme.accent : Theme.edge))
                    .help("Plans that only use the editor's own tools always run straight away. Plans with AI jobs (which cost credits) wait for Run unless this is on.")
                    .accessibilityLabel("Auto-edit")
                    .accessibilityValue(autoRun ? Text("On") : Text("Off"))
                    .accessibilityAddTraits(.isToggle)
                    .accessibilityHint("Runs plans with paid AI steps without asking first.")
                    .onChange(of: autoRun) { _, on in ai.autoRunAIPlans = on }
            }
            if ai.messages.isEmpty {
                Text("Hi — I'm your editing assistant. Tell me what you want: I'll adjust the photo (“make it warmer”), edit its content (“make the sky pink”), generate a new layer (“add a red bird”), or plan several steps and check the result.")
                    .font(.callout)
                    .foregroundStyle(Theme.ink.opacity(0.85))
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.raised, in: .rect(cornerRadius: 12))
            }
            ForEach(ai.messages.suffix(10)) { message in
                VStack(alignment: .leading, spacing: 6) {
                    // No accessibility label on the text itself: on selectable text it makes SwiftUI ask
                    // itself for the label without end, and the app crashes as soon as VoiceOver (or
                    // any assistive tool) reads the message. Who is speaking is said by the group.
                    Text(message.text)
                        .font(.callout)
                        .textSelection(.enabled)
                    if let plan = message.plan { PlanView(ai: ai, messageID: message.id, plan: plan) }
                    if let exact = message.exactWords {
                        DisclosureGroup("Exact words") {
                            // Said in the person's language, so the English below reads as what it is.
                            Text("The agent API's own message, in English:").font(.caption).foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Text(verbatim: exact).font(.caption.monospaced()).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .font(.caption)
                    }
                    if message.pendingCommand != nil {
                        HStack {
                            Spacer()
                            Button("Dismiss") { ai.dismissPendingCommand(message.id) }
                            Button("Run") { ai.runPendingCommand(message.id) }.buttonStyle(.borderedProminent)
                        }
                        .controlSize(.small)
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityLabel(message.fromUser ? Text("You") : Text("Assistant"))
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .foregroundStyle(message.fromUser ? Color.white : Theme.ink)
                .background(message.fromUser ? Theme.accentFill : Theme.raised, in: .rect(cornerRadius: 12))
                .padding(message.fromUser ? .leading : .trailing, 28)
                .frame(maxWidth: .infinity, alignment: message.fromUser ? .trailing : .leading)
            }
            if !ai.savedActions.isEmpty {
                Menu("Actions", systemImage: "bookmark") {
                    ForEach(ai.savedActions) { action in
                        Button(action.name) { ai.run(action) }
                    }
                    Divider()
                    Menu("Delete") {
                        ForEach(ai.savedActions) { action in
                            Button(action.name, role: .destructive) { ai.savedActions.removeAll { $0.id == action.id } }
                        }
                    }
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
            if ai.hasAPIKey {
                HStack(spacing: 6) {
                    Button("Suggest Edits", systemImage: "wand.and.sparkles") { ai.suggestEdits() }
                        .disabled(ai.isSuggesting)
                        .help("Let the assistant look at the image and propose three edits")
                    if ai.isSuggesting { ProgressView().controlSize(.small).accessibilityLabel("Looking at the image") }
                }
                .controlSize(.small)
                ForEach(ai.suggestions) { suggestion in
                    Button {
                        ai.suggestions = []
                        ai.ask(suggestion.goal)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(suggestion.title).font(.callout.weight(.medium))
                            Text(suggestion.goal).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.leading)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(6)
                        .background(Color.accentColor.opacity(0.08), in: .rect(cornerRadius: 8))
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .disabled(ai.isPlanning)
                }
            }
            if ai.isPlanning {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Planning…").font(.callout).foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
            }
            HStack(alignment: .bottom, spacing: 8) {
                TextField("e.g. make the sky a warm sunset — or: add a red bird", text: $text, axis: .vertical)
                    .lineLimit(2...5)
                    .textFieldStyle(.plain)
                    .padding(10)
                    .background(Theme.background, in: .rect(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.fieldEdge))
                    .focused($focused)
                    .onSubmit(send)
                    .accessibilityLabel("Message to the assistant")
                Button("Send", action: send)
                    .buttonStyle(.plain)
                    .font(.callout.weight(.medium))
                    .padding(.horizontal, 14)
                    .frame(minHeight: 36)
                    .foregroundStyle(.white)
                    .background(Theme.accentFill.opacity(canSend ? 1 : 0.4), in: .rect(cornerRadius: 8))
                    .disabled(!canSend)
                    .keyboardShortcut(.return, modifiers: .command)
            }
            Text("Enter to send")
                .font(.caption2)
                .foregroundStyle(Theme.muted)
            // What a request to the chosen text service costs, as far as its own list said; nothing when it runs on this Mac.
            if let price = AIController.textPriceLine(for: AIController.textProvider) {
                Text(verbatim: price)
                    .font(.caption2)
                    .foregroundStyle(Theme.muted)
            }
        }
    }

    private var canSend: Bool {
        !text.trimmingCharacters(in: .whitespaces).isEmpty && !ai.isPlanning
    }

    private func send() {
        ai.ask(text)
        text = ""
    }
}

/// The assistant's plan as a checklist, with Run / Stop.
struct PlanView: View {
    let ai: AIController
    let messageID: UUID
    let plan: AgentPlan

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(plan.steps) { step in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    statusIcon(ai.stepStatus[step.id] ?? .pending)
                        .frame(width: 14)
                        .accessibilityLabel(Self.statusName(ai.stepStatus[step.id] ?? .pending))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(Self.describe(step)).font(.callout)
                        if case .failed(let message)? = ai.stepStatus[step.id] {
                            Text(message).font(.caption).foregroundStyle(.red)
                        } else if let r = step.rationale {
                            Text(verbatim: Self.note(r)).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                // One stop per step: its status, what it does and why.
                .accessibilityElement(children: .combine)
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
                        .needsUnknownPriceTick(plan.usesAI)
                }
                .controlSize(.small)
                if plan.usesAI { UnknownPriceNote() }
            case .running?:
                HStack {
                    Spacer()
                    Button("Stop") { ai.cancelPlan(messageID) }.controlSize(.small)
                }
            case .finished? where !ai.isCorrection(messageID):
                HStack {
                    Spacer()
                    Button("Save as Action", systemImage: "bookmark") { ai.saveAction(from: messageID) }
                        .controlSize(.small)
                        .buttonStyle(.borderless)
                        .help("Keep these steps to run again from ⌘K or the Actions menu")
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

    static func statusName(_ status: AIController.StepStatus) -> Text {
        switch status {
        case .pending: Text("Waiting")
        case .running: Text("Running")
        case .done: Text("Done")
        case .failed: Text("Failed")
        case .skipped: Text("Skipped")
        }
    }

    /// A step's name in the plan, in the person's language. Where the step is something the menus
    /// have, it is called what the menu calls it (the same catalogue entry), so "Crop" in a plan
    /// reads as the menu item does. What the model wrote (a text, a prompt) is shown as it is.
    static func describe(_ step: AgentStep) -> String {
        /// A title as the menus and panels show it: the catalogue's text for it, without the dots of a menu item.
        func menu(_ title: String) -> String {
            String(localized: String.LocalizationValue(title)).replacingOccurrences(of: "…", with: "")
        }
        func plain(_ s: String?) -> String { menu((s ?? "").replacingOccurrences(of: "_", with: " ").capitalized) }
        let effects = ["dropShadow": "Drop Shadow", "innerShadow": "Inner Shadow", "outerGlow": "Outer Glow", "stroke": "Stroke", "colorOverlay": "Color Overlay"]
        var menuTitles = ["crop": "Crop", "resize_image": "Image Size…", "resize_canvas": "Canvas Size…", "auto_enhance": "Auto Enhance", "auto_color": "Auto Color",
                          "select_people": "Select People", "select_sky": "Select Sky", "select_subject": "Select Subject", "remove_background": "Remove Background",
                          "transform_layer": "Free Transform", "add_waveform": "Add Waveform", "deselect": "Deselect"]
        // Features a release can be built without (Config/Features.xcconfig): their names are not in a build that lacks them.
        #if GLIMMER_HEAL
        menuTitles["heal_selection"] = "Heal Selection"
        #endif
        #if GLIMMER_RAW
        menuTitles["develop_raw"] = "Develop…"
        #endif
        switch step.op {
        case "add_adjustment": return AdjustmentKind(rawValue: step.string("type") ?? "").map { menu($0.title) } ?? String(localized: "Adjustment")
        case "apply_filter": return FilterKind(rawValue: step.string("type") ?? "").map { menu($0.title) } ?? String(localized: "Filter")
        case "add_layer_effect":
            let effect = effects[step.string("type") ?? ""].map(menu) ?? String(localized: "Effect")
            return String(localized: "Layer style: \(effect)")
        case "apply_preset": return String(localized: "Preset: \(step.string("name") ?? "")")
        case "add_text": return String(localized: "Text “\(step.string("text") ?? "")”")
        case "style_text": return step.string("match").map { String(localized: "Style “\($0)”") } ?? String(localized: "Style text")
        case "image_edit_composite": return String(localized: "AI edit: \(step.string("instruction") ?? "")")
        case "generate_layer": return String(localized: "Generate: \(step.string("prompt") ?? "")")
        case "select_layer": return String(localized: "Select layer “\(step.string("name") ?? "")”")
        case "inpaint_selection":
            return step.string("mode") == "remove" ? String(localized: "Remove selected object") : String(localized: "Fill selection: \(step.string("prompt") ?? "")")
        case "upscale": return String(localized: "Upscale \(Int(step.number("scale") ?? 2))×")
        case "fill": return String(localized: "Fill with \(step.string("color") ?? "")")
        case "set_foreground": return String(localized: "Foreground \(step.string("color") ?? "")")
        case "run_command":
            return CommandRegistry.standard.descriptor(for: CommandID(rawValue: step.string("id") ?? "")).map { menu($0.title) } ?? plain(step.string("id"))
        default:
            return menuTitles[step.op].map(menu) ?? plain(step.op)
        }
    }

    /// A step's note with Glimmer's own remarks in the person's language. The rest of it is the model's words, shown as they are.
    static func note(_ rationale: String) -> String {
        var text = rationale
        for own in [StepParameters.strayNote, StepParameters.uncheckedNote, PlanCheck.filledNote] {
            text = text.replacingOccurrences(of: own, with: PersonMessage.text(own))
        }
        return text
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
            UnknownPriceNote()
            Button("Generate Layer") {
                let (w, h) = dimensions
                ai.generate(prompt: prompt, negative: negative, width: w, height: h)
            }
            .disabled(prompt.trimmingCharacters(in: .whitespaces).isEmpty)
            .needsUnknownPriceTick()
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
            if mode == .remove {
                TextField("Optional: what to remove, or what should be behind it", text: $prompt, axis: .vertical)
                    .lineLimit(1...3)
                    .textFieldStyle(.roundedBorder)
            }
            UnknownPriceNote()
            Button(mode == .remove ? "Remove Object" : "Fill Selection") {
                ai.fill(mode: mode, prompt: prompt, reference: mode == .fill ? reference : nil)
            }
            .disabled(!hasSelection)
            .needsUnknownPriceTick()
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
            UnknownPriceNote()
            Button("Expand Canvas") { ai.expand(margins: margins, prompt: prompt) }
                .disabled(margins.isEmpty)
                .needsUnknownPriceTick()
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
            Text("…or drop an image here")
                .font(.caption)
                .foregroundStyle(isTargeted ? Theme.accent : Theme.muted)
        }
        .padding(isTargeted ? 6 : 0)
        .overlay {
            if isTargeted { RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.accent, style: StrokeStyle(lineWidth: 1.5, dash: [5])) }
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first(where: { UTType(filenameExtension: $0.pathExtension)?.conforms(to: .image) == true }) else { return false }
            ai.matchColor(reference: url, strength: strength)
            return true
        } isTargeted: { isTargeted = $0 }
    }

    @State private var isTargeted = false
}

private struct JobsView: View {
    let ai: AIController

    var body: some View {
        if !ai.jobs.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Activity").font(.headline).accessibilityAddTraits(.isHeader)
                    Spacer()
                    if ai.totalCost > 0 {
                        Text(ai.totalCost, format: .currency(code: "USD").precision(.fractionLength(3)))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .help("OpenRouter cost of this window's jobs")
                    }
                    // Never summed as if they had a price: counted beside the sum.
                    if ai.jobsWithoutPrice > 0 {
                        Text("\(ai.jobsWithoutPrice) without a price")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .help("Paid jobs whose service's answer carried no cost, and paid jobs that failed after the request was sent and may have been charged. They are not in the sum; the service's usage page has what they cost.")
                    }
                    Button("Clear") { ai.clearFinished() }
                        .controlSize(.small)
                        .disabled(ai.jobs.allSatisfy { $0.status == .running })
                }
                ForEach(ai.jobs) { job in
                    HStack(spacing: 6) {
                        Group {
                            switch job.status {
                            case .running: ProgressView().controlSize(.small).accessibilityLabel("Running")
                            case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).accessibilityLabel("Done")
                            case .failed: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).accessibilityLabel("Failed")
                            case .cancelled: Image(systemName: "xmark.circle").foregroundStyle(.secondary).accessibilityLabel("Cancelled")
                            }
                        }
                        VStack(alignment: .leading, spacing: 1) {
                            Text(LocalizedStringKey(job.title)).lineLimit(2).font(.callout)
                            if case .failed(let message) = job.status {
                                Text(message).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                            }
                            if job.mayHaveBeenCharged {
                                Text("May have been charged").font(.caption).foregroundStyle(.secondary)
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
    // Catalogue keys: a plain String here was shown as written, in English, whatever the app's language.
    let note: LocalizedStringKey
    let button: LocalizedStringKey
    let initial: Double
    let action: (Double) -> Void
    @State private var strength: Double?

    var body: some View {
        let value = strength ?? initial
        VStack(alignment: .leading, spacing: 8) {
            Text(note).font(.callout).foregroundStyle(.secondary)
            ParameterSlider(label: "Strength", value: value * 100, range: 0...100, step: 1,
                            format: { "\(Int($0)) %" }, set: { strength = $0 / 100 }, commit: {})
            UnknownPriceNote()
            Button(button) { action(value) }
                .needsUnknownPriceTick()
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
            UnknownPriceNote()
            Button("Relight") { ai.relight(direction: direction, color: color, intensity: intensity, environment: environment) }
                .needsUnknownPriceTick()
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
    @AppStorage("ai.upscaleNeural") private var neural = true
    @State private var enhance = false
    @State private var creativity = 0.3

    /// Real-ESRGAN holds the result as float pixels; keep it to sizes that fit comfortably.
    private static let neuralMaxSide = 16_384

    var body: some View {
        let out = SIMD2(size.x * scale, size.y * scale)
        let tiles = AIPipelines.enhanceTiles(width: out.x, height: out.y).count
        VStack(alignment: .leading, spacing: 8) {
            Picker("Scale", selection: $scale) {
                Text("2×").tag(2)
                Text("4×").tag(4)
            }
            .pickerStyle(.segmented)
            Picker("Method", selection: $neural) {
                Text("Real-ESRGAN (on this Mac)").tag(true)
                Text("Lanczos").tag(false)
            }
            Text("Result: \(out.x) × \(out.y) px, opened as a new document.")
                .font(.caption).foregroundStyle(.secondary)
            if neural && max(out.x, out.y) > Self.neuralMaxSide {
                Text("Too large for Real-ESRGAN; use 2× or Lanczos.")
                    .font(.caption).foregroundStyle(.orange)
            }
            Toggle("Add AI detail", isOn: $enhance)
            if enhance {
                ParameterSlider(label: "Creativity", value: creativity * 100, range: 0...100, step: 1,
                                format: { "\(Int($0)) %" }, set: { creativity = $0 / 100 }, commit: {})
                Text("Runs the image model on \(tiles) tile\(tiles == 1 ? "" : "s").")
                    .font(.caption)
                    .foregroundStyle(tiles > 16 ? .orange : .secondary)
            }
            if enhance { UnknownPriceNote() }
            Button("Upscale") { ai.upscale(scale: scale, neural: neural, enhance: enhance, creativity: creativity) }
                .disabled((enhance && max(out.x, out.y) > 8192) || (neural && max(out.x, out.y) > Self.neuralMaxSide))
                .needsUnknownPriceTick(enhance)
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
            if ai.isLensBlurLive {
                Toggle("Show depth map", isOn: $showDepth)
                    .help("White is near, black is far")
                HStack {
                    Button("Cancel") { finish(apply: false) }
                        .keyboardShortcut(.cancelAction)
                    Button("Apply") { finish(apply: true) }
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.borderedProminent)
                }
            } else {
                HStack {
                    Button("Preview Lens Blur") { ai.beginLensBlur(p) }
                        .disabled(ai.isPreparingLensBlur)
                    if ai.isPreparingLensBlur { ProgressView().controlSize(.small) }
                }
                .help("Shows the blur on the canvas while you adjust it")
            }
        }
        .onChange(of: p) { _, new in ai.updateLensBlur(new, showDepth: showDepth) }
        .onChange(of: showDepth) { _, show in ai.updateLensBlur(p, showDepth: show) }
        .onDisappear { if ai.isLensBlurLive { finish(apply: false) } }
    }

    @State private var showDepth = false

    private func finish(apply: Bool) {
        ai.endLensBlur(apply: apply, parameters: p)
        showDepth = false
    }
}

extension Color {
    init(hex: String) {
        let v = UInt32(hex.trimmingCharacters(in: CharacterSet(charactersIn: "#")), radix: 16) ?? 0
        self.init(.sRGB, red: Double((v >> 16) & 0xff) / 255, green: Double((v >> 8) & 0xff) / 255, blue: Double(v & 0xff) / 255)
    }
}
