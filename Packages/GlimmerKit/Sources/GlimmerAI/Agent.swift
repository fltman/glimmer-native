import Foundation
import GlimmerCore

/// A JSON value as the planner emits it (params are passed through loosely).
public enum JSONValue: Codable, Hashable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSONValue].self) { self = .array(a) }
        else if let o = try? c.decode([String: JSONValue].self) { self = .object(o) }
        else { self = .null }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let s): try c.encode(s)
        case .number(let n): try c.encode(n)
        case .bool(let b): try c.encode(b)
        case .object(let o): try c.encode(o)
        case .array(let a): try c.encode(a)
        case .null: try c.encodeNil()
        }
    }

    public var string: String? { if case .string(let s) = self { s } else { nil } }
    public var number: Double? {
        switch self {
        case .number(let n): n
        case .string(let s): Double(s)
        case .bool(let b): b ? 1 : 0
        default: nil
        }
    }
    public var object: [String: JSONValue]? { if case .object(let o) = self { o } else { nil } }

    /// Foundation form (for JSONSerialization round trips).
    public var any: Any {
        switch self {
        case .string(let s): s
        case .number(let n): n
        case .bool(let b): b
        case .object(let o): o.mapValues(\.any)
        case .array(let a): a.map(\.any)
        case .null: NSNull()
        }
    }
}

public struct AgentParam: Sendable {
    public let name: String
    public let type: String
    public let description: String
    public let options: [String]?

    public init(_ name: String, _ type: String, _ description: String, options: [String]? = nil) {
        self.name = name
        self.type = type
        self.description = description
        self.options = options
    }
}

/// One operation the planner may use. The system prompt is generated from this
/// list, so the model and the executor can't drift apart.
public struct AgentOp: Sendable {
    public let name: String
    public let description: String
    public let params: [AgentParam]
    /// Runs an AI job (costs money, takes a while).
    public let isAIJob: Bool
    /// Through the API, a request with this step always runs as a job (202), like every paid step.
    public var startsJob: Bool { isAIJob }

    public init(_ name: String, _ description: String, _ params: [AgentParam] = [], aiJob: Bool = false) {
        self.name = name
        self.description = description
        self.params = params
        self.isAIJob = aiJob
    }
}

public struct AgentStep: Codable, Hashable, Sendable, Identifiable {
    public var id = UUID()
    public var op: String
    public var params: [String: JSONValue]
    public var rationale: String?

    enum CodingKeys: String, CodingKey { case op, params, rationale }

    public init(op: String, params: [String: JSONValue] = [:], rationale: String? = nil) {
        self.op = op
        self.params = params
        self.rationale = rationale
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        op = (try? c.decode(String.self, forKey: .op)) ?? ""
        params = (try? c.decode([String: JSONValue].self, forKey: .params)) ?? [:]
        rationale = try? c.decode(String.self, forKey: .rationale)
    }

    public func string(_ key: String) -> String? { params[key]?.string }
    public func number(_ key: String) -> Double? { params[key]?.number }
    public func object(_ key: String) -> [String: JSONValue] { params[key]?.object ?? [:] }
}

public struct AgentPlan: Sendable, Equatable {
    public var steps: [AgentStep]
    public var message: String?
    /// Ops the model invented (dropped).
    public var droppedOps: [String] = []

    public init(steps: [AgentStep], message: String? = nil, droppedOps: [String] = []) {
        self.steps = steps
        self.message = message
        self.droppedOps = droppedOps
    }

    public var usesAI: Bool { steps.contains { AgentPlanner.op(named: $0.op)?.isAIJob == true } }
}

/// A plan kept for reuse: runs again without the planner (and without cost, unless it has AI steps).
public struct SavedAction: Codable, Identifiable, Hashable, Sendable {
    public var id = UUID()
    public var name: String
    public var steps: [AgentStep]

    public init(name: String, steps: [AgentStep]) {
        self.name = name
        self.steps = steps
    }

    static let key = "assistant.savedActions"

    public static func load(_ defaults: UserDefaults = .standard) -> [SavedAction] {
        guard let data = defaults.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([SavedAction].self, from: data)) ?? []
    }

    public static func store(_ actions: [SavedAction], _ defaults: UserDefaults = .standard) {
        defaults.set(try? JSONEncoder().encode(actions), forKey: key)
    }
}

