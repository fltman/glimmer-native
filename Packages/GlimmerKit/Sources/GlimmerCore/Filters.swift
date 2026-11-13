import Foundation

/// The destructive pixel filters (Filter menu). Raw values match the web app's
/// filter ids so presets and agent tool calls carry over unchanged.
public enum FilterKind: String, CaseIterable, Codable, Sendable {
    case gaussianBlur = "gaussian_blur"
    case lensBlur = "lens_blur"
    case motionBlur = "motion_blur"
    case sharpen
    case unsharpMask = "unsharp_mask"
    case clarity
    case addNoise = "add_noise"
    case pixelate
    case findEdges = "find_edges"
    case emboss
    case oilPaint = "oil_paint"
    case halftone
    case vignette
    case chromaticAberration = "chromatic_aberration"

    public var title: String {
        switch self {
        case .gaussianBlur: "Gaussian Blur"
        case .lensBlur: "Lens Blur"
        case .motionBlur: "Motion Blur"
        case .sharpen: "Sharpen"
        case .unsharpMask: "Unsharp Mask"
        case .clarity: "Clarity"
        case .addNoise: "Add Noise"
        case .pixelate: "Pixelate"
        case .findEdges: "Find Edges"
        case .emboss: "Emboss"
        case .oilPaint: "Oil Paint"
        case .halftone: "Halftone"
        case .vignette: "Vignette"
        case .chromaticAberration: "Chromatic Aberration"
        }
    }

    /// Filter menu submenu.
    public var group: String {
        switch self {
        case .gaussianBlur, .lensBlur, .motionBlur: "Blur"
        case .sharpen, .unsharpMask, .clarity: "Sharpen"
        case .addNoise: "Noise"
        case .pixelate, .halftone: "Pixelate"
        case .findEdges, .emboss, .oilPaint: "Stylize"
        case .vignette, .chromaticAberration: "Lens"
        }
    }

    public var fields: [FilterField] {
        switch self {
        case .gaussianBlur: [.slider("radius", "Radius", 0...100, 4, unit: "px")]
        case .lensBlur: [.slider("radius", "Radius", 0...60, 8, unit: "px"),
                         .slider("brightnessBoost", "Highlight Bloom", 0...1, 0.3)]
        case .motionBlur: [.slider("angle", "Angle", -180...180, 0, unit: "°"),
                           .slider("distance", "Distance", 0...200, 20, unit: "px")]
        case .sharpen: [.slider("amount", "Amount", 0...5, 1)]
        case .unsharpMask: [.slider("amount", "Amount", 0...5, 0.8),
                            .slider("radius", "Radius", 0.5...10, 2, unit: "px"),
                            .slider("threshold", "Threshold", 0...1, 0)]
        case .clarity: [.slider("amount", "Amount", -1...1, 0.4)]
        case .addNoise: [.slider("amount", "Amount", 0...1, 0.1), .toggle("monochrome", "Monochromatic", false)]
        case .pixelate: [.slider("cell", "Cell Size", 2...200, 10, unit: "px")]
        case .findEdges: []
        case .emboss: [.slider("angle", "Angle", -180...180, 135, unit: "°"), .slider("amount", "Amount", 0...5, 1)]
        case .oilPaint: [.slider("radius", "Radius", 1...10, 4, unit: "px"), .slider("intensity", "Intensity", 0...1, 1)]
        case .halftone: [.slider("cellSize", "Cell Size", 2...40, 8, unit: "px"), .slider("angle", "Angle", 0...90, 45, unit: "°"),
                         .toggle("monochrome", "Monochrome", true)]
        case .vignette: [.slider("amount", "Amount", 0...1, 0.5), .slider("midpoint", "Midpoint", 0...1, 0.5),
                         .slider("roundness", "Roundness", 0...1, 0.5), .slider("feather", "Feather", 0.01...1, 0.5)]
        case .chromaticAberration: [.slider("amount", "Amount", 0...40, 6, unit: "px"),
                                    .toggle("edgeOnly", "Stronger at Edges", true)]
        }
    }
}

public struct FilterField: Sendable, Hashable {
    public let key: String
    public let label: String
    public let range: ClosedRange<Double>
    public let defaultValue: Double
    public let isToggle: Bool
    public let unit: String

    public static func slider(_ key: String, _ label: String, _ range: ClosedRange<Double>, _ d: Double,
                              unit: String = "") -> FilterField {
        FilterField(key: key, label: label, range: range, defaultValue: d, isToggle: false, unit: unit)
    }

    public static func toggle(_ key: String, _ label: String, _ d: Bool) -> FilterField {
        FilterField(key: key, label: label, range: 0...1, defaultValue: d ? 1 : 0, isToggle: true, unit: "")
    }
}

/// A filter with its parameters. Toggles are stored as 0/1 so the web's
/// `{monochrome: 1}` style parameter bags decode directly.
public struct FilterSettings: Codable, Hashable, Sendable {
    public var kind: FilterKind
    public var values: [String: Double]

    public init(_ kind: FilterKind, _ values: [String: Double] = [:]) {
        self.kind = kind
        self.values = values
    }

    /// Parses a web-style id (`"add_noise"`) and parameter bag.
    public init?(id: String, _ values: [String: Double] = [:]) {
        guard let kind = FilterKind(rawValue: id) else { return nil }
        self.init(kind, values)
    }

    public func value(_ key: String) -> Double {
        if let v = values[key] { return v }
        return kind.fields.first { $0.key == key }?.defaultValue ?? 0
    }

    public func flag(_ key: String) -> Bool { value(key) >= 0.5 }

    /// How far (px) the filter reads from neighbouring pixels.
    public var reach: Int {
        let r: Double = switch kind {
        case .gaussianBlur: value("radius") * 1.5
        case .lensBlur: value("radius")
        case .motionBlur: value("distance") / 2
        case .sharpen, .findEdges: 1
        case .unsharpMask: value("radius") * 3
        case .clarity: 80
        case .emboss: 2
        case .oilPaint: value("radius")
        case .chromaticAberration: value("amount")
        case .pixelate: value("cell")
        case .addNoise, .halftone, .vignette: 0
        }
        return Int(r.rounded(.up)) + 1
    }
}
