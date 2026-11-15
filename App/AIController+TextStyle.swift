import AppKit
import GlimmerAI
import GlimmerCore

/// The agent's `style_text` step: words in a text layer get their own font, boldness, size
/// or colour, as when they're selected in the editor and changed in the options bar.
extension AIController {
    func performStyleText(_ step: AgentStep) throws {
        let s = session
        if let key = step.string("target")?.trimmingCharacters(in: .whitespaces), !key.isEmpty {
            guard let layer = s.state.allLayers.reversed().first(where: {
                $0.id.uuidString.caseInsensitiveCompare(key) == .orderedSame || $0.name.caseInsensitiveCompare(key) == .orderedSame
            }) else { throw StepError("No layer named “\(key)”.") }
            s.setActiveLayer(layer.id)
        }
        guard let layer = s.activeLayer, case .text(var text) = layer.content else {
            throw StepError("The layer isn't a text layer.", reason: "not_text")
        }
        do {
            stepInfo = try StyleTextStep.apply(step, to: &text)
        } catch let refusal as StyleTextStep.Refusal {
            throw StepError(refusal.message, reason: refusal.reason)
        }
        let id = layer.id
        s.edit(String(localized: "Style Text")) { $0.updateLayer(id) { $0.content = .text(text) } }
    }
}
