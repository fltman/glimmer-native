import AppKit
import GlimmerAI
import GlimmerCore
import GlimmerRender

/// The agent's `crop`, `resize_image`, `select_rect` and `set_layer` steps.
extension AIController {
    private func refusing<T>(_ body: () throws -> T) throws -> T {
        do {
            return try body()
        } catch let refusal as CanvasSteps.Refusal {
            throw StepError(refusal.message, reason: refusal.reason)
        }
    }

    private static func json(_ r: PixelRect) -> [String: Any] { ["x": r.x, "y": r.y, "width": r.width, "height": r.height] }

    func performCrop(_ step: AgentStep) throws {
        let s = session
        let box = try refusing {
            try CanvasSteps.cropBox(step, canvas: s.state.bounds, selection: s.state.selection?.bounds(in: s.state.bounds))
        }
        if s.cropSession != nil { s.cropSession = nil }  // an open Crop tool box would be for the old canvas
        try s.cropCanvas(to: box, deletePixels: step.params["deletePixels"]?.bool ?? false)
        stepInfo = Self.json(box)
    }

    func performResizeImage(_ step: AgentStep) throws {
        let s = session
        let size = try refusing { try CanvasSteps.newSize(step, width: s.state.width, height: s.state.height) }
        try s.resizeImage(width: size.width, height: size.height)
        stepInfo = ["width": size.width, "height": size.height]
    }

    func performResizeCanvas(_ step: AgentStep) throws {
        let s = session
        let w = s.state.width, h = s.state.height
        let box = try refusing { try CanvasSteps.canvasBox(step, width: w, height: h) }
        let fillText = step.string("fill")
        let fill = parseHexColor(fillText)
        if fillText != nil, fill == nil { throw StepError("fill must be #RRGGBB.", reason: "bad_color") }
        if s.cropSession != nil { s.cropSession = nil }
        if box.width != w || box.height != h {
            try s.cropCanvas(to: box, deletePixels: false, actionName: String(localized: "Canvas Size"))
        }
        var info = Self.json(box)
        if let fill {
            if box.width > w || box.height > h {
                let layer = Layer(name: String(localized: "Canvas Fill"), content: .fill(.solid(fill)))
                s.edit(String(localized: "Canvas Size")) { $0.layers.insert(layer, at: 0) }
                info["fill"] = "added"
            } else {
                info["fill"] = "not_needed"
            }
        }
        stepInfo = info
    }

    func performSelectRect(_ step: AgentStep) throws {
        let s = session
        let box = try refusing { try CanvasSteps.rect(step, canvas: s.state.bounds) }
        let r = CGRectLike(x0: Double(box.x), y0: Double(box.y), x1: Double(box.maxX), y1: Double(box.maxY))
        var shape: Selection = step.string("shape") == "ellipse" ? .ellipse(in: r) : .rectangle(r)
        if let feather = step.number("feather"), feather > 0, let metal = s.metal {
            shape = try SelectionOps.apply(.feather(min(feather, 1000)), to: shape, limit: s.state.bounds, context: metal)
        }
        let mode: Selection.Operation = switch step.string("mode") {
        case "add": .add
        case "subtract": .subtract
        case "intersect": .intersect
        default: .replace
        }
        s.edit(String(localized: "Select")) { state in
            if let current = state.selection, mode != .replace {
                state.selection = current.combined(with: shape, mode)
            } else {
                // Nothing selected: adding gives the shape, taking away or intersecting gives nothing.
                state.selection = mode == .replace || mode == .add ? shape : nil
            }
        }
        stepInfo = Self.json(box)
    }

    func performSetLayer(_ step: AgentStep) throws {
        let s = session
        let id: UUID
        if let key = step.string("target")?.trimmingCharacters(in: .whitespaces), !key.isEmpty {
            id = try refusing { try CanvasSteps.target(key, in: s.state.allLayers.map { (id: $0.id, name: $0.name) }) }
        } else {
            guard let active = s.state.activeLayerID else { throw StepError("There's no active layer.", reason: "unknown_layer") }
            id = active
        }
        guard let layer = s.state.layer(id: id) else { throw StepError("There's no such layer.", reason: "unknown_layer") }
        var isGroup = false
        if case .group = layer.content { isGroup = true }
        let change = try refusing { try CanvasSteps.layerChange(step, isGroup: isGroup) }
        s.edit(String(localized: "Layer Properties")) { state in
            state.updateLayer(id) { l in
                if let v = change.opacity { l.opacity = v }
                if let v = change.blendMode { l.blendMode = v }
                if let v = change.visible { l.isVisible = v }
                if let v = change.name { l.name = v }
            }
        }
        stepInfo = ["layer": id.uuidString]
    }
}
