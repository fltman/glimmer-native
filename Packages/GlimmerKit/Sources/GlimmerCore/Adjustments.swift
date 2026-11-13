import Foundation

/// Straight (non-premultiplied) sRGB colour, components 0...1.
public struct SRGBColor: Codable, Hashable, Sendable {
    public var r: Double
    public var g: Double
    public var b: Double

    public init(_ r: Double, _ g: Double, _ b: Double) {
        self.r = r
        self.g = g
        self.b = b
    }

    public static let black = SRGBColor(0, 0, 0)
    public static let white = SRGBColor(1, 1, 1)

    /// Linear-light components.
    public var linear: SIMD3<Float> {
        func lin(_ c: Double) -> Float {
            Float(c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4))
        }
        return SIMD3(lin(r), lin(g), lin(b))
    }

    public var srgb: SIMD3<Float> { SIMD3(Float(r), Float(g), Float(b)) }
}

public struct CurvePoint: Codable, Hashable, Sendable {
    public var x: Double
    public var y: Double

    public init(_ x: Double, _ y: Double) {
        self.x = x
        self.y = y
    }
}

/// Monotone cubic (Fritsch–Carlson) curve through sorted control points.
public enum CurveMath {
    public static let identity = [CurvePoint(0, 0), CurvePoint(1, 1)]

    public static func evaluate(_ points: [CurvePoint], at t: Double) -> Double {
        let pts = points.sorted { $0.x < $1.x }
        guard let first = pts.first, let last = pts.last else { return t }
        if pts.count == 1 { return clamp(first.y) }
        if t <= first.x { return clamp(first.y) }
        if t >= last.x { return clamp(last.y) }

        let n = pts.count
        var delta = [Double](repeating: 0, count: n - 1)
        for i in 0..<(n - 1) {
            let dx = pts[i + 1].x - pts[i].x
            delta[i] = dx > 1e-9 ? (pts[i + 1].y - pts[i].y) / dx : 0
        }
        var m = [Double](repeating: 0, count: n)
        m[0] = delta[0]
        m[n - 1] = delta[n - 2]
        for i in 1..<(n - 1) {
            m[i] = delta[i - 1] * delta[i] <= 0 ? 0 : (delta[i - 1] + delta[i]) / 2
        }
        for i in 0..<(n - 1) where delta[i] == 0 {
            m[i] = 0
            m[i + 1] = 0
        }
        for i in 0..<(n - 1) where delta[i] != 0 {
            let a = m[i] / delta[i], b = m[i + 1] / delta[i]
            let s = a * a + b * b
            if s > 9 {
                let tau = 3 / s.squareRoot()
                m[i] = tau * a * delta[i]
                m[i + 1] = tau * b * delta[i]
            }
        }

        var k = 0
        while k < n - 2, t > pts[k + 1].x { k += 1 }
        let h = pts[k + 1].x - pts[k].x
        guard h > 1e-9 else { return clamp(pts[k].y) }
        let u = (t - pts[k].x) / h
        let u2 = u * u, u3 = u2 * u
        let y = (2 * u3 - 3 * u2 + 1) * pts[k].y + (u3 - 2 * u2 + u) * h * m[k]
            + (-2 * u3 + 3 * u2) * pts[k + 1].y + (u3 - u2) * h * m[k + 1]
        return clamp(y)
    }

    static func clamp(_ v: Double) -> Double { min(max(v, 0), 1) }
}

public struct LevelsChannel: Codable, Hashable, Sendable {
    public var inBlack: Double = 0
    public var inWhite: Double = 1
    public var gamma: Double = 1
    public var outBlack: Double = 0
    public var outWhite: Double = 1

    public init(inBlack: Double = 0, inWhite: Double = 1, gamma: Double = 1, outBlack: Double = 0, outWhite: Double = 1) {
        self.inBlack = inBlack
        self.inWhite = inWhite
        self.gamma = gamma
        self.outBlack = outBlack
        self.outWhite = outWhite
    }

    public static let identity = LevelsChannel()

    public func apply(_ t: Double) -> Double {
        let span = max(1e-4, inWhite - inBlack)
        var v = min(max((t - inBlack) / span, 0), 1)
        v = pow(v, 1 / max(0.01, gamma))
        return min(max(outBlack + v * (outWhite - outBlack), 0), 1)
    }
}