/// What the planner knows about the open document.
public struct AgentContext: Sendable {
    public var width: Int
    public var height: Int
    public var layerCount: Int
    public var hasSelection: Bool
    public var activeLayerKind: String
    public var activeLayerName: String

    public init(width: Int, height: Int, layerCount: Int, hasSelection: Bool, activeLayerKind: String, activeLayerName: String) {
        self.width = width
        self.height = height
        self.layerCount = layerCount
        self.hasSelection = hasSelection
        self.activeLayerKind = activeLayerKind
        self.activeLayerName = activeLayerName
    }
}

public enum AgentPlanner {
    /// Command ids the agent may run directly (no file dialogs or destructive app-level actions).
    public static let runnableCommands: [CommandDescriptor] = CommandRegistry.standard.descriptors.filter { d in
        [.layer, .select, .image, .view].contains(d.category) && d.id.adjustmentKind == nil && !d.isSystemProvided
            && ![CommandID.layerStyle, .newSolidFill, .newGradientFill, .newPatternFill,
                 .featherSelection, .growSelection, .shrinkSelection, .crop, .freeTransform].contains(d.id)
    }

    private static func number(_ v: Double) -> String {
        v == v.rounded() ? String(Int(v)) : String(format: "%.2g", v)
    }

    /// "brightness_contrast: brightness (-1…1, 0), contrast (-1…1, 0); …" from the schema.
    static let adjustmentReference: String = AdjustmentKind.allCases.compactMap { kind -> String? in
        var keys = kind.sliders.map { "\($0.key) (\(number($0.range.lowerBound))…\(number($0.range.upperBound)), \(number($0.defaultValue)))" }
        keys += kind.toggles.map { "\($0.key) (true/false)" }
        keys += kind.colors.map { "\($0.key) (#RRGGBB)" }
        return keys.isEmpty ? nil : "\(kind.rawValue): " + keys.joined(separator: ", ")
    }.joined(separator: "; ")

    static let filterReference: String = FilterKind.allCases.map { kind in
        let keys = kind.fields.map { f in
            f.isToggle ? "\(f.key) (0/1)" : "\(f.key) (\(number(f.range.lowerBound))…\(number(f.range.upperBound)), \(number(f.defaultValue)))"
        }
        return "\(kind.rawValue): " + (keys.isEmpty ? "no settings" : keys.joined(separator: ", "))
    }.joined(separator: "; ")

