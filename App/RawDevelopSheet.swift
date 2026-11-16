#if GLIMMER_RAW   // Config/Features.xcconfig switches this
import AppKit
import GlimmerCore
import GlimmerRender
import SwiftUI

/// Renders drafts for the Develop sheet away from the main thread. One decoder is kept for
/// as long as the sheet is open, and only the latest settings are rendered: a control that
/// moves faster than the decoder answers skips the settings in between. The sheet never
/// waits for this; it shows the last picture and says when it is behind.
final class RawDraftWorker: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.brattoo.glimmer.raw-draft", qos: .userInitiated)
    private let lock = NSLock()
    private var draft: RawDraft?          // touched on `queue` only
    private var wanted: RawSettings?      // behind `lock`
    private var busy = false              // behind `lock`
    private let data: Data
    /// Called on the main thread: a picture with the settings it shows and the time it took, or why there is none.
    private let deliver: @MainActor @Sendable (Result<(image: CGImage, settings: RawSettings, seconds: Double), Error>) -> Void

    init(data: Data, deliver: @escaping @MainActor @Sendable (Result<(image: CGImage, settings: RawSettings, seconds: Double), Error>) -> Void) {
        self.data = data
        self.deliver = deliver
    }

    /// Asks for a picture with these settings. Returns at once.
    func request(_ settings: RawSettings) {
        lock.lock()
        wanted = settings
        let start = !busy
        if start { busy = true }
        lock.unlock()
        if start { queue.async { [self] in run() } }
    }

    private func run() {
        while true {
            lock.lock()
            guard let settings = wanted else { busy = false; lock.unlock(); return }
            wanted = nil
            lock.unlock()
            let began = Date()
            let result: Result<(image: CGImage, settings: RawSettings, seconds: Double), Error>
            do {
                if draft == nil { draft = try RawDraft(data) }
                let image = try draft!.picture(settings)
                result = .success((image, settings, Date().timeIntervalSince(began)))
            } catch {
                result = .failure(error)
            }
            let deliver = deliver
            DispatchQueue.main.async { MainActor.assumeIsolated { deliver(result) } }
        }
    }
}

/// What the Develop sheet shows and changes.
@MainActor @Observable
final class RawDevelopModel {
    let layerID: UUID
    let source: RawSource
    let info: RawInfo
    /// Whether something was painted or pasted on the layer since it was developed.
    let pixelsChanged: Bool
    var settings: RawSettings { didSet { if settings != oldValue { askForDraft() } } }
    private(set) var picture: CGImage?
    /// The settings the picture on screen shows.
    private(set) var shown: RawSettings?
    private(set) var lastDraftSeconds: Double?
    var problem: String?
    var isDeveloping = false
    var isPickingNeutral = false
    @ObservationIgnored private var worker: RawDraftWorker?

    init?(layer: Layer) {
        guard let raw = layer.raw, let info = try? RawDevelopment.info(raw.data) else { return nil }
        layerID = layer.id
        source = raw
        self.info = info
        pixelsChanged = !RawLayer.pixelsAreAsDeveloped(layer)
        settings = raw.settings
        worker = RawDraftWorker(data: raw.data) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let made):
                picture = made.image; shown = made.settings; lastDraftSeconds = made.seconds; problem = nil
            case .failure(let error):
                problem = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
        // Started when the sheet opens, before any control is touched: the first render is the slow one.
        askForDraft()
    }

    private func askForDraft() { worker?.request(settings) }

    /// True while the picture on screen is not yet the one the controls say.
    var isBehind: Bool { shown != settings }

    var temperature: Double {
        get { settings.temperature ?? info.temperature }
        set { settings.temperature = newValue }
    }
    var tint: Double {
        get { settings.tint ?? info.tint }
        set { settings.tint = newValue }
    }

    /// The camera's own white balance and the decoder's own values; the process stays the one the picture was developed with.
    func resetToAsShot() {
        var fresh = RawSettings()
        fresh.process = settings.process
        settings = fresh
    }

    /// White balance from a point of the draft that should be grey (`unit` is 0…1 from the picture's top left).
    func pickNeutral(at unit: CGPoint) {
        isPickingNeutral = false
        let data = source.data, current = settings
        let point = CGPoint(x: unit.x * CGFloat(info.width), y: unit.y * CGFloat(info.height))
        Task {
            let found = await Task.detached(priority: .userInitiated) { try? RawDevelopment.whiteBalance(for: data, settings: current, neutralAt: point) }.value
            guard let found else { problem = String(localized: "Couldn't read a white balance from that point."); return }
            settings.temperature = found.temperature
            settings.tint = found.tint
        }
    }
}

/// Layer › Develop…: the RAW file in the active layer developed again with other settings.
struct RawDevelopSheet: View {
    let session: EditorSession
    @Environment(\.dismiss) private var dismiss
    @State private var model: RawDevelopModel?

