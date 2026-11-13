import Foundation
import simd

// MARK: Masks

/// A non-destructive layer mask in document coordinates. Stored tiles hold the
/// mask value in every channel; missing tiles use `defaultValue`.
public struct LayerMask: Sendable {
    public var tiles: TileGrid
    /// 1 = reveal (white), 0 = hide (black), used where no tile is stored.
    public var defaultValue: Float
    public var isEnabled: Bool
    /// 0...1. At 0 the mask has no effect.
    public var density: Double
    /// Gaussian feather radius in pixels (non-destructive).
    public var feather: Double

    public init(tiles: TileGrid = TileGrid(), defaultValue: Float = 1, isEnabled: Bool = true,
                density: Double = 1, feather: Double = 0) {
        self.tiles = tiles
        self.defaultValue = defaultValue
        self.isEnabled = isEnabled
        self.density = density
        self.feather = feather
    }

    public static let revealAll = LayerMask(defaultValue: 1)
    public static let hideAll = LayerMask(defaultValue: 0)

    /// The mask tile at `coord`, synthesizing a solid tile for the default.
    public func tile(at coord: TileCoord) -> Tile {
        tiles[coord] ?? .solid(SIMD4(repeating: defaultValue))
    }
}

// MARK: Layer styles

public struct ShadowEffect: Codable, Hashable, Sendable {
    public var isEnabled = true
    public var color = SRGBColor.black
    public var opacity = 0.75
    /// Light angle in degrees (0 = from the right, counter-clockwise positive).
    public var angle = 120.0
    public var distance = 10.0
    public var size = 10.0
    /// 0...1, thickens the shape before blurring.
    public var spread = 0.0
    public var blendMode = BlendMode.multiply

    public init() {}

    /// Offset in document pixels (y down), opposite the light.
    public var offset: SIMD2<Double> {
        let r = angle * .pi / 180
        return SIMD2(-cos(r) * distance, sin(r) * distance)
    }
}

public struct GlowEffect: Codable, Hashable, Sendable {
    public var isEnabled = true
    public var color = SRGBColor(1, 1, 0.75)
    public var opacity = 0.75
    public var size = 10.0
    public var spread = 0.0
    public var blendMode = BlendMode.screen

    public init() {}
}

public struct StrokeEffect: Codable, Hashable, Sendable {
    public enum Position: String, Codable, CaseIterable, Sendable { case outside, inside, center }

    public var isEnabled = true
    public var color = SRGBColor(1, 0, 0)
    public var opacity = 1.0
    public var width = 3.0
    public var position = Position.outside
    public var blendMode = BlendMode.normal

    public init() {}
}

public struct ColorOverlayEffect: Codable, Hashable, Sendable {
    public var isEnabled = true
    public var color = SRGBColor(1, 0, 0)
    public var opacity = 1.0
    public var blendMode = BlendMode.normal

    public init() {}
}

public struct LayerEffects: Codable, Hashable, Sendable {
    public var dropShadow: ShadowEffect?
    public var innerShadow: ShadowEffect?
    public var outerGlow: GlowEffect?
    public var stroke: StrokeEffect?
    public var colorOverlay: ColorOverlayEffect?

    public init() {}

    public var hasEnabled: Bool {
        dropShadow?.isEnabled == true || innerShadow?.isEnabled == true || outerGlow?.isEnabled == true
            || stroke?.isEnabled == true || colorOverlay?.isEnabled == true
    }

    /// Effects that need neighbourhood processing (everything but colour overlay).
    public var hasSpatialEffects: Bool {
        dropShadow?.isEnabled == true || innerShadow?.isEnabled == true
            || outerGlow?.isEnabled == true || stroke?.isEnabled == true
    }

    /// The largest distance an effect reaches beyond the layer's pixels.
    public var reach: Int {
        var r = 0.0
        if let s = dropShadow, s.isEnabled { r = max(r, s.distance + s.size * 1.5) }
        if let s = innerShadow, s.isEnabled { r = max(r, s.distance + s.size * 1.5) }
        if let g = outerGlow, g.isEnabled { r = max(r, g.size * 1.5) }
        if let s = stroke, s.isEnabled { r = max(r, s.width) }
        return Int(r.rounded(.up)) + 2
    }
}

// MARK: Fill layers

public enum PatternKind: String, Codable, CaseIterable, Sendable {
    case checkerboard, dots, stripes, grid, noise

    public var title: String { rawValue.capitalized }
    public var shaderIndex: Int32 { Int32(Self.allCases.firstIndex(of: self)!) }
}

public enum GradientStyle: String, Codable, CaseIterable, Sendable {
    case linear, radial
    public var title: String { rawValue.capitalized }
}

public struct GradientFill: Codable, Hashable, Sendable {
    public var stops: [GradientStop]
    public var style: GradientStyle
    /// Document pixels.
    public var start: SIMD2<Double>
    public var end: SIMD2<Double>
    public var reverse: Bool

