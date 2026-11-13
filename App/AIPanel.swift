import AppKit
import GlimmerAI
import GlimmerCore
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
                    section("On This Mac", id: "local", symbol: "cpu") {
                        VStack(alignment: .leading, spacing: 8) {
                            Button("Remove Background", systemImage: "person.crop.rectangle") { ai.removeBackground() }
                                .help("Masks the active layer to its subject. Runs on this Mac, free.")
                            Button("Select Subject", systemImage: "person.and.background.dotted") { ai.selectSubject() }
                                .help("Selects the main subject. Runs on this Mac, free.")
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
            Label(title, systemImage: symbol).font(.headline)
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
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(ai.messages.suffix(8)) { message in
                Text(message.text)
                    .font(.callout)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(message.fromUser ? Color.accentColor.opacity(0.15) : Color.secondary.opacity(0.1),
                                in: .rect(cornerRadius: 8))
                    .frame(maxWidth: .infinity, alignment: message.fromUser ? .trailing : .leading)
            }
            HStack(alignment: .bottom) {
                TextField("Describe a change, or something to add…", text: $text, axis: .vertical)
                    .lineLimit(1...4)
                    .textFieldStyle(.roundedBorder)
                    .focused($focused)
                    .onSubmit(send)
                Button(action: send) {
                    Image(systemName: "arrow.up.circle.fill").font(.title2)
                }
                .buttonStyle(.borderless)
                .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
                .keyboardShortcut(.return, modifiers: .command)
                .accessibilityLabel("Send")
            }
            Text("“Add a red kite in the sky” makes a new layer. Anything else edits the image, or the selection if there is one.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func send() {
        ai.ask(text)
        text = ""
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
        LabeledContent(label) {
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
