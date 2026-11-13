import GlimmerAI
import GlimmerCore
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            Tab("General", systemImage: "gearshape") {
                GeneralSettingsView()
            }
            Tab("AI", systemImage: "sparkles") {
                AISettingsView()
            }
            Tab("Models", systemImage: "cpu") {
                ModelSettingsView()
            }
            Tab("Performance", systemImage: "gauge.with.dots.needle.67percent") {
                PerformanceSettingsView()
            }
            Tab("Tablet", systemImage: "applepencil.tip") {
                TabletSettingsView()
            }
        }
        .frame(width: 540)
    }
}

private struct AISettingsView: View {
    private let store: any SecretStore = KeychainSecretStore.openRouterAPIKey

    @AppStorage(AIDefaults.imageModelKey) private var imageModel = AIDefaults.imageModel
    @AppStorage(AIDefaults.textModelKey) private var textModel = AIDefaults.textModel

    @State private var apiKey = ""
    @State private var savedKey = ""
    @State private var status: KeyStatus = .idle

    enum KeyStatus: Equatable {
        case idle, checking
        case valid(String)
        case failed(String)
    }

    var body: some View {
        Form {
            Section {
                SecureField("API key", text: $apiKey, prompt: Text("sk-or-v1-…"))
                    .onSubmit(save)
                HStack {
                    Button("Save", action: save)
                        .disabled(apiKey == savedKey)
                    Button("Test Key", action: test)
                        .disabled(apiKey.isEmpty || status == .checking)
                    if !savedKey.isEmpty {
                        Button("Remove", role: .destructive, action: remove)
                    }
                    Spacer()
                    statusView
                }
            } header: {
                Text("OpenRouter")
            } footer: {
                Text("Glimmer calls OpenRouter directly with your own key. It is stored in your keychain and only sent to openrouter.ai. [Get a key](https://openrouter.ai/keys)")
                    .foregroundStyle(.secondary)
            }

            Section("Models") {
                TextField("Image model", text: $imageModel)
                TextField("Text model", text: $textModel)
                Button("Restore Defaults") {
                    imageModel = AIDefaults.imageModel
                    textModel = AIDefaults.textModel
                }
                .disabled(imageModel == AIDefaults.imageModel && textModel == AIDefaults.textModel)
            }
        }
        .formStyle(.grouped)
        .task { load() }
    }

    @ViewBuilder private var statusView: some View {
        switch status {
        case .idle:
            EmptyView()
        case .checking:
            ProgressView().controlSize(.small)
        case .valid(let detail):
            Label(detail, systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .lineLimit(2)
        }
    }

    private func load() {
        do {
            savedKey = try store.read() ?? ""
            apiKey = savedKey
        } catch {
            status = .failed(error.localizedDescription)
        }
    }

    private func save() {
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            if trimmed.isEmpty { try store.delete() } else { try store.write(trimmed) }
            apiKey = trimmed
            savedKey = trimmed
            status = .idle
        } catch {
            status = .failed(error.localizedDescription)
        }
    }

    private func remove() {
        apiKey = ""
        save()
    }

    private func test() {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        status = .checking
        Task {
            do {
                let info = try await OpenRouterClient(apiKey: key).keyInfo()
                status = .valid(describe(info))
            } catch {
                status = .failed(error.localizedDescription)
            }
        }
    }

    private func describe(_ info: OpenRouterKeyInfo) -> String {
        if let remaining = info.limitRemaining {
            return "Valid · \(remaining.formatted(.currency(code: "USD"))) left"
        }
        return "Valid"
    }
}


/// On-device models downloaded on first use.
private struct ModelSettingsView: View {
    @State private var installed: Set<OnDeviceModel> = []

