import Foundation
import GlimmerCore

extension AIPipelines {
    // MARK: Relight (workers/aips/tasks/relight.py)

    public enum LightDirection: String, CaseIterable, Sendable {
        case left, right, top, bottom, front, behind

        public var title: String { rawValue.capitalized }

        var phrase: String {
            switch self {
            case .left: "from the LEFT side of the frame (a side/key light entering from the left)"
            case .right: "from the RIGHT side of the frame (a side/key light entering from the right)"
            case .top: "from directly ABOVE (overhead/top light)"
            case .bottom: "from BELOW (an uplight / footlight pointing upward)"
            case .front: "from the FRONT, on the camera axis (flat frontal light)"
            case .behind: "from BEHIND the subject (backlight / rim light that haloes the edges)"
            }
        }

        var shadows: String {
            switch self {
            case .left: "casting soft shadows toward the right"
            case .right: "casting soft shadows toward the left"
            case .top: "casting soft shadows downward, under forms"
            case .bottom: "throwing shadows upward in an eerie, dramatic way"
            case .front: "minimizing cast shadows, filling the form evenly"
            case .behind: "leaving the camera-facing side in relative shadow with a bright rim"
            }
        }
    }

    public static func relightInstruction(direction: LightDirection, color: SRGBColor, intensity: Double,
                                          environment: String) -> String {
        let r = Int((color.r * 255).rounded()), g = Int((color.g * 255).rounded()), b = Int((color.b * 255).rounded())
        let temp = r - b > 30 ? "warm (golden/amber)" : (b - r > 30 ? "cool (blue/daylight)" : "neutral white")
        let hex = String(format: "#%02x%02x%02x", r, g, b)
        let strength = intensity >= 0.75
            ? "Make the relighting DRAMATIC and high-contrast, with strong highlights and deep, well-defined shadows"
            : intensity >= 0.4
                ? "Make the relighting clearly visible, with balanced highlights and natural, soft-edged shadows"
                : "Make the relighting SUBTLE — a gentle directional shaping with soft, low-contrast shadows"
        var parts = [
            "Relight this image. Add a dominant key light coming \(direction.phrase), \(direction.shadows).",
            "The light is \(temp) light, color hex \(hex); let it set the overall color temperature of highlights and the ambient fill.",
            "\(strength).",
        ]
        let env = environment.trimmingCharacters(in: .whitespacesAndNewlines)
        if !env.isEmpty {
            parts.append("Relight the scene as if the subject were in this environment: \"\(env)\". Adapt the background lighting, ambient color and reflections to that environment.")
        }
        parts.append("CRITICAL: change ONLY the lighting — its direction, color temperature, shadows and highlights. Keep the subject's identity, shapes, pose, materials and the overall composition EXACTLY the same. Do not move, add or remove objects, do not change the framing, and do not crop, rotate or resize the image.")
        return parts.joined(separator: " ")
    }

    public static func relight(_ image: RGBAImage, direction: LightDirection, color: SRGBColor, intensity: Double,
                               environment: String = "", model: ImageModel) async throws -> AIImageResult {
        let instruction = relightInstruction(direction: direction, color: color, intensity: intensity, environment: environment)
        return try await edit(image, instruction: instruction, model: model)
    }

    // MARK: Remove reflections (pipelines/remove_reflections.py)

    public static func reflectionsInstruction(strength: Double, confined: Bool) -> String {
        let region = confined ? "Work ONLY on the reflective surface in this crop" : "Work across the whole image"
        let degree = strength >= 0.75
            ? "Remove reflections and glare COMPLETELY and fully reveal whatever is behind the glass/surface, reconstructing the hidden detail plausibly"
            : strength >= 0.4
                ? "Clearly reduce the reflections and glare, revealing most of what is behind the glass/surface while keeping it looking natural"
                : "Gently knock back only the strongest reflection hotspots and glare, keeping the edit subtle"
        return [
            "\(region). Remove unwanted reflections, glare and specular hotspots from reflective surfaces — glass, windows, water, screens/monitors, and eyeglass lenses — so the subject behind the glass becomes clearly visible.",
            "\(degree).",
            "Preserve the surface itself (the frame, glass edges, screen bezel, lens rims) and everything that is genuinely behind or around it; do not invent new objects, text or logos.",
            "CRITICAL: change ONLY the reflections/glare. Keep the framing, perspective, geometry, colors and exposure of everything else EXACTLY the same. Do not recompose, crop, rotate or resize the image.",
        ].joined(separator: " ")
    }

