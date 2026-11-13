import Foundation

/// One-click looks, ported from the web app (`web/src/ai/presets/presetDefs.ts`).
/// Each becomes a group of adjustment layers; filter steps are applied once
/// filters exist (phase 7) and are skipped until then.
public struct Preset: Identifiable, Sendable {
    public enum Step: Sendable {
        case adjustment(Adjustment)
        case filter(String, [String: Double])
    }

    public let id: String
    public let name: String
    public let description: String
    /// Two sRGB hex swatches for the UI.
    public let swatch: (String, String)
    public let steps: [Step]

    /// The preset as a group of adjustment layers (bottom → top).
    public func makeGroup() -> Layer {
        let children = steps.compactMap { step -> Layer? in
            guard case .adjustment(let adjustment) = step else { return nil }
            return Layer(name: adjustment.kind.title, content: .adjustment(adjustment))
        }
        return Layer(name: name, blendMode: .passThrough, content: .group(LayerGroup(children: children, isExpanded: false)))
    }

    public var filterSteps: [(String, [String: Double])] {
        steps.compactMap { if case .filter(let n, let p) = $0 { (n, p) } else { nil } }
    }
}

/// Web-style parameters (same shapes as `.aips` files) → an adjustment.
private func adj(_ kind: AdjustmentKind, _ params: [String: Any] = [:]) -> Preset.Step {
    .adjustment(AipsImporter.adjustment(kind, params))
}
private func filt(_ name: String, _ params: [String: Double] = [:]) -> Preset.Step { .filter(name, params) }
private func pts(_ p: [(Double, Double)]) -> [[String: Double]] { p.map { ["x": $0.0, "y": $0.1] } }
private func rgba(_ r: Double, _ g: Double, _ b: Double) -> [String: Double] { ["r": r, "g": g, "b": b, "a": 1] }