    var body: some View {
        Form {
            Section {
                ForEach(OnDeviceModel.allCases, id: \.self) { model in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(model.title)
                            Text(installed.contains(model) ? "Downloaded" : "Downloads on first use (\(model.approximateSize))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if installed.contains(model) {
                            Button("Remove", role: .destructive) {
                                Task {
                                    try? await ModelStore.shared.remove(model)
                                    await refresh()
                                }
                            }
                        }
                    }
                }
            } footer: {
                Text("These models run on this Mac. They come from Apple's Core ML conversions on Hugging Face.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .task { await refresh() }
    }

    private func refresh() async {
        var set: Set<OnDeviceModel> = []
        for model in OnDeviceModel.allCases where await ModelStore.shared.isInstalled(model) { set.insert(model) }
        installed = set
    }
}

/// App-wide preferences (UserDefaults keys live in `Preferences`).
enum Preferences {
    enum CanvasBackground: String, CaseIterable {
        case system, light, mid, dark, black
        var title: LocalizedStringResource {
            switch self {
            case .system: "Match System"
            case .light: "Light Grey"
            case .mid: "Mid Grey"
            case .dark: "Dark Grey"
            case .black: "Black"
            }
        }
        var grey: Double? {
            switch self {
            case .system: nil
            case .light: 0.85
            case .mid: 0.5
            case .dark: 0.2
            case .black: 0
            }
        }
    }

    static let canvasBackgroundKey = "canvas.background"
    static let checkerSizeKey = "canvas.checkerSize"
    static let showOmnibarKey = "ui.showOmnibar"

    static var canvasBackground: CanvasBackground {
        CanvasBackground(rawValue: UserDefaults.standard.string(forKey: canvasBackgroundKey) ?? "") ?? .system
    }

    static var checkerSize: Double {
        let v = UserDefaults.standard.double(forKey: checkerSizeKey)
        return v > 0 ? v : 8
    }
}

private struct GeneralSettingsView: View {
    @AppStorage(Preferences.canvasBackgroundKey) private var background = Preferences.CanvasBackground.system.rawValue
    @AppStorage(Preferences.checkerSizeKey) private var checker = 8.0
    @AppStorage(Preferences.showOmnibarKey) private var showOmnibar = true
    @AppStorage(AIController.autoRunKey) private var autoRun = false

    var body: some View {
        Form {
            Section("Canvas") {
                Picker("Background", selection: $background) {
                    ForEach(Preferences.CanvasBackground.allCases, id: \.rawValue) { Text($0.title).tag($0.rawValue) }
                }
                Picker("Transparency grid", selection: $checker) {
                    Text("Small").tag(4.0)
                    Text("Medium").tag(8.0)
                    Text("Large").tag(16.0)
                }
                Toggle("Show the search bar on the canvas", isOn: $showOmnibar)
            }
            Section("Assistant") {
                Toggle("Run AI steps without asking", isOn: $autoRun)
                Text("Plans that only use the editor's own tools always run straight away.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding(.vertical, 8)
        .onChange(of: background) { NotificationCenter.default.post(name: .glimmerPreferencesChanged, object: nil) }
        .onChange(of: checker) { NotificationCenter.default.post(name: .glimmerPreferencesChanged, object: nil) }
    }
}

extension Notification.Name {
    static let glimmerPreferencesChanged = Notification.Name("GlimmerPreferencesChanged")
}

private struct PerformanceSettingsView: View {
    @AppStorage(GlimmerDocument.historyLimitKey) private var historyLimit = 100
    @AppStorage(GlimmerDocument.historyBudgetKey) private var budgetMB = 2048

    var body: some View {
        Form {
            Section {
                Stepper(value: $historyLimit, in: 10...500, step: 10) {
                    LabeledContent("History states", value: "\(historyLimit)")
                }
                Picker("History memory", selection: $budgetMB) {
                    ForEach([512, 1024, 2048, 4096, 8192], id: \.self) { mb in
                        Text(ByteCountFormatter.string(fromByteCount: Int64(mb) * 1_048_576, countStyle: .memory)).tag(mb)
                    }
                }
            } header: {
                Text("Undo History")
            } footer: {
                Text("Undo steps share unchanged pixels, so each step only costs the tiles it changed. When the history needs more memory than this, the oldest steps are dropped.")
            }
            Section("Graphics") {
                LabeledContent("GPU", value: GPU.device.name)
                LabeledContent("Memory", value: ByteCountFormatter.string(
                    fromByteCount: Int64(ProcessInfo.processInfo.physicalMemory), countStyle: .memory))
                LabeledContent("Recommended working set", value: ByteCountFormatter.string(
                    fromByteCount: Int64(GPU.device.recommendedMaxWorkingSetSize), countStyle: .memory))
            }
        }
        .formStyle(.grouped)
        .padding(.vertical, 8)
    }
}

private struct TabletSettingsView: View {
    @AppStorage(TabletSettings.pressureCurveKey) private var exponent = 1.0
    @AppStorage(TabletSettings.useTiltKey) private var useTilt = true

    var body: some View {
        Form {
            Section {
                LabeledContent("Pressure") {
                    HStack {
                        Text("Soft").font(.caption).foregroundStyle(.secondary)
                        // Log scale so 1 sits in the middle.
                        Slider(value: Binding(get: { log2(exponent) }, set: { exponent = pow(2, $0) }), in: -1.3...1.3)
                        Text("Firm").font(.caption).foregroundStyle(.secondary)
                    }
                }
                HStack {
                    Spacer()
                    Canvas { ctx, size in
                        var axes = Path()
                        axes.addRect(CGRect(origin: .zero, size: size))
                        ctx.stroke(axes, with: .color(.secondary.opacity(0.4)), lineWidth: 1)
                        var curve = Path()
                        for i in 0...40 {
                            let x = Double(i) / 40
                            let p = CGPoint(x: x * size.width, y: size.height - TabletSettings.curve(x, exponent: exponent) * size.height)
                            if i == 0 { curve.move(to: p) } else { curve.addLine(to: p) }
                        }
                        ctx.stroke(curve, with: .color(.accentColor), lineWidth: 2)
                    }
                    .frame(width: 120, height: 120)
                    .accessibilityLabel("Pressure curve")
                    Spacer()
                }
                Button("Reset") { exponent = 1 }
                    .disabled(exponent == 1)
            } header: {
                Text("Pen Pressure")
            } footer: {
                Text("Soft reaches full size and flow with a lighter touch; firm needs more force.")
            }
            Section {
                Toggle("Use pen tilt", isOn: $useTilt)
            } footer: {
                Text("Turn on Tilt → Angle, Tilt → Roundness or Rotation → Angle under Dynamics in the brush options to shape dabs with the pen.")
            }
        }
        .formStyle(.grouped)
        .padding(.vertical, 8)
    }
}