    public static let ops: [AgentOp] = [
        AgentOp("add_adjustment", "Add a non-destructive adjustment layer above the active layer (contrast, hue, black & white, curves …).", [
            AgentParam("type", "string", "Which adjustment.", options: AdjustmentKind.allCases.map(\.rawValue)),
            AgentParam("params", "object", "Settings by key; omitted keys keep their default, {} is neutral. Keys (range, default) per type — " + adjustmentReference + ". Moderate values look natural: exposure is in stops (±0.3–1), most −1…1 sliders are strong beyond ±0.4. For a colour cast use color_balance (positive B = bluer, positive R = redder) or photo_filter."),
        ]),
        AgentOp("apply_filter", "Apply a destructive pixel filter to the active pixel layer (inside the selection if there is one).", [
            AgentParam("type", "string", "Which filter.", options: FilterKind.allCases.map(\.rawValue)),
            AgentParam("params", "object", "Settings by key; {} uses the defaults. Keys (range, default) per type — " + filterReference + "."),
        ]),
        AgentOp("add_layer_effect", "Add or update a layer style on the active layer.", [
            AgentParam("type", "string", "Which effect.", options: ["dropShadow", "innerShadow", "outerGlow", "stroke", "colorOverlay"]),
            AgentParam("params", "object", "Patch, e.g. {\"distance\": 8, \"opacity\": 0.5, \"size\": 12} for dropShadow, {\"width\": 4, \"color\": \"#ffffff\"} for stroke, or {}."),
        ]),
        AgentOp("apply_preset", "Apply a finished photo look (adjustment group plus grain/vignette).", [
            AgentParam("name", "string", "Preset name.", options: Preset.all.map(\.name)),
        ]),
        AgentOp("add_text", "Add a text layer.", [
            AgentParam("text", "string", "The text."),
            AgentParam("color", "string", "#RRGGBB colour (optional, default the foreground colour)."),
            AgentParam("size", "number", "Font size in pixels (optional; default ~8% of the image height)."),
            AgentParam("position", "string", "Where to place it.", options: ["top", "center", "bottom"]),
        ]),
        AgentOp("image_edit_composite", "Edit the WHOLE visible image with a natural-language instruction (content-aware: \"make it snowy\", \"change the car to red\"). The result lands as a new layer.", [
            AgentParam("instruction", "string", "The change to make."),
        ], aiJob: true),
        AgentOp("generate_layer", "Generate a new image from a text prompt as a new layer.", [
            AgentParam("prompt", "string", "What to generate."),
        ], aiJob: true),
        AgentOp("auto_enhance", "Automatic tone and colour correction (on-device, free, instant) as editable adjustment layers. A good first step for \"fix\", \"improve\" or \"make it look better\" before any creative changes."),
        AgentOp("auto_color", "Neutralise a colour cast (on-device, free) with a Color Balance layer. For \"too yellow/blue/green\", \"fix the white balance\"."),
        AgentOp("select_sky", "Select the sky (on-device, free). Use before replacing or adjusting the sky."),
        AgentOp("select_people", "Select every person in the image (on-device, free, more precise than select_subject for people)."),
        AgentOp("remove_background", "Cut the main subject out of the active layer onto transparency (adds a mask; on-device, free)."),
        AgentOp("select_subject", "Select the main subject (on-device, free)."),
        AgentOp("inpaint_selection", "Regenerate or erase the SELECTED region. Requires a selection.", [
            AgentParam("prompt", "string", "What to fill the selection with (may be empty for remove)."),
            AgentParam("mode", "string", "fill replaces with the prompt; remove erases an object.", options: ["fill", "remove"]),
        ], aiJob: true),
        AgentOp("upscale", "Upscale the whole image.", [
            AgentParam("scale", "number", "2 or 4 (on-device Real-ESRGAN, free)."),
        ], ),
        AgentOp("fill", "Fill the selection (or the whole active layer) with a colour.", [
            AgentParam("color", "string", "#RRGGBB or #RRGGBBAA."),
        ]),
        AgentOp("set_foreground", "Set the foreground (paint) colour.", [
            AgentParam("color", "string", "#RRGGBB."),
        ]),
        AgentOp("select_all", "Select the whole canvas."),
        AgentOp("deselect", "Clear the selection."),
        AgentOp("invert_selection", "Invert the selection."),
        AgentOp("feather_selection", "Soften the selection edge.", [AgentParam("radius", "number", "Pixels.")]),
        AgentOp("select_layer", "Make a layer the active one, so the following steps act on it. New layers become active by themselves.", [
            AgentParam("name", "string", "The layer's name (not case-sensitive; the topmost match wins) or its id."),
        ]),
        AgentOp("new_layer", "Add an empty pixel layer.", [AgentParam("name", "string", "Optional layer name.")]),
        AgentOp("transform_layer", "Scale, rotate, skew or distort a layer or a group, like Free Transform. Text stays editable for scale, rotation and skew; corners (distort or perspective) would turn text into pixels and are refused unless allowRasterize is true. One undo step.", [
            AgentParam("target", "string", "Optional. The layer's or group's name or id; default the active layer."),
            AgentParam("scaleX", "number", "Optional. Width in percent of the current size (default 100)."),
            AgentParam("scaleY", "number", "Optional. Height in percent of the current size (default 100)."),
            AgentParam("degrees", "number", "Optional. Rotation about the centre, clockwise."),
            AgentParam("skewX", "number", "Optional. Horizontal skew in degrees."),
            AgentParam("skewY", "number", "Optional. Vertical skew in degrees."),
            AgentParam("corners", "points", "Optional. Four corners in document pixels, top-left, top-right, bottom-right, bottom-left, for distort or perspective (replaces scale, rotation and skew)."),
            AgentParam("allowRasterize", "boolean", "Optional. Let corners turn text layers into pixels (default false)."),
        ]),
        AgentOp("add_waveform", "Draw the waveform of the sound open in Jämmer (the series' audio editor, a separate app) as a new shape layer, for a cover or poster. It stays a vector shape the user can recolour, move and style.", [
            AgentParam("style", "string", "Optional. bars (default) or wave (one outline).", options: SiblingWaveform.Style.allCases.map(\.rawValue)),
            AgentParam("bars", "number", "Optional. How many bars, 16–400 (default 64)."),
            AgentParam("color", "string", "Optional. #RRGGBB; default the foreground colour."),
            AgentParam("height", "number", "Optional. Share of the canvas height, 0.05–1 (default 0.3)."),
            AgentParam("width", "number", "Optional. Share of the canvas width, 0.1–1 (default 0.8)."),
            AgentParam("position", "string", "Optional. center (default), top or bottom.", options: ["center", "top", "bottom"]),
            AgentParam("document", "string", "Optional. The Jämmer document id or name; default the one in front."),
        ]),
        AgentOp("run_command", "Run an editor menu command.", [
            AgentParam("id", "string", "Command id.", options: runnableCommands.map(\.id.rawValue)),
        ]),
    ]

