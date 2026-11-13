import GlimmerAI
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            Tab("AI", systemImage: "sparkles") {
                AISettingsView()
            }
            Tab("Models", systemImage: "cpu") {
                ModelSettingsView()
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
