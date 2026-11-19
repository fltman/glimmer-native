import GlimmerAI
import SwiftUI

/// A feature needs models that aren't on this Mac: what to ask the person about, and what to do
/// once they are there.
struct ModelDownloadRequest: Identifiable {
    let id = UUID()
    let models: [OnDeviceModel]
    /// Runs again once the models are installed; nil when the person starts it again themselves.
    let retry: (@MainActor () -> Void)?
}

/// The question before Glimmer downloads a model: how much, from whom, from where and under which
/// license. Nothing is fetched until the person clicks Download (the series' rule: an in-app
/// download starts only with a click in the app's own window). The same sheet serves Settings › Models.
struct ModelDownloadSheet: View {
    let models: [OnDeviceModel]
    /// True when every model was downloaded and checked.
    let done: (Bool) -> Void

    @State private var fraction: Double?
    @State private var failure: String?
    @State private var task: Task<Void, Never>?

    private var totalBytes: Int64 { Int64(models.reduce(0) { $0 + ($1.requirement.sizeBytes ?? 0) }) }
    private var size: String { ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file) }
    private var publisher: String { Array(Set(models.map(\.requirement.source.publisher))).sorted().joined(separator: ", ") }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Download \(size) from \(publisher) via Hugging Face?")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            Group {
                if models.count == 1 {
                    Text("This feature runs on your Mac with a model that isn't built into Glimmer. Glimmer downloads it once and checks every file against its published checksum before it uses it.")
                } else {
                    Text("This feature runs on your Mac with models that aren't built into Glimmer. Glimmer downloads them once and checks every file against its published checksum before it uses them.")
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            ForEach(models, id: \.self) { model in
                ModelFacts(model: model)
            }
            if let fraction {
                ProgressView(value: fraction) {
                    Text("Downloading and checking…")
                }
            }
            if let failure {
                StatusLine(.error, verbatim: failure)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) {
                    task?.cancel()
                    done(false)
                }
                .keyboardShortcut(.cancelAction)
                Button(failure == nil ? "Download" : "Try Again") { start() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(fraction != nil)
            }
        }
        .padding(20)
        .frame(width: 460)
        .onDisappear { task?.cancel() }
    }

    private func start() {
        failure = nil
        fraction = 0
        let models = models
        let total = Double(max(totalBytes, 1))
        task = Task {
            do {
                var before = 0.0
                for model in models where !ModelStore.shared.isInstalled(model) {
                    let share = Double(model.requirement.sizeBytes ?? 0) / total
                    let start = before
                    try await ModelStore.shared.download(model) { part in
                        Task { @MainActor in fraction = start + part * share }
                    }
                    before += share
                }
                fraction = 1
                done(true)
            } catch is CancellationError {
                fraction = nil
            } catch {
                fraction = nil
                failure = PersonMessage.text(for: error)
            }
        }
    }
}

/// A model's size, publisher, source and license, with links.
struct ModelFacts: View {
    let model: OnDeviceModel

    var body: some View {
        let r = model.requirement
        VStack(alignment: .leading, spacing: 3) {
            Text(LocalizedStringKey(model.title)).bold()
            Text("\(ByteCountFormatter.string(fromByteCount: Int64(r.sizeBytes ?? 0), countStyle: .file)) · by \(r.source.publisher)")
                .foregroundStyle(.secondary)
            HStack(spacing: 12) {
                if let url = URL(string: r.source.url) {
                    Link("Source", destination: url)
                        .accessibilityLabel("Source of \(model.title)")
                }
                if let url = URL(string: r.license.url) {
                    Link("License: \(r.license.spdx)", destination: url)
                }
            }
            .font(.callout)
        }
        .accessibilityElement(children: .contain)
    }
}

extension AIController {
    /// Runs `action` when every model in `models` is on this Mac; otherwise asks the person to
    /// download them first, and runs it once they have.
    func withModels(_ models: [OnDeviceModel], _ action: @escaping @MainActor () -> Void) {
        let missing = ModelStore.shared.missing(models)
        if missing.isEmpty { return action() }
        // From the agent API nothing is asked in the window (the request was refused with model_missing before it ran).
        guard !runningAPISteps else { return }
        modelRequest = ModelDownloadRequest(models: missing, retry: action)
    }
}