    public static func op(named name: String) -> AgentOp? { ops.first { $0.name == name } }

    static let preamble = """
    You are the planning brain of Glimmer, a native macOS photo editor (a modern Photoshop). The user states a goal in natural language; you turn it into an ordered PLAN of editor operations that a deterministic executor runs.

    Only use the operations listed under AVAILABLE OPS. Each step names one op exactly and supplies concrete params. Never invent ops, params or values that are not described.

    Guidelines:
    - Order steps the way an expert retoucher would (select before inpainting; remove the background before adding a drop shadow).
    - Prefer the editor's native, non-destructive ops (add_adjustment, apply_preset, add_layer_effect, apply_filter, selection ops). Use image_edit_composite and generate_layer only for content changes the native ops cannot express: they cost money and take time.
    - inpaint_selection needs a selection. If there is none and the goal needs one, add a step that makes one (select_subject, select_all + invert_selection …) or ask a clarifying question.
    - Colours are #RRGGBB hex strings.
    - When unsure about a param, send {} (or omit it) to get sensible defaults rather than guessing exotic numbers.
    - If the goal is ambiguous, contradictory or impossible with these ops, return an empty "steps" array and put a short clarifying question in "message".
    - If the user is only chatting or asking a question about the editor, answer briefly in "message" with no steps.
    - Keep each step's "rationale" to one short sentence.

    OUTPUT FORMAT — return ONLY one JSON object, no markdown:
    {"steps": [{"op": "<op name>", "params": {…}, "rationale": "<short>"}], "message": "<short summary of the plan, or a question>"}
    """

    public static func renderOps() -> String {
        ops.map { op in
            let params = op.params.isEmpty ? "    (no params)" : op.params.map { p in
                let opts = p.options.map { " — one of: \($0.joined(separator: ", "))" } ?? ""
                return "    - \(p.name) (\(p.type)): \(p.description)\(opts)"
            }.joined(separator: "\n")
            return "- \(op.name)\(op.isAIJob ? " [AI job]" : ""): \(op.description)\n\(params)"
        }.joined(separator: "\n\n")
    }

    public static func systemPrompt() -> String {
        preamble + "\n\nAVAILABLE OPS:\n" + renderOps()
    }

    public static func userPrompt(goal: String, context: AgentContext, history: [(user: String, reply: String)]) -> String {
        var text = """
        CURRENT EDITOR CONTEXT:
        - canvas: \(context.width)×\(context.height) px
        - layers: \(context.layerCount)
        - active layer: \(context.activeLayerName) (\(context.activeLayerKind))
        - hasSelection: \(context.hasSelection)

        """
        if !history.isEmpty {
            text += "EARLIER IN THIS CONVERSATION:\n"
            for turn in history.suffix(6) {
                text += "- user: \(turn.user)\n  you: \(turn.reply)\n"
            }
            text += "\n"
        }
        text += "USER GOAL:\n\(goal)\n\nReturn the JSON plan now."
        return text
    }

    /// Parses the model's reply: tolerates code fences and prose around the JSON,
    /// drops unknown ops and malformed steps instead of failing the plan.
    public static func parsePlan(_ text: String) throws -> AgentPlan {
        guard let json = extractJSONObject(text) else {
            // Plain prose: treat as a chat answer.
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { throw AgentError.emptyResponse }
            return AgentPlan(steps: [], message: trimmed)
        }
        struct Raw: Decodable {
            var steps: [JSONValue]?
            var message: String?
        }
        let raw = try JSONDecoder().decode(Raw.self, from: Data(json.utf8))
        var steps: [AgentStep] = []
        var dropped: [String] = []
        for value in raw.steps ?? [] {
            guard let data = try? JSONEncoder().encode(value),
                  let step = try? JSONDecoder().decode(AgentStep.self, from: data) else { continue }
            if op(named: step.op) == nil, SiblingApp.split(tool: step.op) == nil {
                dropped.append(step.op)
            } else {
                steps.append(step)
            }
        }
        return AgentPlan(steps: steps, message: raw.message, droppedOps: dropped)
    }

