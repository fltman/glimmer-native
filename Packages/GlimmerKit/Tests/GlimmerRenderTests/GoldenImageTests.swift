import CoreGraphics
import Foundation
import GlimmerCore
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import GlimmerRender

/// Golden-image tests: every blend mode, adjustment, filter and layer effect is
/// rendered on a fixed scene and compared with a checked-in reference in CIELAB.
/// A render passes when the mean ΔE (CIE76) is below 0.5 and 99 % of pixels are
/// below 2.
///
/// References live in `Golden/`. Record new ones with
/// `GLIMMER_RECORD_GOLDEN=1 swift test --filter GoldenImageTests`, look at them,
/// and check them in.
@Suite(.serialized) struct GoldenImageTests {
    static let size = 96
    static let recording = ProcessInfo.processInfo.environment["GLIMMER_RECORD_GOLDEN"] == "1"
    static let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "Golden")

    // MARK: Scene

    /// A hue sweep across, darker towards the bottom, with a grey ramp strip.
    static func baseLayer() throws -> Layer {
        let s = size
        let ctx = CGContext(data: nil, width: s, height: s, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        for x in 0..<s {
            for y in 0..<s {
                let hue = Double(x) / Double(s)
                let value = 1 - Double(y) / Double(s) * 0.7
                let (r, g, b) = hsv(hue, 0.8, value)
                ctx.setFillColor(CGColor(srgbRed: r, green: g, blue: b, alpha: 1))
                ctx.fill(CGRect(x: x, y: s - 1 - y, width: 1, height: 1))
            }
        }
        for x in 0..<s {
            let v = Double(x) / Double(s - 1)
            ctx.setFillColor(CGColor(srgbRed: v, green: v, blue: v, alpha: 1))
            ctx.fill(CGRect(x: x, y: 0, width: 1, height: 12))
        }
        return Layer(name: "Base", content: .raster(try ImageImporter.tiles(from: ctx.makeImage()!)))
    }

    /// A soft-edged orange disc with a cyan square, on transparency.
    static func shapeLayer(blend: BlendMode = .normal) throws -> Layer {
        let s = size
        let ctx = CGContext(data: nil, width: s, height: s, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(srgbRed: 1, green: 0.55, blue: 0.1, alpha: 0.9))
        ctx.fillEllipse(in: CGRect(x: 18, y: 30, width: 50, height: 50))
        ctx.setFillColor(CGColor(srgbRed: 0.1, green: 0.8, blue: 0.9, alpha: 0.7))
        ctx.fill(CGRect(x: 50, y: 20, width: 30, height: 30))
        return Layer(name: "Shapes", blendMode: blend, content: .raster(try ImageImporter.tiles(from: ctx.makeImage()!)))
    }

    static func hsv(_ h: Double, _ s: Double, _ v: Double) -> (Double, Double, Double) {
        let i = Int(h * 6) % 6, f = h * 6 - Double(Int(h * 6))
        let p = v * (1 - s), q = v * (1 - f * s), t = v * (1 - (1 - f) * s)
        switch i {
        case 0: return (v, t, p)
        case 1: return (q, v, p)
        case 2: return (p, v, t)
        case 3: return (p, q, v)
        case 4: return (t, p, v)
        default: return (v, p, q)
        }
    }

    static func state(_ layers: [Layer]) -> DocumentState {
        DocumentState(width: size, height: size, layers: layers)
    }

    /// Hand-picked, clearly visible but unsaturated settings, so every reference
    /// keeps detail a regression would change.
    static let settings: [AdjustmentKind: [String: Double]] = [
        .brightnessContrast: ["brightness": 0.15, "contrast": 0.3],
        .exposure: ["exposure": 0.6, "gamma": 1.2],
        .hueSaturation: ["hue": 60, "saturation": 0.2, "lightness": -0.1],
        .vibrance: ["vibrance": 0.5, "saturation": -0.2],
        .colorBalance: ["midtonesR": 0.4, "shadowsB": 0.3, "highlightsG": -0.2],
        .blackWhite: ["red": 0.9, "blue": -0.2],
        .photoFilter: ["density": 0.5],
        .channelMixer: ["rr": 0.8, "rg": 0.3, "bb": 0.7, "gc": 0.05],
        .posterize: ["levels": 6],
        .threshold: ["level": 0.35],
    ]

    static func adjusted(_ kind: AdjustmentKind) -> Adjustment {
        var a = Adjustment(kind)
        for (key, value) in settings[kind] ?? [:] { a.numbers[key] = value }
        switch kind {
        case .curves: a.curves[.rgb] = [CurvePoint(0, 0.05), CurvePoint(0.3, 0.2), CurvePoint(0.7, 0.85), CurvePoint(1, 1)]
        case .levels: a.levels[.rgb] = LevelsChannel(inBlack: 0.1, inWhite: 0.85, gamma: 1.4)
        default: break
        }
        return a
    }

    // MARK: Comparison

    static func pixels(_ image: CGImage) -> [UInt8] {
        let s = size
        var px = [UInt8](repeating: 0, count: s * s * 4)
        px.withUnsafeMutableBytes { buffer in
            let ctx = CGContext(data: buffer.baseAddress, width: s, height: s, bitsPerComponent: 8, bytesPerRow: s * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: s, height: s))
        }
        return px
    }

    /// sRGB 8-bit → CIELAB (D65).
    static func lab(_ r: UInt8, _ g: UInt8, _ b: UInt8) -> SIMD3<Double> {
        func lin(_ c: UInt8) -> Double {
            let v = Double(c) / 255
            return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        let R = lin(r), G = lin(g), B = lin(b)
        let x = (0.4124 * R + 0.3576 * G + 0.1805 * B) / 0.95047
        let y = 0.2126 * R + 0.7152 * G + 0.0722 * B
        let z = (0.0193 * R + 0.1192 * G + 0.9505 * B) / 1.08883
        func f(_ t: Double) -> Double { t > 0.008856 ? cbrt(t) : 7.787 * t + 16.0 / 116 }
        return SIMD3(116 * f(y) - 16, 500 * (f(x) - f(y)), 200 * (f(y) - f(z)))
    }

    /// Mean and 99th-percentile ΔE76 over pixels that are visible in either image
    /// (colours over a mid-grey matte, so alpha differences count too).
    static func deltaE(_ a: [UInt8], _ b: [UInt8]) -> (mean: Double, p99: Double) {
        var values: [Double] = []
        for i in stride(from: 0, to: a.count, by: 4) where a[i + 3] > 0 || b[i + 3] > 0 {
            func over(_ p: [UInt8], _ c: Int) -> UInt8 {
                UInt8(min(255, Int(p[i + c]) + (255 - Int(p[i + 3])) / 2))  // premultiplied over 50 % grey
            }
            let la = lab(over(a, 0), over(a, 1), over(a, 2)), lb = lab(over(b, 0), over(b, 1), over(b, 2))
            let d = la - lb
            values.append((d * d).sum().squareRoot())
        }
        guard !values.isEmpty else { return (0, 0) }
        values.sort()
        return (values.reduce(0, +) / Double(values.count), values[min(values.count - 1, values.count * 99 / 100)])
    }

    static func writePNG(_ image: CGImage, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let dest = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, image, nil)
        #expect(CGImageDestinationFinalize(dest))
    }

    func check(_ name: String, _ state: DocumentState) throws {
        let image = try ImageExporter.flattenedSRGB(state, context: try context())
        let url = Self.directory.appending(path: "\(name).png")
        let exists = FileManager.default.fileExists(atPath: url.path)
        if Self.recording || !exists {
            try Self.writePNG(image, to: url)
            if !Self.recording { Issue.record("Recorded a missing reference for \(name); check it and commit it.") }
            return
        }
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        let reference = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let (mean, p99) = Self.deltaE(Self.pixels(image), Self.pixels(reference))
        #expect(mean < 0.5 && p99 < 2, "\(name): mean ΔE \(String(format: "%.3f", mean)), p99 \(String(format: "%.3f", p99))")
    }

    // MARK: Cases

    static let blendModes = BlendMode.allCases.filter { $0 != .passThrough }

    @Test(arguments: blendModes)
    func blendMode(_ mode: BlendMode) throws {
        try check("blend-\(mode.rawValue)", Self.state([try Self.baseLayer(), try Self.shapeLayer(blend: mode)]))
    }

    @Test(arguments: AdjustmentKind.allCases)
    func adjustment(_ kind: AdjustmentKind) throws {
        let layer = Layer(name: kind.title, content: .adjustment(Self.adjusted(kind)))
        try check("adjustment-\(kind.rawValue)", Self.state([try Self.baseLayer(), try Self.shapeLayer(), layer]))
    }

    @Test(arguments: FilterKind.allCases)
    func filter(_ kind: FilterKind) throws {
        var base = try Self.baseLayer()
        let frame = PixelRect(x: 0, y: 0, width: Self.size, height: Self.size)
        base.tiles = try FilterEngine(context: try context()).apply(FilterSettings(kind), to: base.tiles, frame: frame, selection: nil)
        try check("filter-\(kind.rawValue)", Self.state([base]))
    }

    @Test(arguments: ["dropShadow", "innerShadow", "outerGlow", "stroke", "colorOverlay"])
    func effect(_ name: String) throws {
        var shapes = try Self.shapeLayer()
        var fx = LayerEffects()
        switch name {
        case "dropShadow": fx.dropShadow = ShadowEffect()
        case "innerShadow": fx.innerShadow = ShadowEffect()
        case "outerGlow": fx.outerGlow = GlowEffect()
        case "stroke": fx.stroke = StrokeEffect()
        default: fx.colorOverlay = ColorOverlayEffect()
        }
        shapes.effects = fx
        try check("effect-\(name)", Self.state([try Self.baseLayer(), shapes]))
    }

    @Test func comparisonCatchesDifferences() {
        let a = [UInt8](repeating: 128, count: 16), b = a.map { $0 &+ 20 }
        #expect(Self.deltaE(a, a).mean == 0)
        #expect(Self.deltaE(a, b).mean > 2)
    }
}
