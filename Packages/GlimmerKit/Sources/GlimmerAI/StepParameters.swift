import Foundation
import GlimmerCore

/// A step may only carry parameters its operation has. A parameter under a name the
/// operation doesn't know used to be passed over in silence, so that an agent believed it
/// had done something it had not (found with `develop_raw`, 2026-11-16: "brightness" beside
/// a valid value ran with the valid value alone). The series' rule since: refused by name,
/// before anything is applied.
///
/// Everything here is read from the register that describes each operation (`AgentPlanner.ops`,
/// and for the nested settings the adjustment's, the filter's and the effect's own lists), so
/// an operation added later is covered without a line here.
public enum StepParameters {
    public struct Stray: Equatable, Sendable {
        /// The name the operation doesn't have.
        public let name: String
        /// Where it was: nil for the step's own parameters, "params" for the nested settings.
        public let inside: String?
        public let allowed: [String]
        public let op: String

        /// What a person would call the thing that was asked: the adjustment's, filter's or effect's
        /// name for a nested setting ("Exposure"), else the operation's ("Crop"). In English; the app says it in the person's language.
        public var subject: String = ""

        /// "crop has no parameter named widht. It has: x, y, width, height, toSelection, aspect."
        public var message: String {
            let place = inside.map { " in \($0)" } ?? ""
            let list = allowed.isEmpty ? "It takes none." : "It has: \(allowed.joined(separator: ", "))."
            return "\(op) has no parameter named \(name)\(place). \(list)"
        }
    }

    /// Said in a plan's step that carries a parameter its operation doesn't have.
    public static let strayNote = "asks for a setting that doesn't exist"

    /// Said in a plan's step in another app whose settings Glimmer could not check beforehand.
    public static let uncheckedNote = "Glimmer could not check these settings before running: the other app doesn't say which value chooses them, in"

    /// The first parameter of the step that its operation doesn't have, or nil. Unknown
    /// operations are someone else's to refuse.
    public static func stray(in step: AgentStep) -> Stray? {
        guard let op = AgentPlanner.op(named: step.op) else { return nil }
        let allowed = op.params.map(\.name)
        if let name = step.params.keys.sorted().first(where: { !allowed.contains($0) && $0 != "rationale" }) {
            return Stray(name: name, inside: nil, allowed: allowed, op: step.op, subject: step.op.replacingOccurrences(of: "_", with: " ").capitalized)
        }
        // The nested settings of the three operations that take them by type.
        guard case .object(let nested)? = step.params["params"], let keys = nestedKeys(op: step.op, type: step.string("type")) else { return nil }
        if let name = nested.keys.sorted().first(where: { !keys.contains($0) }) {
            let type = step.string("type") ?? ""
            let subject = AdjustmentKind(rawValue: type)?.title ?? FilterKind(rawValue: type)?.title ?? type
            return Stray(name: name, inside: "params", allowed: keys, op: step.op, subject: subject)
        }
        return nil
    }

    /// The setting names an operation's `params` object takes for this `type`, or nil when the
    /// operation has no such object or the type is not one it knows (refused elsewhere).
    public static func nestedKeys(op: String, type: String?) -> [String]? {
        guard let type else { return nil }
        switch op {
        case "add_adjustment":
            guard let kind = AdjustmentKind(rawValue: type) else { return nil }
            return kind.sliders.map(\.key) + kind.toggles.map(\.key) + kind.colors.map(\.key)
        case "apply_filter":
            return FilterKind(rawValue: type)?.fields.map(\.key)
        case "add_layer_effect":
            func keys<T: Encodable>(_ value: T) -> [String] {
                guard let data = try? JSONEncoder().encode(value), let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
                // The patch says "enabled" for the stored "isEnabled".
                return dict.keys.map { $0 == "isEnabled" ? "enabled" : $0 }.sorted()
            }
            switch type {
            case "dropShadow", "innerShadow": return keys(ShadowEffect())
            case "outerGlow": return keys(GlowEffect())
            case "stroke": return keys(StrokeEffect())
            case "colorOverlay": return keys(ColorOverlayEffect())
            default: return nil
            }
        default:
            return nil
        }
    }

    // MARK: Published schemas

