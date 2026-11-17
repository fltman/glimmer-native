#if GLIMMER_RAW   // Config/Features.xcconfig switches this
import Foundation
import GlimmerAI
import GlimmerCore
import GlimmerRender

/// The agent's `develop_raw`: a RAW layer developed again with other settings.
extension AIController {
    /// What the agent API says about a layer's RAW file.
    static func describeRaw(_ layer: Layer) -> [String: Any]? {
        guard let raw = layer.raw else { return nil }
        return ["fileName": raw.fileName, "byteCount": raw.data.count, "settings": settingsJSON(raw.settings),
                "process": raw.settings.process ?? NSNull(), "pixelsAsDeveloped": RawLayer.pixelsAreAsDeveloped(layer)]
    }

    /// The settings as an agent gives them: nil values are the camera's own (`asShot` in raw/info).
    static func settingsJSON(_ s: RawSettings) -> [String: Any] {
        var d: [String: Any] = ["exposure": s.exposure, "shadows": s.shadows, "highlightRecovery": s.highlightRecovery]
        d["temperature"] = s.temperature ?? NSNull(); d["tint"] = s.tint ?? NSNull()
        d["contrast"] = s.contrast ?? NSNull(); d["sharpness"] = s.sharpness ?? NSNull()
        d["luminanceNoise"] = s.luminanceNoise ?? NSNull(); d["colorNoise"] = s.colorNoise ?? NSNull()
        d["lensCorrection"] = s.lensCorrection ?? NSNull()
        return d
    }

    /// `GET …/layers/{layer}/raw/info`: what the file allows, and the settings as they now are.
    static func rawInfo(_ layer: Layer) throws -> [String: Any] {
        guard let raw = layer.raw else { throw StepError("This layer has no RAW file. Only a layer opened from a camera's RAW file has one.", reason: "not_raw") }
        let info = try RawDevelopment.info(raw.data)
        let controls = RawRequest.controls(info).map { c -> [String: Any] in
            ["name": c.name, "min": c.range.lowerBound, "max": c.range.upperBound, "supported": c.supported, "asShot": c.asShot]
        }
        let switches = RawRequest.switches(info).map { ["name": $0.name, "supported": $0.supported, "asShot": $0.asShot] as [String: Any] }
        return ["fileName": raw.fileName, "byteCount": raw.data.count, "width": info.width, "height": info.height,
                "hasLensCorrectionData": info.supportsLensCorrection, "processes": info.processes,
                "controls": controls, "switches": switches, "settings": settingsJSON(raw.settings),
                "process": raw.settings.process ?? NSNull(), "pixelsAsDeveloped": RawLayer.pixelsAreAsDeveloped(layer)]
    }

    func performDevelopRaw(_ step: AgentStep) async throws {
        let s = session
        let id: UUID
        if let key = step.string("target")?.trimmingCharacters(in: .whitespaces), !key.isEmpty {
            do { id = try CanvasSteps.target(key, in: s.state.allLayers.map { (id: $0.id, name: $0.name) }) }
            catch let refusal as CanvasSteps.Refusal { throw StepError(refusal.message, reason: refusal.reason) }
        } else {
            guard let active = s.state.activeLayerID else { throw StepError("There's no active layer.", reason: "unknown_layer") }
            id = active
        }
        guard let layer = s.state.layer(id: id) else { throw StepError("There's no such layer.", reason: "unknown_layer") }
        guard let raw = layer.raw else {
            throw StepError("“\(layer.name)” has no RAW file to develop: it was not opened from a camera's RAW file. Use add_adjustment to change its tone or color.", reason: "not_raw")
        }
        if !RawLayer.pixelsAreAsDeveloped(layer), step.params["replaceChanges"]?.bool != true {
            throw StepError("“\(layer.name)” has been painted on or changed since it was developed, and developing again replaces those changes. Send replaceChanges: true to do it anyway.", reason: "replaces_changes")
        }
        // A name develop_raw doesn't have is refused, not passed over: "brightness" beside a valid value
        // used to run with the valid value alone (found by the API test, 2026-11-16).
        let known: Set<String> = ["target", "exposure", "temperature", "tint", "shadows", "contrast", "sharpness", "luminanceNoise", "colorNoise",
                                  "highlightRecovery", "lensCorrection", "asShot", "replaceChanges", "rationale"]
        if let stray = step.params.keys.sorted().first(where: { !known.contains($0) }) {
            throw StepError("develop_raw has no parameter named \(stray). It has: exposure, temperature, tint, shadows, contrast, sharpness, luminanceNoise, colorNoise, highlightRecovery, lensCorrection, asShot.", reason: "unknown_control")
        }
        var numbers: [String: Double] = [:], switches: [String: Bool] = [:]
        for name in ["exposure", "temperature", "tint", "shadows", "contrast", "sharpness", "luminanceNoise", "colorNoise"] {
            guard let value = step.params[name], value != .null else { continue }
            guard let number = value.number else { throw StepError("\(name) must be a number.", reason: "bad_value") }
            numbers[name] = number
        }
        for name in ["highlightRecovery", "lensCorrection"] {
            guard let value = step.params[name], value != .null else { continue }
            guard let flag = value.bool else { throw StepError("\(name) must be true or false.", reason: "bad_value") }
            switches[name] = flag
        }
        let asShot = step.params["asShot"]?.bool == true
        guard asShot || !numbers.isEmpty || !switches.isEmpty else {
            throw StepError("Give at least one of exposure, temperature, tint, shadows, contrast, sharpness, luminanceNoise, colorNoise, highlightRecovery, lensCorrection or asShot.", reason: "nothing_to_set")
        }
        let settings: RawSettings
        do {
            settings = try RawRequest.settings(from: raw.settings, info: try RawDevelopment.info(raw.data), numbers: numbers, switches: switches, asShot: asShot)
        } catch let refusal as RawRequest.Refusal {
            throw StepError(refusal.message, reason: refusal.reason)
        }
        let made = try await Task.detached(priority: .userInitiated) { try RawLayer.developedTimed(layer, with: settings) }.value
        // The layer may have gone or changed while the file was developed.
        guard s.state.layer(id: id)?.raw != nil else { throw StepError("The layer was removed while it was being developed.", reason: "unknown_layer") }
        s.edit(stepName("Develop RAW")) { state in state.updateLayer(id) { $0 = made.layer } }
        stepInfo = ["layer": id.uuidString, "settings": Self.settingsJSON(made.layer.raw?.settings ?? settings), "process": made.layer.raw?.settings.process ?? NSNull(),
                    "seconds": ((made.decoderSeconds + made.tileSeconds) * 10).rounded() / 10]
    }
}
#endif
