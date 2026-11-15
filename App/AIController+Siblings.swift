import AppKit
import GlimmerAI
import GlimmerCore

/// Glimmer's side of the series' sibling protocol: the assistant's `jammer_*` and
/// `flimmer_*` steps, and `add_waveform`, which draws Jämmer's sound as a shape layer.
extension AIController {
    /// Runs a sibling's operation in that app (one undo step there; nothing changes here).
    func performSiblingTool(_ step: AgentStep) async throws {
        _ = try await SiblingClient.shared.perform(tool: step.op, params: step.params)
    }

    /// Fetches the waveform of a Jämmer document and adds it as a solid fill layer with the
    /// waveform as its vector mask: recolourable, movable and styleable, one undo step.
    func performAddWaveform(_ step: AgentStep) async throws {
        let s = session
        let style = SiblingWaveform.Style(rawValue: step.string("style") ?? "") ?? .bars
        let bars = Int(min(max(step.number("bars") ?? 64, 16), 400))
        let columns = style == .bars ? bars : min(max(s.state.width / 6, 64), 400)
        let wave = try await SiblingClient.shared.waveform(.jammer, document: step.string("document"), columns: columns)
        let rect = Self.waveformRect(width: Double(s.state.width), height: Double(s.state.height),
                                     widthShare: step.number("width"), heightShare: step.number("height"),
                                     position: step.string("position"))
        let path = wave.path(in: rect, style: style)
        let color = parseHexColor(step.string("color")) ?? s.foreground
        let mask = await Task.detached { path.asSelection.asMask }.value
        let layer = Layer(name: path.name, mask: mask, vectorMask: path, content: .fill(.solid(color)))
        s.edit(String(localized: "Add Waveform")) { $0.insertLayerAboveActive(layer) }
    }

    /// Where the waveform goes: centred horizontally, in the middle, top or bottom band.
    nonisolated static func waveformRect(width: Double, height: Double, widthShare: Double?, heightShare: Double?,
                                         position: String?) -> CGRectLike {
        let w = width * min(max(widthShare ?? 0.8, 0.1), 1)
        let h = height * min(max(heightShare ?? 0.3, 0.05), 1)
        let margin = height * 0.08
        let y: Double = switch position {
        case "top": min(margin, height - h)
        case "bottom": max(height - h - margin, 0)
        default: (height - h) / 2
        }
        return CGRectLike(x0: (width - w) / 2, y0: y, x1: (width + w) / 2, y1: y + h)
    }

    /// The assistant's step failed because a sibling isn't open: offer to open it (only on click).
    func noteSiblingFailure(_ error: Error) {
        if case .notRunning(let app)? = error as? SiblingError { session.offlineSibling = app }
    }

    /// Opens a sibling app, after the user clicked the button.
    static func launch(_ app: SiblingApp, session: EditorSession) {
        guard let url = applicationURL(app) else {
            session.errorMessage = String(localized: "\(app.displayName) isn't installed on this Mac.")
            return
        }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }

    /// The copy of a sibling to use (SIBLINGS.md §1): a running one, else the best installed
    /// one. LaunchServices' own default can be any stale build with the same id.
    static func applicationURL(_ app: SiblingApp) -> URL? {
        if let running = NSRunningApplication.runningApplications(withBundleIdentifier: app.bundleID).first?.bundleURL {
            return running
        }
        let urls = NSWorkspace.shared.urlsForApplications(withBundleIdentifier: app.bundleID)
        let copies = urls.map { url in
            (path: url.path,
             build: Bundle(url: url)?.infoDictionary?["CFBundleVersion"] as? String ?? "0",
             modified: (try? url.appending(path: "Contents/Info.plist").resourceValues(forKeys: [.contentModificationDateKey]))?
                 .contentModificationDate ?? .distantPast)
        }
        return SiblingApp.bestCopy(copies).map { urls[$0] }
    }
}