    /// The settings an operation's `params` object takes, per `type`, as JSON Schema: what the
    /// check above enforces, published so a caller can stop a mistake before it calls
    /// (SIBLINGS.md §3). Nil for an operation without such an object.
    public static func nestedSchemas(op: String) -> [String: [String: Any]]? {
        func closed(_ properties: [String: Any]) -> [String: Any] { ["type": "object", "properties": properties, "additionalProperties": false] }
        switch op {
        case "add_adjustment":
            var out: [String: [String: Any]] = [:]
            for kind in AdjustmentKind.allCases {
                var p: [String: Any] = [:]
                for s in kind.sliders { p[s.key] = ["type": "number", "minimum": s.range.lowerBound, "maximum": s.range.upperBound, "default": s.defaultValue] }
                for t in kind.toggles { p[t.key] = ["type": "boolean", "default": t.defaultValue] }
                for c in kind.colors { p[c.key] = ["type": "string", "description": "#RRGGBB"] }
                out[kind.rawValue] = closed(p)
            }
            return out
        case "apply_filter":
            var out: [String: [String: Any]] = [:]
            for kind in FilterKind.allCases {
                var p: [String: Any] = [:]
                for f in kind.fields {
                    p[f.key] = f.isToggle ? ["type": "number", "enum": [0, 1], "default": f.defaultValue]
                                          : ["type": "number", "minimum": f.range.lowerBound, "maximum": f.range.upperBound, "default": f.defaultValue]
                }
                out[kind.rawValue] = closed(p)
            }
            return out
        case "add_layer_effect":
            func schema<T: Encodable>(_ value: T) -> [String: Any] {
                guard let data = try? JSONEncoder().encode(value), let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return closed([:]) }
                var p: [String: Any] = [:]
                for (key, v) in dict {
                    let name = key == "isEnabled" ? "enabled" : key
                    if v is [String: Any] { p[name] = ["type": "string", "description": "#RRGGBB"] }
                    else if let n = v as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() { p[name] = ["type": "boolean"] }
                    else if v is NSNumber { p[name] = ["type": "number"] }
                    else { p[name] = ["type": "string"] }
                }
                return closed(p)
            }
            return ["dropShadow": schema(ShadowEffect()), "innerShadow": schema(ShadowEffect()), "outerGlow": schema(GlowEffect()),
                    "stroke": schema(StrokeEffect()), "colorOverlay": schema(ColorOverlayEffect())]
        default:
            return nil
        }
    }

    /// The name every operation offered as a tool accepts and ignores for effect: a model adds it by habit.
    public static var rationaleSchema: [String: Any] { ["type": "string", "description": "Optional. One short sentence: why this step. Accepted everywhere and has no effect."] }

    // MARK: Endpoints

    /// The query parameters each API path takes (by its segments after /api/v1, with `*` for an id), and nothing else.
    public static func queryParameters(path: [String], method: String) -> [String] {
        switch (path.count, path.first, path.last, method) {
        case (1, "documents", _, "POST"): ["name"]
        case (3, "documents", "image", _): ["format", "maxSide"]
        case (3, "documents", "layers", "POST"): ["fit", "x", "y", "smartObject", "name"]
        case (2, "debug", "raw", _): ["name"]
        default: []
        }
    }

    /// What a JSON body may hold, by what it is for.
    public static let bodyParameters: [String: [String]] = [
        "steps": ["steps", "allowPaid", "allowUnknownPrice", "async"],
        "step": ["op", "params", "rationale", "id"],
        "documents": ["name", "image", "width", "height", "background"],
        "export": ["preset", "format", "depth", "flatten", "quality", "maxSide", "maxBytes", "size"],
        "layers": ["fromDocument"],
        "undo": [],
        "settings.open": ["pane"],
    ]

    /// "export has no parameter named qualty. It has: …", or nil when every name is known.
    public static func strayMessage(_ given: some Sequence<String>, allowed: [String], what: String) -> String? {
        guard let name = given.sorted().first(where: { !allowed.contains($0) && $0 != "rationale" }) else { return nil }
        return "\(what) has no parameter named \(name). " + (allowed.isEmpty ? "It takes none." : "It has: \(allowed.joined(separator: ", ")).")
    }
}
