import Foundation
import GlimmerCore

/// The parts of `crop`, `resize_image`, `select_rect`, `set_layer` and `add_image` that don't
/// need the editor: what the request means, and why it is refused.
public enum CanvasSteps {
    public struct Refusal: Error, LocalizedError, Equatable {
        public let reason: String
        public let message: String
        public var errorDescription: String? { message }

        public init(reason: String, message: String) {
            self.reason = reason
            self.message = message
        }
    }

    /// The largest side of a document, as for a new document.
    public static let maxSide = 30_000

    /// A request that contradicts itself (answered 400, before any step runs), or nil.
    public static func malformed(_ step: AgentStep) -> String? {
        func has(_ key: String) -> Bool { if let v = step.params[key], v != .null { true } else { false } }
        switch step.op {
        case "crop":
            let rect = ["x", "y", "width", "height"].contains(where: has)
            let forms = [rect, step.params["toSelection"]?.bool == true, has("aspect")].filter { $0 }.count
            if forms > 1 { return "crop takes one of: x/y/width/height, toSelection, or aspect." }
            if forms == 0 { return "crop needs x/y/width/height, toSelection: true, or aspect." }
            if rect, !(has("width") && has("height")) { return "crop needs both width and height." }
        case "resize_image":
            let size = has("width") || has("height")
            if size, has("scale") { return "resize_image takes width/height or scale, not both." }
            if !size, !has("scale") { return "resize_image needs width, height or scale." }
        case "select_rect":
            if !(has("width") && has("height")) { return "select_rect needs x, y, width and height." }
        default:
            break
        }
        return nil
    }

    /// "16:9" → 16 / 9. Both numbers must be positive.
    public static func aspect(_ text: String) -> Double? {
        let parts = text.split(separator: ":", omittingEmptySubsequences: false).map { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard parts.count == 2, let w = parts[0], let h = parts[1], w > 0, h > 0, w.isFinite, h.isFinite else { return nil }
        return w / h
    }

    /// The step's rectangle clipped to the canvas, or `bad_rect`.
    public static func rect(_ step: AgentStep, canvas: PixelRect) throws -> PixelRect {
        let x = (step.number("x") ?? 0).rounded(), y = (step.number("y") ?? 0).rounded()
        let w = (step.number("width") ?? 0).rounded(), h = (step.number("height") ?? 0).rounded()
        guard [x, y, w, h].allSatisfy({ $0.isFinite && abs($0) < 1e9 }), w >= 1, h >= 1 else {
            throw Refusal(reason: "bad_rect", message: "width and height must be at least 1 pixel.")
        }
        let r = PixelRect(x: Int(x), y: Int(y), width: Int(w), height: Int(h)).intersection(canvas)
        guard !r.isEmpty else {
            throw Refusal(reason: "bad_rect", message: "The rectangle is outside the canvas (\(canvas.width) × \(canvas.height)).")
        }
        return r
    }

    /// The box `crop` cuts to. `selection` is the bounds of the selection, if there is one.
    public static func cropBox(_ step: AgentStep, canvas: PixelRect, selection: PixelRect?) throws -> PixelRect {
        if step.params["toSelection"]?.bool == true {
            guard let s = selection?.intersection(canvas), !s.isEmpty else {
                throw Refusal(reason: "no_selection", message: "There's no selection to crop to.")
            }
            return s
        }
        if let text = step.string("aspect") {
            guard let a = aspect(text) else {
                throw Refusal(reason: "bad_aspect", message: "aspect must be W:H with positive numbers, like 16:9.")
            }
            // The largest centred box of that shape.
            var w = canvas.width, h = Int((Double(canvas.width) / a).rounded())
            if h > canvas.height {
                h = canvas.height
                w = Int((Double(canvas.height) * a).rounded())
            }
            w = min(max(w, 1), canvas.width)
            h = min(max(h, 1), canvas.height)
            return PixelRect(x: canvas.x + (canvas.width - w) / 2, y: canvas.y + (canvas.height - h) / 2, width: w, height: h)
        }
        return try rect(step, canvas: canvas)
    }

    /// The size `resize_image` gives a `width` × `height` image. One of width and height keeps
    /// the proportions; both give exactly that size.
    public static func newSize(_ step: AgentStep, width: Int, height: Int) throws -> (width: Int, height: Int) {
        var w = Double(width), h = Double(height)
        if let scale = step.number("scale") {
            w *= scale
            h *= scale
        } else {
            switch (step.number("width"), step.number("height")) {
            case (let nw?, let nh?): (w, h) = (nw, nh)
            case (let nw?, nil): (w, h) = (nw, h * nw / w)
            case (nil, let nh?): (w, h) = (w * nh / h, nh)
            default: break
            }
        }
        guard w.isFinite, h.isFinite, w.rounded() >= 1, h.rounded() >= 1,
              w.rounded() <= Double(maxSide), h.rounded() <= Double(maxSide) else {
            throw Refusal(reason: "bad_size", message: "The new size must be 1…\(maxSide) pixels on each side.")
        }
        return (Int(w.rounded()), Int(h.rounded()))
    }

    /// What `set_layer` changes.
    public struct LayerChange: Equatable {
        public var opacity: Double?
        public var blendMode: BlendMode?
        public var visible: Bool?
        public var name: String?
    }

    public static func layerChange(_ step: AgentStep, isGroup: Bool) throws -> LayerChange {
        var c = LayerChange()
        if let o = step.number("opacity") {
            guard (0...1).contains(o) else { throw Refusal(reason: "bad_opacity", message: "opacity must be 0…1.") }
            c.opacity = o
        }
        if let id = step.string("blendMode") {
            guard let mode = BlendMode(rawValue: id), mode != .passThrough || isGroup else {
                let ids = BlendMode.allCases.filter { $0 != .passThrough || isGroup }.map(\.rawValue).joined(separator: ", ")
                throw Refusal(reason: "unknown_blend_mode", message: "blendMode must be one of: \(ids).")
            }
            c.blendMode = mode
        }
        c.visible = step.params["visible"]?.bool
        if let name = step.string("name")?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            c.name = String(name.prefix(200))
        }
        guard c != LayerChange() else {
            throw Refusal(reason: "nothing_to_set", message: "Give opacity, blendMode, visible or name.")
        }
        return c
    }

