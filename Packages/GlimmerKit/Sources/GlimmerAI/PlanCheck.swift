import Foundation

/// Whether a request names what a plan would do. A plan made only of the editor's own steps
/// runs at once (Anders's choice: free edits don't wait), but only when every step that
/// changes the document is named by something in the request. "Write a poem about the sea"
/// names no edit: a model that answers it with a text layer gets its plan shown, and it waits
/// for Run. When Glimmer can't tell, it asks. Series rule, 2026-11-16, after Jämmer's
/// assistant planned a change for a request that asked for none.
public enum PlanCheck {
    /// Steps that leave the document's content as it is (selections, the active layer, the colour to paint with).
    static let harmless: Set<String> = ["select_sky", "select_people", "select_subject", "select_all", "deselect", "invert_selection",
                                        "feather_selection", "select_layer", "select_rect", "set_foreground"]

    /// Paid steps wait for Run whatever the request says (`AgentPlan.usesAI`); this check adds nothing for them.
    static let paid: Set<String> = ["generate_layer", "image_edit_composite", "inpaint_selection"]

    /// Word stems, English and Swedish, by which a request names an operation.
    public static let words: [String: [String]] = [
        "auto_enhance": ["enhance", "improve", "fix", "better", "auto", "förbättra", "fixa", "bättre", "snygg"],
        "auto_color": ["color", "colour", "färg", "white balance", "vitbalans", "cast", "stick"],
        "remove_background": ["background", "bakgrund", "cut out", "cutout", "frilägg"],
        "heal_selection": ["heal", "remove", "erase", "retouch", "laga", "ta bort", "retusch"],
        "upscale": ["upscale", "enlarge", "bigger", "larger", "resolution", "förstora", "större", "upplösning"],
        "fill": ["fill", "fyll"],
        "new_layer": ["layer", "lager"],
        "transform_layer": ["rotate", "scale", "move", "flip", "skew", "resize", "size", "bigger", "smaller", "tilt", "turn",
                            "rotera", "skala", "flytta", "vänd", "vrid", "storlek", "större", "mindre", "luta"],
        "style_text": ["bold", "italic", "font", "color", "colour", "size", "underline", "text", "fet", "kursiv", "typsnitt", "färg", "storlek", "understruk"],
        "crop": ["crop", "square", "aspect", "trim", "beskär", "kvadrat", "format"],
        "resize_image": ["resize", "size", "smaller", "bigger", "larger", "half", "double", "pixel", "scale", "width", "height",
                         "storlek", "mindre", "större", "hälften", "dubbel", "skala", "bredd", "höjd"],
        "resize_canvas": ["canvas", "border", "margin", "extend", "pad", "arbetsyta", "duk", "kant", "marginal", "utöka"],
        "set_layer": ["opacity", "transparent", "blend", "hide", "show", "rename", "name", "visible",
                      "opacitet", "genomskinlig", "dölj", "visa", "namn", "bland", "synlig"],
        "add_waveform": ["waveform", "audio", "sound", "vågform", "ljud"],
        "add_layer_effect": ["shadow", "glow", "stroke", "outline", "effect", "bevel", "skugga", "glöd", "kontur", "effekt"],
        "apply_preset": ["preset", "look", "style", "förinställning", "stil"],
    ]

