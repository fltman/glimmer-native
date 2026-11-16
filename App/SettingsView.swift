import GlimmerAI
import GlimmerCore
import SwiftUI

struct SettingsView: View {
    /// The selected tab, kept so "Add OpenRouter Key…" can open Settings on AI.
    static let tabKey = "settings.tab"
    @AppStorage(Self.tabKey) private var tab = "general"

    var body: some View {
        TabView(selection: $tab) {
            Tab("General", systemImage: "gearshape", value: "general") {
                GeneralSettingsView()
            }
            Tab("AI", systemImage: "sparkles", value: "ai") {
                AISettingsView()
            }
            Tab("Models", systemImage: "cpu", value: "models") {
                ModelSettingsView()
            }
            Tab("Performance", systemImage: "gauge.with.dots.needle.67percent", value: "performance") {
                PerformanceSettingsView()
            }
            Tab("Tablet", systemImage: "applepencil.tip", value: "tablet") {
                TabletSettingsView()
            }
        }
        .frame(width: 540)
    }
}

private struct AISettingsView: View {
    private let store: any SecretStore = ProviderKeys.keychain.store(for: "openrouter")
    @AppStorage(AIController.textProviderKey) private var textProvider = "openrouter"

    @AppStorage(AIDefaults.imageModelKey) private var imageModel = AIDefaults.imageModel
    @AppStorage(AIController.imageProviderKey) private var imageProvider = "openrouter"
    /// The image service being chosen, until what is sent to it has been confirmed.
    @State private var imageProviderAsked: AIProvider?
    @AppStorage(AIDefaults.textModelKey) private var textModel = AIDefaults.textModel
    @AppStorage(AIDefaults.endpointKey) private var endpoint = ""

    @State private var apiKey = ""
    @State private var savedKey = ""
    @State private var status: KeyStatus = .idle
    /// What each running local server has installed; a server that doesn't answer has no entry.
    @State private var localModels: [String: [OllamaTextModel.Installed]] = [:]