extension Preset {
    public static let all: [Preset] = [
        Preset(id: "teal_orange", name: "Cinematic Teal & Orange",
               description: "Hollywood blockbuster split-tone: warm skin, teal shadows.", swatch: ("#0e4d5c", "#e8954b"),
               steps: [
                adj(.curves, ["rgb": pts([(0, 0.02), (0.25, 0.2), (0.75, 0.82), (1, 0.98)])]),
                adj(.colorBalance, ["shadows": [-0.18, 0.02, 0.24], "midtones": [0.04, 0.0, -0.04],
                                    "highlights": [0.2, 0.06, -0.22], "preserveLuminosity": true]),
                adj(.vibrance, ["vibrance": 0.22, "saturation": 0.05]),
                filt("clarity", ["amount": 0.25]),
               ]),
        Preset(id: "vintage_film", name: "Vintage Film",
               description: "Faded 70s stock: lifted blacks, warm cast, fine grain.", swatch: ("#6b5b3e", "#d8c9a3"),
               steps: [
                adj(.levels, ["inBlack": 0, "inWhite": 1, "gamma": 1.05, "outBlack": 0.08, "outWhite": 0.94]),
                adj(.photoFilter, ["color": rgba(0.85, 0.55, 0.22), "density": 0.3, "preserveLuminosity": true]),
                adj(.hueSaturation, ["hue": 0, "saturation": -0.18, "lightness": 0.02]),
                adj(.curves, ["r": pts([(0, 0.06), (1, 0.96)]), "b": pts([(0, 0.04), (1, 0.9)])]),
                filt("add_noise", ["amount": 0.07, "monochrome": 1]),
               ]),
        Preset(id: "bw_noir", name: "B&W Noir",
               description: "High-contrast black & white with deep shadows and grain.", swatch: ("#0a0a0a", "#e6e6e6"),
               steps: [
                adj(.blackWhite, ["red": 0.6, "yellow": 0.85, "green": 0.4, "cyan": 0.3, "blue": 0.15, "magenta": 0.7]),
                adj(.curves, ["rgb": pts([(0, 0), (0.22, 0.1), (0.78, 0.92), (1, 1)])]),
                filt("vignette", ["amount": 0.55, "midpoint": 0.4, "roundness": 0.4, "feather": 0.5]),
                filt("add_noise", ["amount": 0.1, "monochrome": 1]),
               ]),
        Preset(id: "hdr_pop", name: "HDR Pop",
               description: "Punchy detail and saturation — clarity-driven, modern look.", swatch: ("#1a6fb0", "#f2c94c"),
               steps: [
                filt("clarity", ["amount": 0.7]),
                filt("sharpen", ["amount": 0.6]),
                adj(.curves, ["rgb": pts([(0, 0.04), (0.35, 0.42), (0.7, 0.74), (1, 0.99)])]),
                adj(.vibrance, ["vibrance": 0.4, "saturation": 0.12]),
               ]),
        Preset(id: "golden_hour", name: "Golden Hour",
               description: "Warm, glowing sunset light with soft, lifted shadows.", swatch: ("#c8722a", "#ffe2a8"),
               steps: [
                adj(.photoFilter, ["color": rgba(0.98, 0.66, 0.25), "density": 0.35, "preserveLuminosity": true]),
                adj(.colorBalance, ["shadows": [0.05, 0.0, -0.04], "midtones": [0.08, 0.02, -0.08],
                                    "highlights": [0.16, 0.06, -0.16], "preserveLuminosity": true]),
                adj(.levels, ["inBlack": 0, "inWhite": 1, "gamma": 1.08, "outBlack": 0.06, "outWhite": 1]),
                adj(.vibrance, ["vibrance": 0.2, "saturation": 0.04]),
               ]),
        Preset(id: "cyberpunk", name: "Cool Cyberpunk",
               description: "Neon night city: magenta highlights, electric-blue shadows.", swatch: ("#1b1040", "#ff2e9a"),
               steps: [
                adj(.colorBalance, ["shadows": [-0.1, -0.06, 0.3], "midtones": [0.06, -0.08, 0.12],
                                    "highlights": [0.24, -0.05, 0.1], "preserveLuminosity": true]),
                adj(.curves, ["r": pts([(0, 0), (0.7, 0.78), (1, 1)]), "b": pts([(0, 0.12), (0.5, 0.58), (1, 1)])]),
                adj(.hueSaturation, ["hue": 0, "saturation": 0.3, "lightness": -0.02]),
                filt("chromatic_aberration", ["amount": 4, "edgeOnly": 1]),
                filt("vignette", ["amount": 0.4, "midpoint": 0.45, "roundness": 0.6, "feather": 0.6]),
               ]),
        Preset(id: "matte_fade", name: "Matte Fade",
               description: "Modern Instagram matte: flattened blacks, muted color.", swatch: ("#4a4f57", "#cdbfb2"),
               steps: [
                adj(.levels, ["inBlack": 0, "inWhite": 0.96, "gamma": 1.0, "outBlack": 0.12, "outWhite": 0.95]),
                adj(.curves, ["rgb": pts([(0, 0.12), (0.5, 0.5), (1, 0.94)])]),
                adj(.vibrance, ["vibrance": -0.12, "saturation": -0.16]),
                adj(.colorBalance, ["shadows": [-0.04, 0.0, 0.08], "midtones": [0, 0, 0],
                                    "highlights": [0.04, 0.02, -0.04], "preserveLuminosity": true]),
               ]),
        Preset(id: "bleach_bypass", name: "Bleach Bypass",
               description: "Desaturated, high-contrast silver-retention war-film look.", swatch: ("#2b2b2b", "#bfc4c0"),
               steps: [
                adj(.hueSaturation, ["hue": 0, "saturation": -0.55, "lightness": 0]),
                adj(.curves, ["rgb": pts([(0, 0), (0.25, 0.14), (0.75, 0.9), (1, 1)])]),
                adj(.colorBalance, ["shadows": [-0.04, 0.04, 0.0], "midtones": [0.0, 0.06, -0.02],
                                    "highlights": [0.02, 0.04, -0.04], "preserveLuminosity": true]),
                filt("clarity", ["amount": 0.45]),
                filt("add_noise", ["amount": 0.05, "monochrome": 1]),
               ]),
        Preset(id: "cross_process", name: "Cross Process",
               description: "C-41-in-E6 colour shift: green shadows, yellow highlights.", swatch: ("#3c5a2e", "#e8d24a"),
               steps: [
                adj(.curves, ["r": pts([(0, 0), (0.5, 0.58), (1, 0.95)]), "g": pts([(0, 0.06), (0.5, 0.5), (1, 1)]),
                              "b": pts([(0, 0.14), (0.5, 0.42), (1, 0.85)])]),
                adj(.colorBalance, ["shadows": [-0.12, 0.16, -0.06], "midtones": [0.04, 0.06, -0.1],
                                    "highlights": [0.06, 0.04, -0.18], "preserveLuminosity": false]),
                adj(.hueSaturation, ["hue": 0, "saturation": 0.28, "lightness": 0]),
               ]),
        Preset(id: "dreamy_soft", name: "Dreamy Soft",
               description: "Hazy pastel glow — soft contrast, airy highlights, fine bloom.", swatch: ("#d8a7c4", "#fbe9d0"),
               steps: [
                adj(.levels, ["inBlack": 0, "inWhite": 1, "gamma": 1.12, "outBlack": 0.1, "outWhite": 1]),
                adj(.vibrance, ["vibrance": -0.06, "saturation": -0.1]),
                adj(.photoFilter, ["color": rgba(0.95, 0.7, 0.78), "density": 0.18, "preserveLuminosity": true]),
                adj(.gradientMap, ["stops": [
                    ["pos": 0.0, "color": rgba(0.22, 0.12, 0.26)] as [String: Any],
                    ["pos": 0.5, "color": rgba(0.78, 0.6, 0.62)],
                    ["pos": 1.0, "color": rgba(0.99, 0.94, 0.86)],
                ]]),
                filt("lens_blur", ["radius": 3, "brightnessBoost": 0.6]),
               ]),
    ]
}