    /// The layer a `target` means: its id, or its name when exactly one layer has it.
    /// `layers` is every layer, in any order.
    public static func target(_ key: String, in layers: [(id: UUID, name: String)]) throws -> UUID {
        let key = key.trimmingCharacters(in: .whitespaces)
        if let hit = layers.first(where: { $0.id.uuidString.caseInsensitiveCompare(key) == .orderedSame }) { return hit.id }
        let named = layers.filter { $0.name.caseInsensitiveCompare(key) == .orderedSame }
        if named.count > 1 {
            throw Refusal(reason: "ambiguous_target",
                          message: "\(named.count) layers are named “\(key)”. Use an id: \(named.map(\.id.uuidString).joined(separator: ", ")).")
        }
        guard let hit = named.first else { throw Refusal(reason: "unknown_layer", message: "No layer named “\(key)”.") }
        return hit.id
    }

    /// The box Canvas Size cuts or extends the canvas to, in the old canvas's pixels. `anchor`
    /// says which part of the image stays put: 0, 1 or 2 for left/centre/right and top/middle/bottom.
    public static func canvasBox(old: (width: Int, height: Int), new: (width: Int, height: Int),
                                 anchor: (x: Int, y: Int)) -> PixelRect {
        func origin(_ old: Int, _ new: Int, _ a: Int) -> Int {
            switch a {
            case 0: 0
            case 2: old - new
            default: Int((Double(old - new) / 2).rounded(.down))
            }
        }
        return PixelRect(x: origin(old.width, new.width, anchor.x), y: origin(old.height, new.height, anchor.y),
                         width: new.width, height: new.height)
    }

    /// How `add_image` fits an image into the canvas.
    public enum Fit: String, CaseIterable, Sendable { case none, contain, cover }

    /// Where an added image of `image` size lands: its size after fitting, and its top-left.
    /// `contain` only scales down; `cover` scales either way until the canvas is covered.
    public static func placement(image: (width: Int, height: Int), canvas: (width: Int, height: Int), fit: Fit,
                                 x: Double?, y: Double?) -> (x: Double, y: Double, width: Double, height: Double) {
        let iw = Double(image.width), ih = Double(image.height), cw = Double(canvas.width), ch = Double(canvas.height)
        let scale: Double = switch fit {
        case .none: 1
        case .contain: min(1, min(cw / iw, ch / ih))
        case .cover: max(cw / iw, ch / ih)
        }
        let w = iw * scale, h = ih * scale
        return (x ?? ((cw - w) / 2).rounded(), y ?? ((ch - h) / 2).rounded(), w, h)
    }
}