    static func extractJSONObject(_ text: String) -> String? {
        guard let start = text.firstIndex(of: "{") else { return nil }
        var depth = 0
        var inString = false
        var escaped = false
        var i = start
        while i < text.endIndex {
            let ch = text[i]
            if inString {
                if escaped { escaped = false } else if ch == "\\" { escaped = true } else if ch == "\"" { inString = false }
            } else if ch == "\"" {
                inString = true
            } else if ch == "{" {
                depth += 1
            } else if ch == "}" {
                depth -= 1
                if depth == 0 { return String(text[start...i]) }
            }
            i = text.index(after: i)
        }
        return nil
    }

    // MARK: Suggestions

    /// An edit the assistant proposes for this particular photo.
    public struct Suggestion: Sendable, Hashable, Identifiable {
        public var id: String { title }
        /// Two or three words for a button.
        public var title: String
        /// The request to send to the planner when it is chosen.
        public var goal: String
    }

    static let suggestionPrompt = """
    You are a photo retoucher looking at a user's image in a photo editor. Propose exactly three different edits that would genuinely improve or creatively transform THIS photo, based on what you see (its light, colours, subject, flaws). Make them distinct: for example one corrective, one mood, one bold.
    The editor can do: tonal and colour adjustments, black & white, blur/sharpen/vignette/grain filters, photo looks, text, removing the background, and AI edits of content.
    Return ONLY JSON: {"suggestions": [{"title": "<2-3 words>", "goal": "<one sentence instructing the edit, specific to this photo>"}]}
    Write title and goal in the language with code "%@".
    """

    public static func parseSuggestions(_ text: String) -> [Suggestion] {
        struct Raw: Decodable {
            struct Item: Decodable { var title: String?; var goal: String? }
            var suggestions: [Item]?
        }
        guard let json = extractJSONObject(text), let raw = try? JSONDecoder().decode(Raw.self, from: Data(json.utf8)) else { return [] }
        var seen = Set<String>()
        return (raw.suggestions ?? []).compactMap { item in
            guard let title = item.title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty,
                  let goal = item.goal?.trimmingCharacters(in: .whitespacesAndNewlines), !goal.isEmpty,
                  seen.insert(title).inserted else { return nil }
            return Suggestion(title: title, goal: goal)
        }.prefix(3).map { $0 }
    }

    /// Looks at the image (JPEG) and proposes three edits.
    public static func suggestions(image: Data, language: String, client: OpenRouterClient, model: String) async throws -> [Suggestion] {
        let response = try await client.textCompletion(model: model, system: nil,
                                                       user: String(format: suggestionPrompt, language),
                                                       images: [image], imageType: "image/jpeg", jsonMode: true, temperature: 0.7)
        return parseSuggestions(response.text)
    }

    // MARK: Tool calling

    static let toolPreamble = """
    You are the planning brain of Glimmer, a native macOS photo editor (a modern Photoshop). The user states a goal in natural language; you carry it out by calling the editor's tools. Every tool call becomes one step of a plan that a deterministic executor runs in the order you call them.

    Guidelines:
    - Call tools in the order an expert retoucher would (select before inpainting; remove the background before adding a drop shadow).
    - Prefer the editor's native, non-destructive tools (add_adjustment, apply_preset, add_layer_effect, apply_filter, selection tools). Use image_edit_composite and generate_layer only for content changes the native tools cannot express: they cost money and take time.
    - inpaint_selection needs a selection. If there is none and the goal needs one, make one first (select_subject, select_all …) or ask a clarifying question.
    - Colours are #RRGGBB hex strings. When unsure about a setting, pass {} to get sensible defaults rather than guessing exotic numbers.
    - Give each call a one-sentence "rationale".
    - Alongside the calls, reply with one short sentence summarising the plan, in the user's language.
    - If the goal is ambiguous, contradictory or impossible with these tools, call no tools and ask a short clarifying question.
    - If the user is only chatting or asking about the editor, answer briefly without calling tools.
    - When a picture of the current image is attached, look at it: choose settings that suit this photo (its exposure, colours and subject) rather than generic ones.
    - Tools whose names start with jammer_ or flimmer_ (when present) act in Glimmer's sibling apps Jämmer (audio) and Flimmer (video), which run separately. Use them only when the user asks for something in that app. To bring Jämmer's sound into the image, use add_waveform.
    """

