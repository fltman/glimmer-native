import simd

/// Maps between document pixels and view points (both y-down).
///
/// `view = translation + R(rotation) · (scale · document)`
///
/// The transform only affects presentation; compositing always happens in
/// document space.
public struct ViewTransform: Equatable, Sendable {
    public static let minScale = 0.02
    public static let maxScale = 64.0

    /// View points per document pixel.
    public private(set) var scale: Double
    /// Radians, clockwise on screen, normalized to (-π, π].
    public private(set) var rotation: Double
    /// View-space position of the document origin.
    public var translation: SIMD2<Double>

    public init(scale: Double = 1, rotation: Double = 0, translation: SIMD2<Double> = .zero) {
        self.scale = Self.clampScale(scale)
        self.rotation = Self.normalize(rotation)
        self.translation = translation
    }

    // MARK: Mapping

    var rotationMatrix: simd_double2x2 {
        let c = cos(rotation), s = sin(rotation)
        return simd_double2x2(columns: (SIMD2(c, s), SIMD2(-s, c)))
    }

    public func viewPoint(fromDocument point: SIMD2<Double>) -> SIMD2<Double> {
        translation + rotationMatrix * (point * scale)
    }

    public func documentPoint(fromView point: SIMD2<Double>) -> SIMD2<Double> {
        rotationMatrix.transpose * (point - translation) / scale
    }

    /// Homogeneous view → document matrix (column-major, for shaders).
    public var viewToDocumentMatrix: simd_double3x3 {
        let a = rotationMatrix.transpose * (1 / scale)
        let b = -(a * translation)
        return simd_double3x3(columns: (
            SIMD3(a.columns.0, 0),
            SIMD3(a.columns.1, 0),
            SIMD3(b, 1)
        ))
    }

    // MARK: Manipulation (all anchored so the document point under `anchor` stays put)

    public mutating func pan(by delta: SIMD2<Double>) {
        translation += delta
    }

    public mutating func zoom(by factor: Double, around anchor: SIMD2<Double>) {
        setScale(scale * factor, around: anchor)
    }

    public mutating func setScale(_ newScale: Double, around anchor: SIMD2<Double>) {
        let pinned = documentPoint(fromView: anchor)
        scale = Self.clampScale(newScale)
        translation = anchor - rotationMatrix * (pinned * scale)
    }

    public mutating func rotate(by angle: Double, around anchor: SIMD2<Double>) {
        setRotation(rotation + angle, around: anchor)
    }

    public mutating func setRotation(_ angle: Double, around anchor: SIMD2<Double>) {
        let pinned = documentPoint(fromView: anchor)
        rotation = Self.normalize(angle)
        translation = anchor - rotationMatrix * (pinned * scale)
    }

    /// A transform that centers the (possibly rotated) document in the view.
    public static func fitting(
        documentSize: SIMD2<Double>,
        in viewSize: SIMD2<Double>,
        rotation: Double = 0,
        margin: Double = 0.92
    ) -> ViewTransform {
        guard documentSize.x > 0, documentSize.y > 0, viewSize.x > 0, viewSize.y > 0 else {
            return ViewTransform(rotation: rotation)
        }
        let c = abs(cos(rotation)), s = abs(sin(rotation))
        let bounds = SIMD2(c * documentSize.x + s * documentSize.y,
                           s * documentSize.x + c * documentSize.y)
        let scale = min(viewSize.x / bounds.x, viewSize.y / bounds.y) * margin
        var t = ViewTransform(scale: scale, rotation: rotation)
        t.translation = viewSize / 2 - t.rotationMatrix * (documentSize / 2 * t.scale)
        return t
    }

    /// Snaps a free rotation to the nearest right angle when within `threshold` radians.
    public static func snappedRotation(_ raw: Double, threshold: Double = 3 * .pi / 180) -> Double {
        let quarter = Double.pi / 2
        let nearest = (raw / quarter).rounded() * quarter
        return abs(raw - nearest) <= threshold ? nearest : raw
    }

    // MARK: Helpers

    static func clampScale(_ s: Double) -> Double {
        guard s.isFinite, s > 0 else { return 1 }
        return min(max(s, minScale), maxScale)
    }

    static func normalize(_ angle: Double) -> Double {
        var a = angle.truncatingRemainder(dividingBy: 2 * .pi)
        if a <= -.pi { a += 2 * .pi }
        if a > .pi { a -= 2 * .pi }
        return a
    }
}

/// Photoshop-style zoom stops (as a fraction: 1 = 100 %).
public enum ZoomLadder {
    public static let stops: [Double] = [
        0.02, 0.03, 0.04, 0.05, 0.0625, 0.0833, 0.125, 0.1667, 0.25, 0.3333,
        0.5, 0.6667, 1, 1.5, 2, 3, 4, 6, 8, 12, 16, 24, 32, 48, 64,
    ]

    public static func next(after zoom: Double) -> Double {
        stops.first { $0 > zoom * 1.0001 } ?? stops[stops.count - 1]
    }

    public static func previous(before zoom: Double) -> Double {
        stops.last { $0 < zoom * 0.9999 } ?? stops[0]
    }
}