    /// Removes reflections in `roi` (padded) or the whole image. Returns a layer image and origin.
    public static func removeReflections(_ image: RGBAImage, roi: PixelRect?, strength: Double,
                                         model: ImageModel) async throws -> InpaintResult {
        let full = PixelRect(x: 0, y: 0, width: image.width, height: image.height)
        let region = roi.map { Imaging.clampROI($0, width: image.width, height: image.height) } ?? full
        let confined = region != full
        let crop = image.cropped(to: region)
        let result = try await model.generate(prompt: reflectionsInstruction(strength: strength, confined: confined),
                                              images: [crop], seed: nil)
        let aligned = result.image.resized(width: region.width, height: region.height)
        var matched = Imaging.colorMatch(aligned, to: crop, trusted: GrayImage(width: region.width, height: region.height, fill: 255))
        if confined {
            let feather = Imaging.featherMask(GrayImage(width: region.width, height: region.height, fill: 255), erode: 2, blur: 3)
            matched = matched.withAlpha(feather)
        }
        return InpaintResult(image: matched, origin: SIMD2(region.x, region.y), cost: result.cost)
    }

    // MARK: Harmonize (pipelines/harmonize.py)

    public static func harmonizeInstruction(strength: Double) -> String {
        let degree = strength >= 0.75 ? "Strongly" : (strength >= 0.4 ? "Noticeably" : "Subtly")
        return "You are compositing. This image shows a subject that was inserted into a scene and currently looks pasted-in. \(degree) relight and color-grade the inserted subject so it matches the scene: align its lighting direction, color temperature, contrast and exposure to the surrounding environment, and add a plausible soft contact shadow where the subject meets the ground/surface. Keep the subject's identity, shape and pose exactly. Do NOT change the background, its framing, perspective or content, and do not crop, rotate or resize the image."
    }

    /// Re-grades `foreground` (RGBA, same size as `background`) to sit in the scene.
    /// Returns the subject with its original alpha.
    public static func harmonize(foreground: RGBAImage, background: RGBAImage, strength: Double,
                                 model: ImageModel) async throws -> AIImageResult {
        var composite = background
        for i in 0..<(background.width * background.height) {
            let a = foreground.pixels[i * 4 + 3] / 255
            for c in 0..<3 {
                composite.pixels[i * 4 + c] = foreground.pixels[i * 4 + c] * a + background.pixels[i * 4 + c] * (1 - a)
            }
            composite.pixels[i * 4 + 3] = 255
        }
        var result = try await model.generate(prompt: harmonizeInstruction(strength: strength), images: [composite], seed: nil)
        let aligned = result.image.resized(width: background.width, height: background.height)
        let k = Float(min(max(strength, 0), 1))
        var out = foreground
        for i in 0..<(foreground.width * foreground.height) {
            for c in 0..<3 {
                out.pixels[i * 4 + c] = foreground.pixels[i * 4 + c] * (1 - k) + aligned.pixels[i * 4 + c] * k
            }
        }
        result.image = out  // alpha stays the subject's own
        return result
    }

    // MARK: Upscale enhance (tasks/upscale.py)

    public static func enhanceInstruction(creativity: Double) -> String {
        let detail = creativity >= 0.66
            ? "add rich, realistic fine detail and texture, reconstructing plausible micro-structure where the upscale is soft"
            : creativity >= 0.33
                ? "add realistic fine detail and texture, and noticeably sharpen edges"
                : "subtly sharpen textures and edges and remove residual blur"
        return "Enhance this image: \(detail). Keep the composition, framing, subject shapes and colors IDENTICAL — do not move, add or remove objects, do not recolor, do not crop, rotate or resize. This is a detail/sharpness pass only."
    }