    var body: some View {
        Group {
            if let model {
                content(model)
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Develop RAW").font(.headline)
                    Text("This layer has no RAW file that this Mac can develop.").fixedSize(horizontal: false, vertical: true)
                    HStack { Spacer(); Button("OK") { dismiss() }.keyboardShortcut(.defaultAction) }
                }
                .padding(20).frame(width: 420)
            }
        }
        .onAppear { if model == nil, let layer = session.activeLayer { model = RawDevelopModel(layer: layer) } }
    }

    @ViewBuilder private func content(_ model: RawDevelopModel) -> some View {
        @Bindable var model = model
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                preview(model)
                Text(statusLine(model)).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("rawDraftStatus")
            }
            .frame(width: 460)
            VStack(alignment: .leading, spacing: 10) {
                Text("Develop RAW").font(.headline)
                Text(verbatim: "\(model.source.fileName) · \(model.info.width) × \(model.info.height) · \(ByteCountFormatter.string(fromByteCount: Int64(model.source.data.count), countStyle: .file))")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if model.pixelsChanged {
                    Label("This layer has been painted on or changed since it was developed. Developing again replaces those changes.", systemImage: "exclamationmark.triangle.fill")
                        .font(.callout).fixedSize(horizontal: false, vertical: true)
                }
                slider("Exposure", value: $model.settings.exposure, in: -3...3, shown: stops(model.settings.exposure))
                slider("Temperature", value: $model.temperature, in: 2_000...12_000, shown: String(localized: "\(Int(model.temperature.rounded())) K"))
                slider("Tint", value: $model.tint, in: -100...100, shown: "\(Int(model.tint.rounded()))")
                Toggle("Click the picture to set what should be grey", isOn: $model.isPickingNeutral).toggleStyle(.checkbox)
                slider("Shadows", value: $model.settings.shadows, in: 0...2, shown: model.settings.shadows.formatted(.number.precision(.fractionLength(2))))
                if model.info.supportsContrast {
                    slider("Contrast", value: optional($model.settings.contrast, model.info.contrast), in: 0...1, shown: percent(model.settings.contrast ?? model.info.contrast))
                }
                if model.info.supportsSharpness {
                    slider("Sharpness", value: optional($model.settings.sharpness, model.info.sharpness), in: 0...1, shown: percent(model.settings.sharpness ?? model.info.sharpness))
                }
                if model.info.supportsLuminanceNoise {
                    slider("Noise reduction", value: optional($model.settings.luminanceNoise, model.info.luminanceNoise), in: 0...1, shown: percent(model.settings.luminanceNoise ?? model.info.luminanceNoise))
                }
                if model.info.supportsColorNoise {
                    slider("Colour noise reduction", value: optional($model.settings.colorNoise, model.info.colorNoise), in: 0...1, shown: percent(model.settings.colorNoise ?? model.info.colorNoise))
                }
                if model.info.supportsHighlightRecovery {
                    Toggle("Recover highlights", isOn: $model.settings.highlightRecovery).toggleStyle(.checkbox)
                }
                if model.info.supportsLensCorrection {
                    Toggle("Lens correction", isOn: Binding(get: { model.settings.lensCorrection ?? model.info.lensCorrection }, set: { model.settings.lensCorrection = $0 }))
                        .toggleStyle(.checkbox)
                    Text("Uses the correction the camera stored in the file. It reshapes the whole picture a little, not only the corners.")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                if let problem = model.problem {
                    Label(problem, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 4)
                HStack {
                    Button("As Shot") { model.resetToAsShot() }
                    Spacer()
                    if model.isDeveloping { ProgressView().controlSize(.small).accessibilityLabel("Developing") }
                    Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                    Button("Develop") { develop(model) }.keyboardShortcut(.defaultAction).disabled(model.isDeveloping)
                }
            }
            .frame(width: 330)
        }
        .padding(20)
    }

    private func preview(_ model: RawDevelopModel) -> some View {
        let aspect = CGFloat(model.info.width) / CGFloat(max(1, model.info.height))
        return ZStack {
            Rectangle().fill(.black.opacity(0.25))
            if let picture = model.picture {
                Image(decorative: picture, scale: 1).resizable().interpolation(.high)
            } else {
                ProgressView().accessibilityLabel("Developing the first picture")
            }
        }
        // An exact size, so the line under the picture sits right under it whatever the picture's shape.
        .frame(width: aspect >= 1 ? 460 : 460 * aspect, height: aspect >= 1 ? 460 / aspect : 460)
        .overlay {
            GeometryReader { geo in
                Color.clear.contentShape(Rectangle())
                    .onTapGesture { location in
                        guard model.isPickingNeutral, geo.size.width > 0, geo.size.height > 0 else { return }
                        model.pickNeutral(at: CGPoint(x: location.x / geo.size.width, y: location.y / geo.size.height))
                    }
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Preview of the developed picture")
    }

    private func statusLine(_ model: RawDevelopModel) -> String {
        if model.picture == nil { return String(localized: "Developing the first picture…") }
        if model.isBehind { return String(localized: "The picture is catching up with the controls…") }
        return String(localized: "The picture shows the settings as they are.")
    }

    private func slider(_ title: LocalizedStringKey, value: Binding<Double>, in range: ClosedRange<Double>, shown: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack { Text(title); Spacer(); Text(verbatim: shown).monospacedDigit().foregroundStyle(.secondary) }
                .accessibilityHidden(true)
            Slider(value: value, in: range) { Text(title) }
                .labelsHidden()
                .accessibilityValue(Text(verbatim: shown))
        }
    }

    private func optional(_ binding: Binding<Double?>, _ fallback: Double) -> Binding<Double> {
        Binding(get: { binding.wrappedValue ?? fallback }, set: { binding.wrappedValue = $0 })
    }

    private func stops(_ value: Double) -> String {
        let number = value.formatted(.number.precision(.fractionLength(2)).sign(strategy: .always(includingZero: false)))
        return String(localized: "\(number) stops")
    }

    private func percent(_ value: Double) -> String { (value).formatted(.percent.precision(.fractionLength(0))) }

    private func develop(_ model: RawDevelopModel) {
        guard let layer = session.state.layer(id: model.layerID) else { dismiss(); return }
        let settings = model.settings
        model.isDeveloping = true
        Task {
            do {
                let developed = try await Task.detached(priority: .userInitiated) { try RawLayer.developed(layer, with: settings) }.value
                session.edit(String(localized: "Develop RAW")) { state in state.updateLayer(model.layerID) { $0 = developed } }
                dismiss()
            } catch {
                model.isDeveloping = false
                model.problem = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }
}
#endif