public struct GradientStop: Codable, Hashable, Sendable {
    public var position: Double
    public var color: SRGBColor
    public var opacity: Double

    public init(_ position: Double, _ color: SRGBColor, opacity: Double = 1) {
        self.position = position
        self.color = color
        self.opacity = opacity
    }

    public static let blackToWhite = [GradientStop(0, .black), GradientStop(1, .white)]

    /// Straight sRGB colour and opacity at `t` (linear interpolation in sRGB, like Photoshop).
    public static func sample(_ stops: [GradientStop], at t: Double) -> (SRGBColor, Double) {
        let s = stops.sorted { $0.position < $1.position }
        guard let first = s.first, let last = s.last else { return (.black, 1) }
        if t <= first.position { return (first.color, first.opacity) }
        if t >= last.position { return (last.color, last.opacity) }
        for i in 0..<(s.count - 1) where t <= s[i + 1].position {
            let a = s[i], b = s[i + 1]
            let f = (t - a.position) / max(1e-9, b.position - a.position)
            let c = SRGBColor(a.color.r + (b.color.r - a.color.r) * f,
                             a.color.g + (b.color.g - a.color.g) * f,
                             a.color.b + (b.color.b - a.color.b) * f)
            return (c, a.opacity + (b.opacity - a.opacity) * f)
        }
        return (last.color, last.opacity)
    }
}

/// The 14 adjustment layer types. Raw values match Glimmer for the web.
public enum AdjustmentKind: String, Codable, CaseIterable, Sendable {
    case brightnessContrast = "brightness_contrast"
    case levels
    case curves
    case exposure
    case hueSaturation = "hue_saturation"
    case vibrance
    case colorBalance = "color_balance"
    case blackWhite = "black_white"
    case photoFilter = "photo_filter"
    case channelMixer = "channel_mixer"
    case invert
    case posterize
    case threshold
    case gradientMap = "gradient_map"

    public var title: String {
        switch self {
        case .brightnessContrast: "Brightness/Contrast"
        case .levels: "Levels"
        case .curves: "Curves"
        case .exposure: "Exposure"
        case .hueSaturation: "Hue/Saturation"
        case .vibrance: "Vibrance"
        case .colorBalance: "Color Balance"
        case .blackWhite: "Black & White"
        case .photoFilter: "Photo Filter"
        case .channelMixer: "Channel Mixer"
        case .invert: "Invert"
        case .posterize: "Posterize"
        case .threshold: "Threshold"
        case .gradientMap: "Gradient Map"
        }
    }

    public var symbolName: String {
        switch self {
        case .brightnessContrast: "sun.max"
        case .levels: "chart.bar"
        case .curves: "point.topleft.down.to.point.bottomright.curvepath"
        case .exposure: "plusminus.circle"
        case .hueSaturation: "paintpalette"
        case .vibrance: "drop.triangle"
        case .colorBalance: "scalemass"
        case .blackWhite: "circle.lefthalf.filled"
        case .photoFilter: "camera.filters"
        case .channelMixer: "slider.horizontal.3"
        case .invert: "circle.righthalf.filled.inverse"
        case .posterize: "square.stack.3d.down.right"
        case .threshold: "circle.and.line.horizontal"
        case .gradientMap: "rectangle.righthalf.inset.filled"
        }
    }

    /// Order the shader's `adjustColor` switch uses. Must match Adjust.metal.
    public var shaderIndex: Int32 {
        Int32(Self.allCases.firstIndex(of: self)!)
    }

    /// Whether the effect is computed through a lookup table.
    public var usesLUT: Bool { self == .levels || self == .curves || self == .gradientMap }