    public init(stops: [GradientStop] = GradientStop.blackToWhite, style: GradientStyle = .linear,
                start: SIMD2<Double>, end: SIMD2<Double>, reverse: Bool = false) {
        self.stops = stops
        self.style = style
        self.start = start
        self.end = end
        self.reverse = reverse
    }
}

public struct PatternFill: Codable, Hashable, Sendable {
    public var kind: PatternKind
    /// Cell size in document pixels.
    public var scale: Double
    public var foreground: SRGBColor
    public var background: SRGBColor

    public init(kind: PatternKind = .checkerboard, scale: Double = 32,
                foreground: SRGBColor = SRGBColor(0.2, 0.2, 0.2), background: SRGBColor = .white) {
        self.kind = kind
        self.scale = scale
        self.foreground = foreground
        self.background = background
    }
}

public enum Fill: Codable, Hashable, Sendable {
    case solid(SRGBColor)
    case gradient(GradientFill)
    case pattern(PatternFill)

    public var title: String {
        switch self {
        case .solid: "Color Fill"
        case .gradient: "Gradient Fill"
        case .pattern: "Pattern Fill"
        }
    }
}

// MARK: Smart objects

/// Affine map from smart-object source pixels to document pixels:
/// `doc = [a c; b d] · src + (tx, ty)`.
/// A 2D transform: affine, plus an optional projective row (`g`, `h`) for
/// perspective/distort. With g = h = 0 it's an ordinary affine transform.
/// Matrix (column vectors): x' = (a·x + c·y + tx) / w, y' = (b·x + d·y + ty) / w, w = g·x + h·y + 1.
public struct AffineTransform: Codable, Hashable, Sendable {
    public var a: Double, b: Double, c: Double, d: Double, tx: Double, ty: Double
    public var g: Double, h: Double

    public init(a: Double = 1, b: Double = 0, c: Double = 0, d: Double = 1, tx: Double = 0, ty: Double = 0,
                g: Double = 0, h: Double = 0) {
        self.a = a; self.b = b; self.c = c; self.d = d; self.tx = tx; self.ty = ty; self.g = g; self.h = h
    }

    enum CodingKeys: String, CodingKey { case a, b, c, d, tx, ty, g, h }

    public init(from decoder: Decoder) throws {
        let k = try decoder.container(keyedBy: CodingKeys.self)
        a = try k.decode(Double.self, forKey: .a); b = try k.decode(Double.self, forKey: .b)
        c = try k.decode(Double.self, forKey: .c); d = try k.decode(Double.self, forKey: .d)
        tx = try k.decode(Double.self, forKey: .tx); ty = try k.decode(Double.self, forKey: .ty)
        g = try k.decodeIfPresent(Double.self, forKey: .g) ?? 0
        h = try k.decodeIfPresent(Double.self, forKey: .h) ?? 0
    }

    public func encode(to encoder: Encoder) throws {
        var k = encoder.container(keyedBy: CodingKeys.self)
        try k.encode(a, forKey: .a); try k.encode(b, forKey: .b); try k.encode(c, forKey: .c)
        try k.encode(d, forKey: .d); try k.encode(tx, forKey: .tx); try k.encode(ty, forKey: .ty)
        if !isAffine {
            try k.encode(g, forKey: .g); try k.encode(h, forKey: .h)
        }
    }

    public var isAffine: Bool { abs(g) < 1e-15 && abs(h) < 1e-15 }

    /// The projective transform taking the source rectangle (0,0)–size to the
    /// quadrilateral `corners` (top-left, top-right, bottom-right, bottom-left).
    public static func quad(sourceSize size: SIMD2<Double>, to corners: [SIMD2<Double>]) -> AffineTransform {
        precondition(corners.count == 4)
        let (p0, p1, p2, p3) = (corners[0], corners[1], corners[2], corners[3])
        // Unit square → quad (Heckbert).
        let s = p0 - p1 + p2 - p3
        let d1 = p1 - p2, d2 = p3 - p2
        var g = 0.0, h = 0.0
        let den = d1.x * d2.y - d2.x * d1.y
        if abs(s.x) > 1e-12 || abs(s.y) > 1e-12, abs(den) > 1e-12 {
            g = (s.x * d2.y - d2.x * s.y) / den
            h = (d1.x * s.y - s.x * d1.y) / den
        }
        let a = p1.x - p0.x + g * p1.x, b = p1.y - p0.y + g * p1.y
        let c = p3.x - p0.x + h * p3.x, d = p3.y - p0.y + h * p3.y
        // Pre-scale the unit square to the source size.
        let sx = 1 / max(size.x, 1e-12), sy = 1 / max(size.y, 1e-12)
        return AffineTransform(a: a * sx, b: b * sx, c: c * sy, d: d * sy, tx: p0.x, ty: p0.y, g: g * sx, h: h * sy)
    }