    static let reviewPreamble = """
    You are the quality check of Glimmer, a photo editor. The user asked for an edit and the editor carried out the steps listed. You see the image BEFORE (first picture) and AFTER (second picture).

    Judge whether the result meets what the user asked for.
    - If it does (or is close enough), call no tools and reply with one short sentence saying what was done, in the user's language.
    - If it clearly falls short (too weak, too strong, wrong direction, something asked for is missing), call at most three tools to correct it, building on the current result, and say in one short sentence what you are adjusting. Do not repeat steps that already worked.
    Colours are #RRGGBB. Pass {} for default settings.
    """

    /// The JSON Schema of an op's params. The assistant's tools, the API's operation
    /// list and the guide all use it, so they describe the same thing.
    public static func paramsSchema(_ op: AgentOp) -> [String: Any] {
        var properties: [String: Any] = [:]
        var required: [String] = []
        for p in op.params {
            var schema: [String: Any] = ["description": p.description]
            switch p.type {
            case "number": schema["type"] = "number"
            case "object": schema["type"] = "object"
            case "boolean": schema["type"] = "boolean"
            case "points":  // [[x, y], …]
                schema["type"] = "array"
                schema["items"] = ["type": "array", "items": ["type": "number"], "minItems": 2, "maxItems": 2]
            default: schema["type"] = "string"
            }
            if let options = p.options { schema["enum"] = options }
            properties[p.name] = schema
            if !p.description.localizedCaseInsensitiveContains("optional") { required.append(p.name) }
        }
        return ["type": "object", "properties": properties, "required": required]
    }

    /// One function tool per op; the schemas are generated from `ops`.
    public static func toolSchemas() -> [[String: Any]] {
        ops.map { op in
            var parameters = paramsSchema(op)
            var properties = parameters["properties"] as? [String: Any] ?? [:]
            properties["rationale"] = ["type": "string", "description": "One short sentence: why this step."]
            parameters["properties"] = properties
            let description = op.isAIJob ? op.description + " (AI job: costs money and takes a while.)" : op.description
            return ["type": "function", "function": ["name": op.name, "description": description, "parameters": parameters]]
        }
    }

    /// The conversation: system prompt, earlier turns, then the goal with the editor's state.
    public static func toolMessages(goal: String, context: AgentContext,
                                    history: [(user: String, reply: String)], image: Data? = nil,
                                    siblingContext: String? = nil) -> [[String: Any]] {
        var messages: [[String: Any]] = [["role": "system", "content": toolPreamble]]
        for turn in history.suffix(8) {
            messages.append(["role": "user", "content": turn.user])
            messages.append(["role": "assistant", "content": turn.reply])
        }
        let state = """
        [Editor state: canvas \(context.width)×\(context.height) px, \(context.layerCount) layers, \
        active layer “\(context.activeLayerName)” (\(context.activeLayerKind)), \
        \(context.hasSelection ? "there is a selection" : "no selection").]
        """
        let text = state + (siblingContext.map { "\n" + $0 } ?? "") + "\n\n" + goal
        if let image {
            messages.append(["role": "user", "content": [["type": "text", "text": text], imagePart(image)]])
        } else {
            messages.append(["role": "user", "content": text])
        }
        return messages
    }

    static func imagePart(_ jpeg: Data) -> [String: Any] {
        ["type": "image_url", "image_url": ["url": "data:image/jpeg;base64," + jpeg.base64EncodedString()]]
    }