    public var sliders: [AdjustmentSlider] {
        switch self {
        case .brightnessContrast:
            [.init("brightness", "Brightness", -1...1), .init("contrast", "Contrast", -1...1)]
        case .exposure:
            [.init("exposure", "Exposure", -5...5), .init("offset", "Offset", -0.5...0.5),
             .init("gamma", "Gamma Correction", 0.1...3, default: 1)]
        case .hueSaturation:
            [.init("hue", "Hue", -180...180, step: 1), .init("saturation", "Saturation", -1...1),
             .init("lightness", "Lightness", -1...1)]
        case .vibrance:
            [.init("vibrance", "Vibrance", -1...1), .init("saturation", "Saturation", -1...1)]
        case .colorBalance:
            ["shadows", "midtones", "highlights"].flatMap { tone in
                [("R", "Cyan – Red"), ("G", "Magenta – Green"), ("B", "Yellow – Blue")].map {
                    AdjustmentSlider("\(tone)\($0.0)", "\(tone.capitalized): \($0.1)", -1...1)
                }
            }
        case .blackWhite:
            [.init("red", "Reds", -2...3, default: 0.4), .init("yellow", "Yellows", -2...3, default: 0.6),
             .init("green", "Greens", -2...3, default: 0.4), .init("cyan", "Cyans", -2...3, default: 0.6),
             .init("blue", "Blues", -2...3, default: 0.2), .init("magenta", "Magentas", -2...3, default: 0.8)]
        case .photoFilter:
            [.init("density", "Density", 0...1, default: 0.25)]
        case .channelMixer:
            ["r", "g", "b"].flatMap { out in
                [("r", "Red"), ("g", "Green"), ("b", "Blue"), ("c", "Constant")].map {
                    AdjustmentSlider("\(out)\($0.0)", "\(out.uppercased()) ← \($0.1)", -2...2,
                                     default: out == $0.0 ? 1 : 0)
                }
            }
        case .posterize:
            [.init("levels", "Levels", 2...255, default: 4, step: 1)]
        case .threshold:
            [.init("level", "Threshold Level", 0...1, default: 0.5)]
        case .levels, .curves, .invert, .gradientMap:
            []
        }
    }

    public var toggles: [AdjustmentToggle] {
        switch self {
        case .colorBalance, .photoFilter: [.init("preserveLuminosity", "Preserve Luminosity", default: true)]
        case .channelMixer: [.init("monochrome", "Monochrome", default: false)]
        default: []
        }
    }

    public var colors: [AdjustmentColor] {
        switch self {
        case .photoFilter: [.init("color", "Filter Color", default: SRGBColor(0.92, 0.6, 0.2))]
        default: []
        }
    }
}

public struct AdjustmentSlider: Sendable, Hashable {
    public var key: String
    public var label: String
    public var range: ClosedRange<Double>
    public var defaultValue: Double
    public var step: Double

    public init(_ key: String, _ label: String, _ range: ClosedRange<Double>, default value: Double = 0, step: Double = 0.01) {
        self.key = key
        self.label = label
        self.range = range
        self.defaultValue = value
        self.step = step
    }
}

public struct AdjustmentToggle: Sendable, Hashable {
    public var key: String
    public var label: String
    public var defaultValue: Bool

    public init(_ key: String, _ label: String, default value: Bool) {
        self.key = key
        self.label = label
        self.defaultValue = value
    }
}

public struct AdjustmentColor: Sendable, Hashable {
    public var key: String
    public var label: String
    public var defaultValue: SRGBColor

    public init(_ key: String, _ label: String, default value: SRGBColor) {
        self.key = key
        self.label = label
        self.defaultValue = value
    }
}

public enum CurveChannel: String, Codable, CaseIterable, Sendable {
    case rgb, red, green, blue

    public var title: String {
        switch self {
        case .rgb: "RGB"
        case .red: "Red"
        case .green: "Green"
        case .blue: "Blue"
        }
    }
}

/// An adjustment's parameters. Values missing from the bags fall back to the
/// kind's schema defaults, so decoding is lenient.
public struct Adjustment: Codable, Hashable, Sendable {
    public var kind: AdjustmentKind
    public var numbers: [String: Double]
    public var flags: [String: Bool]
    public var colors: [String: SRGBColor]
    /// Curves: per channel.
    public var curves: [CurveChannel: [CurvePoint]]
    /// Levels: per channel.
    public var levels: [CurveChannel: LevelsChannel]
    /// Gradient Map.
    public var gradient: [GradientStop]

    public init(_ kind: AdjustmentKind) {
        self.kind = kind
        self.numbers = [:]
        self.flags = [:]
        self.colors = [:]
        self.curves = [:]
        self.levels = [:]
        self.gradient = GradientStop.blackToWhite
    }