    /// Tile layout for the enhance pass (1024 px tiles, 96 px overlap).
    public static func enhanceTiles(width: Int, height: Int, tile: Int = 1024, overlap: Int = 96) -> [PixelRect] {
        func starts(_ length: Int) -> [Int] {
            guard length > tile else { return [0] }
            var s: [Int] = []
            var p = 0
            while p + tile < length { s.append(p); p += tile - overlap }
            s.append(length - tile)
            return s
        }
        return starts(height).flatMap { y in starts(width).map { x in
            PixelRect(x: x, y: y, width: min(tile, width), height: min(tile, height))
        } }
    }

    /// AI detail pass over an already upscaled image: tiled, colour-matched to the
    /// base, and blended with feathered seams (the web app pasted hard edges).
    public static func enhance(_ base: RGBAImage, creativity: Double, model: ImageModel,
                               progress: (@Sendable (Double) -> Void)? = nil) async throws -> AIImageResult {
        let tiles = enhanceTiles(width: base.width, height: base.height)
        var out = base
        var cost = 0.0
        let instruction = enhanceInstruction(creativity: creativity)
        for (n, rect) in tiles.enumerated() {
            try Task.checkCancellation()
            let crop = base.cropped(to: rect)
            let result = try await model.generate(prompt: instruction, images: [crop], seed: nil)
            cost += result.cost ?? 0
            let aligned = result.image.resized(width: rect.width, height: rect.height)
            let matched = Imaging.colorMatch(aligned, to: crop, trusted: GrayImage(width: rect.width, height: rect.height, fill: 255))
            // Feather 48 px on edges shared with other tiles.
            var alpha = GrayImage(width: rect.width, height: rect.height, fill: 255)
            let ramp = 48
            for y in 0..<rect.height {
                for x in 0..<rect.width {
                    var a: Float = 1
                    if rect.x > 0 { a = min(a, Float(x) / Float(ramp)) }
                    if rect.y > 0 { a = min(a, Float(y) / Float(ramp)) }
                    if rect.maxX < base.width { a = min(a, Float(rect.width - 1 - x) / Float(ramp)) }
                    if rect.maxY < base.height { a = min(a, Float(rect.height - 1 - y) / Float(ramp)) }
                    alpha.values[y * rect.width + x] = min(max(a, 0), 1) * 255
                }
            }
            let region = out.cropped(to: rect)
            out.paste(Imaging.blendMasked(region, matched, alpha: alpha), x: rect.x, y: rect.y)
            progress?(Double(n + 1) / Double(tiles.count))
        }
        return AIImageResult(image: out, cost: cost)
    }

    // MARK: Distractions (api/src/distractions)

    public struct Distraction: Identifiable, Sendable, Equatable {
        public var id: String
        public var label: String
        public var rationale: String?
        public var severity: String
        /// Normalized 0...1, top-left origin.
        public var box: (x: Double, y: Double, width: Double, height: Double)

        public static func == (a: Distraction, b: Distraction) -> Bool { a.id == b.id }

        public func pixelRect(width: Int, height: Int) -> PixelRect {
            PixelRect(x: Int(box.x * Double(width)), y: Int(box.y * Double(height)),
                      width: max(1, Int((box.width * Double(width)).rounded())),
                      height: max(1, Int((box.height * Double(height)).rounded())))
        }
    }