    /// How a request names a kind of adjustment or filter, beyond the kind's own name.
    static let kinds: [String: [String]] = [
        "black_white": ["black and white", "black & white", "black-and-white", "b&w", "monochrome", "grayscale", "greyscale", "svartvit", "svart-vit", "gråskala"],
        "brightness_contrast": ["bright", "dark", "contrast", "light", "ljus", "mörk", "kontrast"],
        "exposure": ["exposure", "bright", "dark", "exponering", "ljus", "mörk"],
        "levels": ["level", "nivå"],
        "curves": ["curve", "kurv"],
        "hue_saturation": ["hue", "saturat", "colorful", "colourful", "color", "colour", "mättnad", "mätta", "nyans", "färg"],
        "vibrance": ["vibran", "saturat", "color", "colour", "pop", "vivid", "färg", "mättnad", "livfull"],
        "color_balance": ["balance", "warm", "cool", "cold", "tint", "varm", "kall", "balans", "ton"],
        "photo_filter": ["warm", "cool", "sepia", "filter", "varm", "kall"],
        "channel_mixer": ["channel", "kanal"],
        "invert": ["invert", "negative", "negativ"],
        "posterize": ["poster"],
        "threshold": ["threshold", "tröskel"],
        "gradient_map": ["gradient", "duotone", "toning"],
        "gaussian_blur": ["blur", "soft", "oskärpa", "suddig", "mjuk"],
        "lens_blur": ["blur", "bokeh", "depth", "background", "oskärpa", "bakgrund", "skärpedjup"],
        "sharpen": ["sharp", "crisp", "skärp"],
        "vignette": ["vignett"],
        "grain": ["grain", "noise", "film", "korn", "brus"],
    ]

    private static func has(_ request: String, anyOf stems: [String]) -> Bool { stems.contains { request.contains($0) } }

    /// Whether `request` names what `step` does. False for anything Glimmer can't tell.
    public static func names(_ request: String, _ step: AgentStep, commandTitle: (String) -> String? = { _ in nil }) -> Bool {
        let request = request.lowercased()
        switch step.op {
        case "add_text":
            // The text to add must be in the request itself ("add the text Hello"): a text the model wrote is not.
            guard let text = step.string("text")?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !text.isEmpty else { return false }
            return request.contains(text)
        case "add_adjustment", "apply_filter":
            guard let kind = step.string("type")?.lowercased(), !kind.isEmpty else { return false }
            if let stems = kinds[kind], has(request, anyOf: stems) { return true }
            // The kind's own name, word for word ("channel mixer", "posterize").
            let own = kind.split(separator: "_").map(String.init).filter { $0.count >= 4 }
            return !own.isEmpty && own.allSatisfy { request.contains($0) }
        case "apply_preset":
            if let name = step.string("name")?.lowercased(), !name.isEmpty, request.contains(name) { return true }
            return has(request, anyOf: words["apply_preset"]!)
        case "crop":
            if let aspect = step.string("aspect"), request.contains(aspect) { return true }
            return has(request, anyOf: words["crop"]!)
        case "run_command":
            guard let id = step.string("id"), let title = commandTitle(id) else { return false }
            return namesCommand(request, title: title, keywords: [])
        default:
            guard let stems = words[step.op] else { return false }
            return has(request, anyOf: stems)
        }
    }

    /// Whether a plan may run without being shown first: every step that changes the document
    /// is named by the request. (A plan with a paid step waits anyway.)
    public static func runsAtOnce(_ plan: AgentPlan, request: String, commandTitle: (String) -> String? = { _ in nil }) -> Bool {
        plan.steps.allSatisfy { harmless.contains($0.op) || paid.contains($0.op) || names(request, $0, commandTitle: commandTitle) }
    }

    /// The steps the request doesn't name, for telling the person why the plan waits.
    public static func unnamed(_ plan: AgentPlan, request: String, commandTitle: (String) -> String? = { _ in nil }) -> [AgentStep] {
        plan.steps.filter { !harmless.contains($0.op) && !paid.contains($0.op) && !names(request, $0, commandTitle: commandTitle) }
    }

    /// Whether a request names a single command (the on-device router's choice): the command's
    /// title, one of its search words, or a word of its title of four letters or more.
    public static func namesCommand(_ request: String, title: String, keywords: [String]) -> Bool {
        let request = request.lowercased()
        let title = title.lowercased()
        if request.contains(title) || keywords.contains(where: { !$0.isEmpty && request.contains($0.lowercased()) }) { return true }
        let titleWords = title.split(whereSeparator: { !$0.isLetter }).map(String.init).filter { $0.count >= 4 }
        return titleWords.contains { request.contains($0) }
    }
}