    enum CodingKeys: String, CodingKey { case kind, numbers, flags, colors, curves, levels, gradient }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = try c.decode(AdjustmentKind.self, forKey: .kind)
        numbers = try c.decodeIfPresent([String: Double].self, forKey: .numbers) ?? [:]
        flags = try c.decodeIfPresent([String: Bool].self, forKey: .flags) ?? [:]
        colors = try c.decodeIfPresent([String: SRGBColor].self, forKey: .colors) ?? [:]
        curves = try c.decodeIfPresent([CurveChannel: [CurvePoint]].self, forKey: .curves) ?? [:]
        levels = try c.decodeIfPresent([CurveChannel: LevelsChannel].self, forKey: .levels) ?? [:]
        gradient = try c.decodeIfPresent([GradientStop].self, forKey: .gradient) ?? GradientStop.blackToWhite
    }

    public func number(_ key: String) -> Double {
        numbers[key] ?? kind.sliders.first { $0.key == key }?.defaultValue ?? 0
    }

    public func flag(_ key: String) -> Bool {
        flags[key] ?? kind.toggles.first { $0.key == key }?.defaultValue ?? false
    }

    public func color(_ key: String) -> SRGBColor {
        colors[key] ?? kind.colors.first { $0.key == key }?.defaultValue ?? .white
    }

    public func curve(_ channel: CurveChannel) -> [CurvePoint] {
        curves[channel] ?? CurveMath.identity
    }

    public func levelsChannel(_ channel: CurveChannel) -> LevelsChannel {
        levels[channel] ?? .identity
    }

    /// A per-channel lookup table (sRGB-encoded in and out) for LUT-based kinds:
    /// `size` entries of (r, g, b, a).
    public func lookupTable(size: Int = 1024) -> [SIMD4<Float>] {
        (0..<size).map { i in
            let t = Double(i) / Double(size - 1)
            switch kind {
            case .curves:
                let m = curve(.rgb)
                return SIMD4(Float(CurveMath.evaluate(m, at: CurveMath.evaluate(curve(.red), at: t))),
                             Float(CurveMath.evaluate(m, at: CurveMath.evaluate(curve(.green), at: t))),
                             Float(CurveMath.evaluate(m, at: CurveMath.evaluate(curve(.blue), at: t))), 1)
            case .levels:
                let m = levelsChannel(.rgb)
                return SIMD4(Float(m.apply(levelsChannel(.red).apply(t))),
                             Float(m.apply(levelsChannel(.green).apply(t))),
                             Float(m.apply(levelsChannel(.blue).apply(t))), 1)
            case .gradientMap:
                let (c, o) = GradientStop.sample(gradient, at: t)
                return SIMD4(Float(c.r), Float(c.g), Float(c.b), Float(o))
            default:
                return SIMD4(Float(t), Float(t), Float(t), 1)
            }
        }
    }

    /// Scalar parameters packed for the shader (see Adjust.metal for layouts).
    public var shaderParameters: [Float] {
        func n(_ k: String) -> Float { Float(number(k)) }
        func f(_ k: String) -> Float { flag(k) ? 1 : 0 }
        switch kind {
        case .brightnessContrast: return [n("brightness"), n("contrast")]
        case .exposure: return [n("exposure"), n("offset"), n("gamma")]
        case .hueSaturation: return [n("hue") * .pi / 180, n("saturation"), n("lightness")]
        case .vibrance: return [n("vibrance"), n("saturation")]
        case .colorBalance:
            return ["shadows", "midtones", "highlights"].flatMap { t in ["R", "G", "B"].map { n(t + $0) } }
                + [f("preserveLuminosity")]
        case .blackWhite: return ["red", "yellow", "green", "cyan", "blue", "magenta"].map(n)
        case .photoFilter:
            let c = color("color")
            return [Float(c.r), Float(c.g), Float(c.b), n("density"), f("preserveLuminosity")]
        case .channelMixer:
            return ["rr", "rg", "rb", "rc", "gr", "gg", "gb", "gc", "br", "bg", "bb", "bc"].map(n) + [f("monochrome")]
        case .posterize: return [n("levels").rounded()]
        case .threshold: return [n("level")]
        case .levels, .curves, .invert, .gradientMap: return []
        }
    }
}