    public static let distractionSystemPrompt = """
    You are a photo-retouching assistant for an AI image editor. Given a single photograph, identify DISTRACTING elements that a professional retoucher would typically remove to improve the image.
    Look specifically for things like:
    - photobombers and random bystanders who are not the subject
    - litter, trash, clutter and other unwanted small objects
    - stray signs, billboards, posters, logos or watermarks
    - power lines, cables, poles and similar background clutter
    - lens dust, sensor spots, smudges and blemishes on the image itself
    - harsh blown-out highlights / specular hotspots that draw the eye
    - distracting reflections or glare on glass/screens (only if clearly unwanted)
    Do NOT flag the main subject, intentional compositional elements, or normal scene content. Only flag things whose removal would plausibly improve the photo.
    For each element return a bounding box in NORMALIZED image coordinates: x, y, width and height are fractions between 0 and 1 of the image's width/height, with the origin at the TOP-LEFT corner. Be generous enough that the box fully contains the element; the user will fine-tune the selection before anything is removed, so approximate boxes are fine, but they must stay within [0,1].
    OUTPUT FORMAT — return ONLY a single JSON object, no markdown, no prose around it:
    {
      "distractions": [
        {
          "id": "d1",
          "label": "<short label, e.g. 'photobomber', 'power line', 'litter'>",
          "rationale": "<optional one short sentence on why it's distracting>",
          "severity": "low" | "medium" | "high",
          "box": { "x": 0.0, "y": 0.0, "width": 0.0, "height": 0.0 }
        }
      ],
      "message": "<optional note; if nothing distracting is found, return an empty distractions array and a short message>"
    }
    If the image has no distracting elements, return {"distractions": [], "message": "No obvious distractions found."}.
    """

    /// Extracts the JSON object from a model reply (tolerates fences and prose).
    static func jsonObject(in text: String) -> [String: Any]? {
        if let d = text.data(using: .utf8), let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] { return o }
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end else { return nil }
        return (try? JSONSerialization.jsonObject(with: Data(text[start...end].utf8))) as? [String: Any]
    }

    /// Parses and sanitizes the analyzer reply (clamps boxes to [0,1], drops empty ones).
    public static func parseDistractions(_ text: String) -> (items: [Distraction], message: String?) {
        guard let json = jsonObject(in: text) else { return ([], "The model's reply couldn't be read.") }
        let raw = json["distractions"] as? [[String: Any]] ?? []
        var items: [Distraction] = []
        var leftOut = false
        for (i, d) in raw.enumerated() {
            guard let b = d["box"] as? [String: Any] else { continue }
            func n(_ k: String) -> Double { (b[k] as? NSNumber)?.doubleValue ?? 0 }
            let x = min(max(n("x"), 0), 1), y = min(max(n("y"), 0), 1)
            let w = min(max(n("width"), 0), 1 - x), h = min(max(n("height"), 0), 1 - y)
            guard w > 0.001, h > 0.001 else { continue }
            // The reason is the model's own text: a sentence with a figure nobody gave it goes (`AssistantNumbers`).
            let reason = (d["rationale"] as? String).map { AssistantNumbers.checked($0, given: []) }
            if reason?.removed.isEmpty == false { leftOut = true }
            items.append(Distraction(id: d["id"] as? String ?? "d\(i + 1)", label: d["label"] as? String ?? "distraction",
                                     rationale: reason?.text, severity: d["severity"] as? String ?? "medium",
                                     box: (x, y, w, h)))
        }
        // How many were found is Glimmer's own count, so the summary may say it.
        let said = (json["message"] as? String).map { AssistantNumbers.checked($0, given: ["\(items.count) \(raw.count)"]) }
        if said?.removed.isEmpty == false { leftOut = true }
        return (items, AssistantNumbers.noted(said?.text, removed: leftOut))
    }

    public static func findDistractions(_ image: RGBAImage, model: any TextModel)
        async throws -> (items: [Distraction], message: String?, cost: Double?) {
        let png = image.limited(toMaxSide: 1536).pngData()
        let reply = try await model.reply(
            system: distractionSystemPrompt,
            user: "Analyze this image and return the JSON object of distracting elements now.",
            images: [png], imageType: "image/png", json: true, temperature: 0.2)
        let parsed = parseDistractions(reply.text)
        return (parsed.items, parsed.message, reply.cost)
    }
}