    /// The quality check after a plan ran: goal, what was done, before and after.
    public static func reviewMessages(goal: String, steps: [AgentStep], before: Data, after: Data) -> [[String: Any]] {
        let done = steps.map { step -> String in
            let params = (try? JSONEncoder().encode(step.params)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
            return "- \(step.op) \(params)"
        }.joined(separator: "\n")
        let text = "USER REQUEST:\n\(goal)\n\nSTEPS CARRIED OUT:\n\(done)"
        return [["role": "system", "content": reviewPreamble],
                ["role": "user", "content": [["type": "text", "text": text], imagePart(before), imagePart(after)]]]
    }

    /// Tools the quality check may use: the editor's own, never paid AI jobs.
    public static func reviewToolSchemas() -> [[String: Any]] {
        zip(ops, toolSchemas()).filter { !$0.0.isAIJob }.map(\.1)
    }

    /// Asks the model to judge the result; returns corrective steps (possibly none).
    public static func review(goal: String, steps: [AgentStep], before: Data, after: Data,
                              client: OpenRouterClient, model: String) async throws -> AgentPlan {
        let response = try await client.toolCompletion(model: model,
                                                       messages: reviewMessages(goal: goal, steps: steps, before: before, after: after),
                                                       tools: reviewToolSchemas())
        var plan = try plan(from: response)
        plan.steps = Array(plan.steps.filter { op(named: $0.op)?.isAIJob == false }.prefix(3))
        return plan
    }

    /// Turns tool calls into a plan, dropping unknown tools and calls with unreadable arguments.
    /// `extra` are sibling tool names offered with this request.
    public static func plan(from response: OpenRouterClient.ToolResponse, extra: Set<String> = []) throws -> AgentPlan {
        var steps: [AgentStep] = []
        var dropped: [String] = []
        for call in response.toolCalls {
            guard op(named: call.name) != nil || extra.contains(call.name) else {
                dropped.append(call.name)
                continue
            }
            var params = (try? JSONDecoder().decode([String: JSONValue].self, from: Data(call.arguments.utf8))) ?? [:]
            let rationale = params.removeValue(forKey: "rationale")?.string
            // Some models send nested objects as JSON strings.
            for (key, value) in params {
                if case .string(let s) = value, s.hasPrefix("{"),
                   let o = try? JSONDecoder().decode([String: JSONValue].self, from: Data(s.utf8)) {
                    params[key] = .object(o)
                }
            }
            steps.append(AgentStep(op: call.name, params: params, rationale: rationale))
        }
        let text = response.text?.trimmingCharacters(in: .whitespacesAndNewlines)
        if steps.isEmpty, dropped.isEmpty, let text, text.contains("\"steps\"") {
            // A model that ignored the tools and wrote a JSON plan anyway.
            return try parsePlan(text)
        }
        if steps.isEmpty, dropped.isEmpty, text?.isEmpty ?? true { throw AgentError.emptyResponse }
        return AgentPlan(steps: steps, message: text?.isEmpty == false ? text : nil, droppedOps: dropped)
    }

    /// Asks the text model for a plan through tool calling.
    /// `siblings` are the running sibling apps' operations, offered as extra tools, and
    /// `siblingContext` names their open documents.
    public static func plan(goal: String, context: AgentContext, history: [(user: String, reply: String)],
                            image: Data? = nil, siblings: [SiblingOperation] = [], siblingContext: String? = nil,
                            client: OpenRouterClient, model: String,
                            onText: (@Sendable (String) -> Void)? = nil) async throws -> (AgentPlan, Double?) {
        let messages = toolMessages(goal: goal, context: context, history: history, image: image, siblingContext: siblingContext)
        let tools = toolSchemas() + siblings.map(\.toolSchema)
        let response = if let onText {
            try await client.toolCompletionStreaming(model: model, messages: messages, tools: tools, onText: onText)
        } else {
            try await client.toolCompletion(model: model, messages: messages, tools: tools)
        }
        return (try plan(from: response, extra: Set(siblings.map(\.toolName))), response.cost)
    }
}

public enum AgentError: Error, LocalizedError {
    case emptyResponse

    public var errorDescription: String? {
        switch self {
        case .emptyResponse: "The assistant returned an empty answer."
        }
    }
}

/// `#RRGGBB` / `#RRGGBBAA` → sRGB colour (alpha ignored).
public func parseHexColor(_ text: String?) -> SRGBColor? {
    guard var s = text?.trimmingCharacters(in: .whitespaces) else { return nil }
    if s.hasPrefix("#") { s.removeFirst() }
    guard s.count == 6 || s.count == 8, let v = UInt64(s.prefix(6), radix: 16) else { return nil }
    return SRGBColor(Double((v >> 16) & 0xff) / 255, Double((v >> 8) & 0xff) / 255, Double(v & 0xff) / 255)
}
