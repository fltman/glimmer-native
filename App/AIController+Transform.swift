import AppKit
import GlimmerAI
import GlimmerCore

/// The agent's `transform_layer` step: Free Transform without the mouse, with the same rules
/// (text stays editable unless corners would rasterize it; groups with a pixel mask are refused).
extension AIController {
    func performTransformLayer(_ step: AgentStep) throws {
        let s = session
        if let key = step.string("target")?.trimmingCharacters(in: .whitespaces), !key.isEmpty {
            guard let layer = s.state.allLayers.reversed().first(where: {
                $0.id.uuidString.caseInsensitiveCompare(key) == .orderedSame || $0.name.caseInsensitiveCompare(key) == .orderedSame
            }) else { throw StepError("No layer named “\(key)”.") }
            s.setActiveLayer(layer.id)
        }
        guard let layer = s.activeLayer else { throw StepError("There's no layer to transform.") }
        if layer.isGroup, let masked = layer.subtree.dropFirst().first(where: { $0.mask != nil && $0.vectorMask == nil }) {
            throw StepError("“\(masked.name)” in this group has a layer mask, which a transform can't move with it.", reason: "group_has_mask")
        }
        var corners: [SIMD2<Double>]?
        if case .array(let list)? = step.params["corners"] {
            let points = list.compactMap { v -> SIMD2<Double>? in
                guard case .array(let xy) = v, xy.count == 2, let x = xy[0].number, let y = xy[1].number else { return nil }
                return SIMD2(x, y)
            }
            guard points.count == 4, points.count == list.count else {
                throw StepError("corners needs four [x, y] points: top-left, top-right, bottom-right, bottom-left.", reason: "bad_corners")
            }
            // In the order given the outline must be convex and not cross itself.
            guard EditorSession.isConvex(points) else {
                throw StepError("These corners cross each other; give them top-left, top-right, bottom-right, bottom-left.", reason: "bad_corners")
            }
            corners = points
        }
        let errorBefore = s.errorMessage
        s.beginTransform()
        guard var t = s.transformSession else {
            // beginTransform explains in errorMessage (shown in the window); report it here instead.
            let message = s.errorMessage ?? "This layer can't be transformed."
            s.errorMessage = errorBefore
            throw StepError(message, reason: "cannot_transform")
        }
        if let corners {
            t.quad = corners
            t.mode = .distort
            s.transformSession = t
            s.updateTransformPreview()
        } else {
            s.setTransform(scaleXPercent: step.number("scaleX"), scaleYPercent: step.number("scaleY"), degrees: step.number("degrees"))
            let skewX = (step.number("skewX") ?? 0) * .pi / 180, skewY = (step.number("skewY") ?? 0) * .pi / 180
            if skewX != 0 || skewY != 0, var t = s.transformSession {
                // Skew moves opposite edges apart, about the box's centre (still affine).
                let c = t.box.corners, centre = t.box.centre
                t.quad = c.map { p in SIMD2(p.x + tan(skewX) * (p.y - centre.y), p.y + tan(skewY) * (p.x - centre.x)) }
                t.mode = .skew
                s.transformSession = t
                s.updateTransformPreview()
            }
        }
        let rasterizing = s.textLayersToRasterize
        if rasterizing > 0, step.params["allowRasterize"]?.bool != true {
            s.cancelTransform()
            throw StepError("\(rasterizing) text layer\(rasterizing == 1 ? "" : "s") would become pixels; pass allowRasterize: true to allow it.",
                            reason: "would_rasterize_text")
        }
        s.commitTransform(confirmed: true)
    }
}