    public static let identity = AffineTransform()

    /// Scale, then rotate (radians, clockwise on screen) about the scaled box
    /// centre, with the unrotated box's top-left at (x, y). Matches the web app's
    /// `SmartTransform {tx, ty, sx, sy, rot}`.
    public static func make(x: Double, y: Double, scaleX: Double, scaleY: Double, rotation: Double,
                            sourceSize: SIMD2<Double>) -> AffineTransform {
        let cr = cos(rotation), sr = sin(rotation)
        let hw = sourceSize.x * scaleX / 2, hh = sourceSize.y * scaleY / 2
        // doc = centre + R · (S · src - halfSize)
        let cx = x + hw, cy = y + hh
        let a = cr * scaleX, b = sr * scaleX, c = -sr * scaleY, d = cr * scaleY
        let tx = cx - (cr * hw - sr * hh)
        let ty = cy - (sr * hw + cr * hh)
        return AffineTransform(a: a, b: b, c: c, d: d, tx: tx, ty: ty)
    }

    /// Inverse of `make`: the box position, scales and rotation for `sourceSize`.
    public func decompose(sourceSize: SIMD2<Double>) -> (x: Double, y: Double, scaleX: Double, scaleY: Double, rotation: Double) {
        let sx = (a * a + b * b).squareRoot()
        let rotation = atan2(b, a)
        let sy = sx > 1e-12 ? (a * d - b * c) / sx : 1
        let centre = apply(sourceSize / 2)
        let x = centre.x - sourceSize.x * sx / 2, y = centre.y - sourceSize.y * sy / 2
        return (x, y, sx, sy, rotation)
    }

    public func apply(_ p: SIMD2<Double>) -> SIMD2<Double> {
        let w = g * p.x + h * p.y + 1
        let q = SIMD2(a * p.x + c * p.y + tx, b * p.x + d * p.y + ty)
        return abs(w) > 1e-12 ? q / w : q
    }

    public var matrix: simd_double3x3 {
        simd_double3x3(columns: (SIMD3(a, b, g), SIMD3(c, d, h), SIMD3(tx, ty, 1)))
    }

    public init(matrix m: simd_double3x3) {
        let k = abs(m.columns.2.z) > 1e-15 ? 1 / m.columns.2.z : 1
        self.init(a: m.columns.0.x * k, b: m.columns.0.y * k, c: m.columns.1.x * k, d: m.columns.1.y * k,
                  tx: m.columns.2.x * k, ty: m.columns.2.y * k, g: m.columns.0.z * k, h: m.columns.1.z * k)
    }

    public var inverse: AffineTransform {
        guard abs(matrix.determinant) > 1e-15 else { return .identity }
        return AffineTransform(matrix: matrix.inverse)
    }

    /// `self ∘ inner` (inner applied first).
    public func concatenating(_ inner: AffineTransform) -> AffineTransform {
        AffineTransform(matrix: matrix * inner.matrix)
    }

    public func translated(by o: SIMD2<Double>) -> AffineTransform {
        AffineTransform(a: 1, b: 0, c: 0, d: 1, tx: o.x, ty: o.y).concatenating(self)
    }

    /// Document-space bounding box of a source rectangle.
    public func bounds(ofSourceSize s: SIMD2<Double>) -> PixelRect {
        let pts = [SIMD2(0, 0), SIMD2(s.x, 0), SIMD2(0, s.y), s].map(apply)
        let lo = pts.reduce(pts[0]) { simd_min($0, $1) }, hi = pts.reduce(pts[0]) { simd_max($0, $1) }
        let x0 = Int(lo.x.rounded(.down)), y0 = Int(lo.y.rounded(.down))
        return PixelRect(x: x0, y: y0, width: Int(hi.x.rounded(.up)) - x0, height: Int(hi.y.rounded(.up)) - y0)
    }
}

public struct SmartObject: Sendable {
    /// Source pixels, top-left at the origin.
    public var source: TileGrid
    public var width: Int
    public var height: Int
    public var transform: AffineTransform

    public init(source: TileGrid, width: Int, height: Int, transform: AffineTransform) {
        self.source = source
        self.width = width
        self.height = height
        self.transform = transform
    }

    public var sourceSize: SIMD2<Double> { SIMD2(Double(width), Double(height)) }
    public var bounds: PixelRect { transform.bounds(ofSourceSize: sourceSize) }
}

// MARK: Groups

public struct LayerGroup: Sendable {
    /// Bottom → top.
    public var children: [Layer]
    public var isExpanded: Bool

    public init(children: [Layer] = [], isExpanded: Bool = true) {
        self.children = children
        self.isExpanded = isExpanded
    }
}
