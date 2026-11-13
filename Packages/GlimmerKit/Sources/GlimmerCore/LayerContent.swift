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
public struct AffineTransform: Codable, Hashable, Sendable {
    public var a: Double, b: Double, c: Double, d: Double, tx: Double, ty: Double

    public init(a: Double = 1, b: Double = 0, c: Double = 0, d: Double = 1, tx: Double = 0, ty: Double = 0) {
        self.a = a; self.b = b; self.c = c; self.d = d; self.tx = tx; self.ty = ty
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
        SIMD2(a * p.x + c * p.y + tx, b * p.x + d * p.y + ty)
    }

    public var inverse: AffineTransform {
        let det = a * d - b * c
        guard abs(det) > 1e-12 else { return .identity }
        let ia = d / det, ib = -b / det, ic = -c / det, id = a / det
        return AffineTransform(a: ia, b: ib, c: ic, d: id,
                               tx: -(ia * tx + ic * ty), ty: -(ib * tx + id * ty))
    }

    public func translated(by o: SIMD2<Double>) -> AffineTransform {
        var t = self
        t.tx += o.x
        t.ty += o.y
        return t
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