    /// The services that can be chosen for pictures: those offered, and in a debug copy with
    /// `-ai.showUntried YES` those that are built and not tried yet.
    private var imageChoices: [AIProvider] {
        var list = AIProvider.offering(.image)
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "ai.showUntried") {
            list += AIProvider.all.filter { $0.built.contains(.image) && !$0.offers(.image) }
        }
        #endif
        return list
    }

    /// OpenRouter is chosen at once. Another service is chosen only after what is sent to it has
    /// been shown and agreed to, once per service.
    private func chooseImageProvider(_ slug: String) {
        guard slug != "openrouter", let provider = AIProvider.named(slug),
              !UserDefaults.standard.bool(forKey: AIController.imageToldKey(slug)) else {
            imageProvider = slug
            return
        }
        imageProviderAsked = provider
    }

    /// A debug copy may show a service that is built but not offered, for the paid test of it.
    static func untriedAllowed(_ provider: AIProvider) -> Bool {
        #if DEBUG
        return UserDefaults.standard.bool(forKey: "ai.showUntried") && provider.built.contains(.text)
        #else
        return false
        #endif
    }

    private func findLocalServers() async {
        var found: [String: [OllamaTextModel.Installed]] = [:]
        for provider in AIProvider.offering(.text) where provider.slug == "ollama" {
            if let models = try? await OllamaTextModel.installed(baseURL: URL(string: provider.baseURL)!) { found[provider.slug] = models }
        }
        localModels = found
    }

    @FocusState private var keyFieldFocused: Bool

    enum KeyStatus: Equatable {
        case idle, checking
        case valid(String)
        case failed(String)
    }

    var body: some View {
        Form {
            Section {
                SecureField("API key", text: $apiKey, prompt: Text("sk-or-v1-…"))
                    // The field does not take the keyboard by itself when Settings opens: with the cursor in a
                    // secure field macOS lays its Passwords suggestion over the row below (seen in pictures,
                    // 2026-11-16; turning the suggestion off by content type did nothing). It shows when the
                    // person clicks into the field, which is the system's own behaviour.
                    .textContentType(.oneTimeCode)   // (see ProviderKeyField below: not a password saved for a website)
                    .focused($keyFieldFocused)
                    .onAppear { DispatchQueue.main.async { keyFieldFocused = false } }
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
                Text("Glimmer calls OpenRouter directly with your own key. It is stored in your keychain and only sent to the service below (openrouter.ai unless you change it). [Get a key](https://openrouter.ai/keys)")
                    .foregroundStyle(.secondary)
            }

            Section {
                TextField("Endpoint", text: $endpoint, prompt: Text(verbatim: AIDefaults.defaultEndpoint))
                if !endpoint.isEmpty, AIDefaults.endpoint.absoluteString != endpoint.trimmingCharacters(in: .whitespaces) {
                    Text("Not a valid http(s) address; Glimmer uses OpenRouter.").font(.callout).foregroundStyle(.orange)
                }
            } header: {
                Text("Service")
            } footer: {
                Text("Any service with OpenRouter's API (chat completions with image output) works. Leave empty for OpenRouter. Your key is sent only to this address.")
                    .foregroundStyle(.secondary)
            }

            Section {
                Picker("Service", selection: $textProvider) {
                    // A local server is listed only while it is running on this Mac (or when it is the one chosen).
                    ForEach(AIProvider.offering(.text).filter { $0.kind == .cloud || localModels[$0.slug] != nil || $0.slug == textProvider }) { provider in
                        Text(verbatim: provider.kind == .localServer ? String(localized: "\(provider.name) (on this Mac)") : provider.name).tag(provider.slug)
                    }
                    #if DEBUG
                    // For Anders's paid tests: services that are built but not offered yet (`-ai.showUntried YES`).
                    if UserDefaults.standard.bool(forKey: "ai.showUntried") {
                        ForEach(AIProvider.all.filter { $0.built.contains(.text) && !$0.offers(.text) }) { provider in
                            Text("\(provider.name) (not tried yet)").tag(provider.slug)
                        }
                    }
                    #endif
                }
                .task { await findLocalServers() }
                if let provider = AIProvider.named(textProvider), provider.offers(.text) || Self.untriedAllowed(provider) {
                    if provider.slug == "ollama" {
                        LocalTextSettings(provider: provider, models: localModels[provider.slug]) { await findLocalServers() }
                            .id(provider.slug)
                    } else if provider.slug != "openrouter" {
                        ProviderTextSettings(provider: provider)
                            .id(provider.slug)
                    }
                }
                #if DEBUG
                if let provider = AIProvider.named(textProvider), provider.slug != "ollama", provider.offers(.text) || Self.untriedAllowed(provider) {
                    TextModelTrial(provider: provider)
                }
                #endif
                if let provider = AIProvider.named(textProvider), provider.offers(.text) {
                    DisclosureGroup("What is sent to \(provider.name)") {
                        Text(verbatim: AIController.textNotice(for: provider, sendsPictures: AIController.chosenTextModel(for: provider).vision != false))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            } header: {
                Text("Text (the Assistant)")
            } footer: {
                Text(imageProvider == "openrouter"
                     ? "Which service answers when the Assistant plans, suggests edits or looks for distractions. Pictures are still made through OpenRouter."
                     : "Which service answers when the Assistant plans, suggests edits or looks for distractions.")
                    .foregroundStyle(.secondary)
            }

            // Shown only when there is a choice: today OpenRouter is the one service offered for pictures.
            if imageChoices.count > 1 {
                Section {
                    Picker("Service", selection: Binding(get: { imageProvider }, set: { chooseImageProvider($0) })) {
                        ForEach(imageChoices) { provider in
                            Text(verbatim: provider.offers(.image) ? provider.name : String(localized: "\(provider.name) (not tried yet)")).tag(provider.slug)
                        }
                    }
                    if imageProvider != "openrouter", let provider = AIProvider.named(imageProvider) {
                        ProviderImageSettings(provider: provider).id(provider.slug)
                        DisclosureGroup("What is sent to \(provider.name)") {
                            Text(verbatim: AIController.imageNotice(for: provider))
                                .font(.callout).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                } header: {
                    Text("Pictures")
                } footer: {
                    Text("Which service makes and edits pictures: Generate, Edit with Prompt, Generative Fill, Expand and the others.")
                        .foregroundStyle(.secondary)
                }
                .confirmationDialog(Text("Send pictures to \(imageProviderAsked?.name ?? "")?"), isPresented: Binding(get: { imageProviderAsked != nil }, set: { if !$0 { imageProviderAsked = nil } }), presenting: imageProviderAsked) { provider in
                    Button("Use \(provider.name)") {
                        UserDefaults.standard.set(true, forKey: AIController.imageToldKey(provider.slug))
                        imageProvider = provider.slug
                    }
                    Button("Cancel", role: .cancel) {}
                } message: { provider in
                    Text(verbatim: AIController.imageNotice(for: provider))
                }
            }

            Section("Models") {
                TextField("Image model", text: $imageModel)
                TextField("Text model", text: $textModel)
                    .disabled(textProvider != "openrouter")
                    .help(textProvider == "openrouter" ? "" : "Used when the text service is OpenRouter")
                Button("Restore Defaults") {
                    imageModel = AIDefaults.imageModel
                    textModel = AIDefaults.textModel
                }
                .disabled(imageModel == AIDefaults.imageModel && textModel == AIDefaults.textModel)
            }
        }
        .formStyle(.grouped)
        .task { load() }
        // The result of Test Key appears beside the buttons; say it too.
        .onChange(of: status) { _, new in
            switch new {
            case .valid(let detail): AccessibilityNotification.Announcement(detail).post()
            case .failed(let message): AccessibilityNotification.Announcement(message).post()
            default: break
            }
        }
    }

    @ViewBuilder private var statusView: some View {
        switch status {
        case .idle:
            EmptyView()
        case .checking:
            ProgressView().controlSize(.small).accessibilityLabel("Checking the key")
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
            // Through the register's reader, which moves a key stored under the old account name.
            savedKey = try ProviderKeys.keychain.key(for: "openrouter") ?? ""
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
    @AppStorage(ModelStore.sourceKey) private var source = ""

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
                            .accessibilityLabel("Remove \(model.title)")
                        }
                    }
                }
            } footer: {
                Text("These models run on this Mac. They come from Apple's Core ML conversions on Hugging Face.")
                    .foregroundStyle(.secondary)
            }
            Section {
                TextField("Download from", text: $source, prompt: Text(verbatim: ModelStore.defaultSource))
            } footer: {
                Text("Leave empty for Hugging Face. A mirror must serve the same paths (<repository>/resolve/main/<file>).")
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
    @AppStorage(SelectionBar.showKey) private var showSelectionBar = true
    @AppStorage(AIController.autoRunKey) private var autoRun = false
    @AppStorage(AIController.onDeviceRoutingKey) private var routeOnDevice = true
    @AppStorage(AIController.showImageKey) private var showImage = true
    @AppStorage(AIController.reviewKey) private var review = true

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
                Toggle("Show the action bar at the selection", isOn: $showSelectionBar)
            }
            Section("Assistant") {
                Toggle("Run AI steps without asking", isOn: $autoRun)
                Text("Plans that only use the editor's own tools always run straight away.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("Let the assistant see the image", isOn: $showImage)
                Toggle("Check the result and adjust once", isOn: $review)
                Text("A small copy of the image (1024 px) is sent with each request, so settings suit the photo. The check compares before and after.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("Understand simple requests on this Mac", isOn: $routeOnDevice)
                    .disabled(!OnDeviceRouter.isAvailable)
                Text(OnDeviceRouter.isAvailable
                     ? "Apple Intelligence runs one-command requests directly and sends only the rest to OpenRouter."
                     : "Needs Apple Intelligence.")
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
                Text("Undo steps share unchanged pixels, so each step only costs the tiles it changed. When the history needs more memory than this, the oldest steps move to disk and load back when you undo that far.")
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

    /// The slider in words: soft, even or firm, and how far.
    private var pressureDescription: Text {
        let x = log2(exponent) / 1.3  // −1…1
        if abs(x) < 0.05 { return Text("Even") }
        let amount = Int((abs(x) * 100).rounded())
        return x < 0 ? Text("Soft, \(amount) %") : Text("Firm, \(amount) %")
    }

    var body: some View {
        Form {
            Section {
                LabeledContent("Pressure") {
                    HStack {
                        Text("Soft").font(.caption).foregroundStyle(.secondary)
                        // Log scale so 1 sits in the middle.
                        Slider(value: Binding(get: { log2(exponent) }, set: { exponent = pow(2, $0) }), in: -1.3...1.3)
                            .accessibilityLabel("Pressure")
                            .accessibilityValue(pressureDescription)
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
                    .accessibilityValue(pressureDescription)
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

/// Key, terms and model for a text service other than OpenRouter. Everything shown comes
/// from the register (`AIProvider`) and from the service's own model list.
private struct ProviderTextSettings: View {
    let provider: AIProvider

    @State private var key = ""
    @State private var savedKey = ""
    @State private var keyError: String?
    @State private var models: [ProviderModel] = []
    @State private var listError: String?
    @State private var loading = false
    @State private var chosen = ""

    private var store: any SecretStore { ProviderKeys.keychain.store(for: provider.slug) }
    private var modelKey: String { AIController.textModelKey(provider.slug) }
    private var model: ProviderModel? { models.first { $0.id == chosen } }

    var body: some View {
        if provider.needsKey {
            SecureField("\(provider.name) API key", text: $key)
                // Told to macOS as a one-time code, which it has nothing to suggest for: as a plain secure field it gets
                // the Passwords suggestion, laid over the row below, and an API key is not a password saved for a website.
                .textContentType(.oneTimeCode)
                .onSubmit(save)
            HStack {
                Button("Save", action: save).disabled(key == savedKey)
                if !savedKey.isEmpty { Button("Remove", role: .destructive) { key = ""; save() } }
                Spacer()
                if let keyError {
                    Label(keyError, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red).lineLimit(2)
                } else if !savedKey.isEmpty {
                    Label("Saved in your keychain", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                }
            }
        }
        VStack(alignment: .leading, spacing: 4) {
            if let note = provider.termsNote { Text(LocalizedStringKey(note)) }
            if provider.fromDocumentationOnly {
                Text("Glimmer's support for \(provider.name) is built from its documentation and has not been tried with a real call yet. If it answers with an error, Glimmer shows it as it came.")
            }
            Text("Your key is stored in your keychain and sent only to \(URL(string: provider.baseURL)?.host() ?? provider.baseURL).")
            HStack(spacing: 12) {
                if let url = provider.keysURL.flatMap(URL.init) { Link("Get a key", destination: url) }
                if let url = provider.termsURL.flatMap(URL.init) { Link("Terms", destination: url) }
                if let url = provider.pricesURL.flatMap(URL.init) { Link("Prices", destination: url) }
            }
        }
        .font(.callout)
        .foregroundStyle(.secondary)

        HStack {
            Picker("Model", selection: $chosen) {
                if chosen.isEmpty { Text("Choose a model").tag("") }
                // A model chosen earlier that the service no longer lists is shown as such, not silently kept.
                if !chosen.isEmpty, !models.isEmpty, model == nil { Text("\(chosen) (no longer listed)").tag(chosen) }
                if models.isEmpty, !chosen.isEmpty { Text(verbatim: chosen).tag(chosen) }
                ForEach(models) { m in Text(verbatim: m.id).tag(m.id) }
            }
            .disabled(models.isEmpty)
            if loading { ProgressView().controlSize(.small).accessibilityLabel("Loading the model list") }
            Button("Refresh") { Task { await loadModels() } }.disabled(loading)
        }
        .onChange(of: chosen) { _, id in choose(id) }
        .task { load(); await loadModels() }

        if let listError {
            Label(listError, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.callout)
        }
        if let m = model {
            VStack(alignment: .leading, spacing: 4) {
                if m.tools == false {
                    Label("\(provider.name) lists this model without tool calls. The Assistant can't use it.", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
                if m.vision == false {
                    Label("This model can't take pictures, so the Assistant plans without looking at the document, and suggestions and Find Distractions won't work with it.", systemImage: "eye.slash")
                }
                if let price = m.priceLine {
                    Text("\(provider.name)'s list: \(price). \(provider.name) bills you for what you use.")
                } else {
                    Text("Billed by \(provider.name) at their rates.")
                }
            }
            .font(.callout)
            .foregroundStyle(.secondary)
        } else if !chosen.isEmpty, !models.isEmpty {
            Label("\(provider.name) no longer lists \(chosen). Choose another model.", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange).font(.callout)
        }
    }

    private func load() {
        savedKey = ((try? ProviderKeys.keychain.key(for: provider.slug)) ?? nil) ?? ""
        key = savedKey
        chosen = UserDefaults.standard.string(forKey: modelKey) ?? ""
    }

    private func save() {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            if trimmed.isEmpty { try store.delete() } else { try store.write(trimmed) }
            key = trimmed
            savedKey = trimmed
            keyError = nil
        } catch {
            keyError = error.localizedDescription
        }
    }

    /// Remembers the model and what the list says it can do, for the Assistant to check before a request.
    private func choose(_ id: String) {
        let d = UserDefaults.standard
        d.set(id, forKey: modelKey)
        let m = models.first { $0.id == id }
        if let tools = m?.tools { d.set(tools, forKey: modelKey + ".tools") } else { d.removeObject(forKey: modelKey + ".tools") }
        if let vision = m?.vision { d.set(vision, forKey: modelKey + ".vision") } else { d.removeObject(forKey: modelKey + ".vision") }
    }

    private func loadModels() async {
        loading = true
        defer { loading = false }
        do {
            models = try await ModelCatalog.fetchTextModels(provider, key: savedKey.isEmpty ? nil : savedKey)
            listError = nil
            if !chosen.isEmpty { choose(chosen) }   // refresh what the list says about the chosen model
        } catch {
            listError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}

/// The key and the model of an image service. The model is typed in by its id: the services'
/// lists of image models were not read, so Glimmer doesn't claim to know them.
private struct ProviderImageSettings: View {
    let provider: AIProvider

    @State private var key = ""
    @State private var savedKey = ""
    @State private var keyError: String?
    @State private var model = ""
    @State private var editModel = ""

    private var store: any SecretStore { ProviderKeys.keychain.store(for: provider.slug) }

    var body: some View {
        SecureField("\(provider.name) API key", text: $key)
                // Told to macOS as a one-time code, which it has nothing to suggest for: as a plain secure field it gets
                // the Passwords suggestion, laid over the row below, and an API key is not a password saved for a website.
                .textContentType(.oneTimeCode)
            .onSubmit(save)
        HStack {
            Button("Save", action: save).disabled(key == savedKey)
            if !savedKey.isEmpty { Button("Remove", role: .destructive) { key = ""; save() } }
            Spacer()
            if let keyError {
                Label(keyError, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red).lineLimit(2)
            } else if !savedKey.isEmpty {
                Label("Saved in your keychain", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            }
        }
        VStack(alignment: .leading, spacing: 4) {
            if let note = provider.termsNote { Text(LocalizedStringKey(note)) }
            Text("Glimmer's support for \(provider.name) is built from its documentation and has not been tried with a real call yet. If it answers with an error, Glimmer shows it as it came.")
            Text("Your key is stored in your keychain and sent only to \(provider.host).")
            HStack(spacing: 12) {
                if let url = provider.keysURL.flatMap(URL.init) { Link("Get a key", destination: url) }
                if let url = provider.termsURL.flatMap(URL.init) { Link("Terms", destination: url) }
                if let url = provider.pricesURL.flatMap(URL.init) { Link("Prices", destination: url) }
            }
        }
        .font(.callout)
        .foregroundStyle(.secondary)

        TextField("Model", text: $model, prompt: Text("The model's id, as \(provider.name) writes it"))
            .onChange(of: model) { _, id in UserDefaults.standard.set(id.trimmingCharacters(in: .whitespaces), forKey: AIController.imageModelKey(provider.slug)) }
        if provider.slug == "fal" {
            TextField("Model for editing", text: $editModel, prompt: Text("Leave empty for the model's id followed by /edit"))
                .onChange(of: editModel) { _, id in
                    let trimmed = id.trimmingCharacters(in: .whitespaces)
                    if trimmed.isEmpty { UserDefaults.standard.removeObject(forKey: AIController.imageEditModelKey(provider.slug)) }
                    else { UserDefaults.standard.set(trimmed, forKey: AIController.imageEditModelKey(provider.slug)) }
                }
        }
        Text("Billed by \(provider.name) at their rates. Glimmer shows no cost for these pictures, because \(provider.name)'s answers carry none.")
            .font(.callout).foregroundStyle(.secondary)
            .task { load() }
    }

    private func load() {
        savedKey = ((try? ProviderKeys.keychain.key(for: provider.slug)) ?? nil) ?? ""
        key = savedKey
        model = UserDefaults.standard.string(forKey: AIController.imageModelKey(provider.slug)) ?? ""
        editModel = UserDefaults.standard.string(forKey: AIController.imageEditModelKey(provider.slug)) ?? ""
    }

    private func save() {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            if trimmed.isEmpty { try store.delete() } else { try store.write(trimmed) }
            key = trimmed
            savedKey = trimmed
            keyError = nil
        } catch {
            keyError = error.localizedDescription
        }
    }
}

/// The model of a local server (Ollama) for text. Only models that list tool calls can be
/// chosen; the one Glimmer has evaluated is named, the others are marked as not evaluated.
private struct LocalTextSettings: View {
    let provider: AIProvider
    /// nil: no server is answering.
    let models: [OllamaTextModel.Installed]?
    let refresh: () async -> Void

    @State private var chosen = ""

    private var modelKey: String { AIController.textModelKey(provider.slug) }
    private var usable: [OllamaTextModel.Installed] { (models ?? []).filter(\.tools) }
    private var model: OllamaTextModel.Installed? { usable.first { $0.name == chosen } }

    private func title(_ m: OllamaTextModel.Installed) -> String {
        provider.evaluatedModels.contains(m.name) ? m.name : String(localized: "\(m.name) (not evaluated with Glimmer)")
    }

    var body: some View {
        if models == nil {
            Label("\(provider.name) isn't running on this Mac. Start it, then click Refresh.", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange).font(.callout)
        } else if usable.isEmpty {
            Label("None of the models installed in \(provider.name) lists tool calls, which the Assistant needs.", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange).font(.callout)
        }
        HStack {
            Picker("Model", selection: $chosen) {
                if chosen.isEmpty { Text("Choose a model").tag("") }
                if !chosen.isEmpty, model == nil { Text("\(chosen) (not installed)").tag(chosen) }
                ForEach(usable) { m in Text(verbatim: title(m)).tag(m.name) }
            }
            .disabled(usable.isEmpty)
            Button("Refresh") { Task { await refresh() } }
        }
        .onChange(of: chosen) { _, name in choose(name) }
        .onChange(of: models) { _, _ in if !chosen.isEmpty { choose(chosen) } }
        .onAppear { chosen = UserDefaults.standard.string(forKey: modelKey) ?? "" }

        VStack(alignment: .leading, spacing: 4) {
            if let note = provider.termsNote { Text(LocalizedStringKey(note)) }
            if let m = model {
                if let size = m.size {
                    Text("\(m.name) takes about \(ByteCountFormatter.string(fromByteCount: size, countStyle: .memory)) of memory while it runs.")
                }
                if provider.evaluatedModels.contains(m.name) {
                    Text("Glimmer has tried \(m.name) with its own test of everyday requests. It gets most of them right; a Swedish request for an adjustment can come back incomplete, and the same request in English works.")
                } else {
                    Text("Glimmer has not tried \(m.name). It may plan badly or call tools that don't exist; Glimmer drops those and tells you.")
                }
                if !m.vision {
                    Label("This model can't take pictures, so the Assistant plans without looking at the document, and Suggest Edits and Find Distractions won't work with it.", systemImage: "eye.slash")
                }
            }
        }
        .font(.callout)
        .foregroundStyle(.secondary)
    }

    private func choose(_ name: String) {
        let d = UserDefaults.standard
        d.set(name, forKey: modelKey)
        if let m = usable.first(where: { $0.name == name }) {
            d.set(m.tools, forKey: modelKey + ".tools")
            d.set(m.vision, forKey: modelKey + ".vision")
        }
    }
}

#if DEBUG
/// The paid test of a text service (debug builds only): Glimmer's eighteen everyday requests and questions,
/// run only when the button is pressed and confirmed. Its result decides whether the
/// service is offered (the-apps/PROVIDERS.md, rule 3).
private struct TextModelTrial: View {
    let provider: AIProvider
    @State private var asking = false
    @State private var running = false
    @State private var lines: [String] = []
    @State private var verdict: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Button("Run Glimmer's Test of This Model…") { asking = true }.disabled(running)
                if running { ProgressView().controlSize(.small).accessibilityLabel("Running the test") }
            }
            ForEach(lines, id: \.self) { Text(verbatim: $0).font(.caption.monospaced()).textSelection(.enabled) }
            if let verdict { Text(verbatim: verdict).font(.callout.bold()) }
        }
        .confirmationDialog("Send \(Self.requests) requests to \(provider.name)?", isPresented: $asking) {
            Button("Send \(Self.requests) Requests") { run() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Each request carries the list of Glimmer's operations (a few thousand tokens) and gets a short answer. \(provider.name) bills your key for them. Nothing in a document is changed.")
        }
    }

    /// The counted requests, the known gap, and a second group about a RAW layer (three requests).
    static var requests: Int { LocalModelEvaluation.cases.count + LocalModelEvaluation.rawCases.count }

    private func run() {
        guard let model = try? AIController.textModel(for: provider) else {
            verdict = "Save a key and choose a model first."
            return
        }
        running = true; lines = []; verdict = nil
        Task {
            let report = await LocalModelEvaluation.run(model) { outcome in
                Task { @MainActor in
                    lines.append("\(outcome.knownGap ? (outcome.passed ? "gap+" : "gap-") : outcome.passed ? "ok  " : "FAIL") \(String(format: "%5.1f s", outcome.seconds))  \(outcome.language)  \(outcome.goal) → \(outcome.got)")
                }
            }
            let en = report.passed(language: "en"), sv = report.passed(language: "sv")
            verdict = "\(report.model): \(report.passed) of \(report.scored.count) (English \(en.0)/\(en.1), Swedish \(sv.0)/\(sv.1)), median \(String(format: "%.1f", report.median)) s, slowest \(String(format: "%.1f", report.slowest)) s: \(report.passes ? "passes" : "does not pass").\(report.gapLine) The cost is on \(provider.name)'s usage page; this service's answers carry no cost."
            // The second group: requests about a layer opened from a camera's RAW file. Counted by themselves, not in the verdict:
            // a model that is only sent the short tool list is not offered develop_raw and cannot pass the first two.
            lines.append("— RAW layer (a second group, not in the verdict above) —")
            let raw = await LocalModelEvaluation.run(model, cases: LocalModelEvaluation.rawCases) { outcome in
                Task { @MainActor in
                    lines.append("\(outcome.passed ? "ok  " : "FAIL") \(String(format: "%5.1f s", outcome.seconds))  \(outcome.language)  \(outcome.goal) → \(outcome.got)")
                }
            }
            verdict = (verdict ?? "") + " RAW layer: \(raw.outcomes.filter(\.passed).count) of \(raw.outcomes.count)."
            running = false
        }
    }
}
#endif
