import Foundation
import GlimmerRender

/// Brush parameters (mirrors the web app's `BrushParams`).
public struct BrushSettings: Equatable, Sendable, Codable {
    /// Diameter in document pixels.
    public var size: Double = 30
    /// 0 = soft, 1 = hard.
    public var hardness: Double = 0.8
    /// Caps the stroke (0...1).
    public var opacity: Double = 1
    /// Paint laid down per dab; builds up within a stroke (0...1).
    public var flow: Double = 1
    /// Dab spacing as a fraction of the diameter.
    public var spacing: Double = 0.1
    public var roundness: Double = 1
    /// Degrees.
    public var angle: Double = 0
    /// Random offset as a fraction of the diameter.
    public var scatter: Double = 0
    /// Random size variation 0...1.
    public var sizeJitter: Double = 0
    public var textured = false
    public var pressureSize = true
    public var pressureOpacity = false
    /// The dab's long axis follows the direction the pen leans.
    public var tiltAngle = false
    /// The dab flattens as the pen leans over (like the side of a pencil).
    public var tiltRoundness = false
    /// Barrel rotation of the pen turns the dab.
    public var rotationAngle = false

    public init() {}

    public static let presets: [(String, BrushSettings)] = {
        var soft = BrushSettings(); soft.hardness = 0; soft.size = 60
        var hard = BrushSettings(); hard.hardness = 1; hard.size = 20
        var chalk = BrushSettings(); chalk.hardness = 0.6; chalk.textured = true; chalk.size = 40; chalk.flow = 0.8
        var calligraphy = BrushSettings(); calligraphy.hardness = 0.95; calligraphy.roundness = 0.25; calligraphy.angle = 45; calligraphy.size = 30
        var airbrush = BrushSettings(); airbrush.hardness = 0; airbrush.flow = 0.08; airbrush.size = 120; airbrush.spacing = 0.05
        var pencil = BrushSettings(); pencil.hardness = 1; pencil.size = 2; pencil.spacing = 0.05
        return [("Soft Round", soft), ("Hard Round", hard), ("Chalk", chalk), ("Calligraphic", calligraphy),
                ("Airbrush", airbrush), ("Pencil", pencil)]
    }()
}

/// Turns pointer samples into evenly spaced dabs (with pressure, jitter, scatter),
/// carrying the remaining distance between events.
public struct StrokeSampler {
    public struct Sample: Sendable {
        public var position: SIMD2<Double>
        /// 0...1 (1 for a mouse).
        public var pressure: Double
        /// Pen tilt, -1...1 on each axis (document orientation, y down); zero for a mouse.
        public var tilt: SIMD2<Double>
        /// Pen barrel rotation in degrees.
        public var rotation: Double

        public init(_ position: SIMD2<Double>, pressure: Double = 1, tilt: SIMD2<Double> = .zero, rotation: Double = 0) {
            self.position = position
            self.pressure = pressure
            self.tilt = tilt
            self.rotation = rotation
        }
    }

    public var settings: BrushSettings
    private var last: Sample?
    private var carry: Double = 0
    private var rng = SystemRandomNumberGenerator()

    public init(settings: BrushSettings) {
        self.settings = settings
    }

    public mutating func begin(_ s: Sample) -> [DabInstance] {
        last = s
        carry = 0
        return [dab(at: s)]
    }

    public mutating func move(to s: Sample) -> [DabInstance] {
        guard let previous = last else { return begin(s) }
        let delta = s.position - previous.position
        let length = (delta.x * delta.x + delta.y * delta.y).squareRoot()
        let step = max(0.5, settings.spacing * settings.size)
        var dabs: [DabInstance] = []
        var travelled = step - carry
        while travelled <= length {
            let t = travelled / max(length, 1e-9)
            let p = previous.position + delta * t
            let sample = Sample(p, pressure: previous.pressure + (s.pressure - previous.pressure) * t,
                                tilt: previous.tilt + (s.tilt - previous.tilt) * t,
                                rotation: previous.rotation + (s.rotation - previous.rotation) * t)
            dabs.append(dab(at: sample))
            travelled += step
        }
        carry = length - (travelled - step)
        last = s
        return dabs
    }

    mutating func dab(at s: Sample) -> DabInstance {
        let p = s.position, pressure = s.pressure
        var size = settings.size * (settings.pressureSize ? 0.15 + 0.85 * pressure : 1)
        if settings.sizeJitter > 0 { size *= 1 - settings.sizeJitter * Double.random(in: 0...1, using: &rng) }
        var position = p
        if settings.scatter > 0 {
            let a = Double.random(in: 0..<(2 * .pi), using: &rng)
            let r = settings.scatter * settings.size * Double.random(in: 0...1, using: &rng)
            position += SIMD2(cos(a), sin(a)) * r
        }
        let flow = settings.flow * (settings.pressureOpacity ? 0.1 + 0.9 * pressure : 1)
        let (angle, roundness) = Self.shape(settings, s)
        return DabInstance(center: SIMD2(Float(position.x), Float(position.y)), radius: Float(max(size, 0.5) / 2),
                           hardness: Float(settings.hardness), roundness: Float(roundness),
                           angle: Float(angle * .pi / 180), flow: Float(flow), textured: settings.textured)
    }

    /// Dab angle (degrees) and roundness after tilt and rotation dynamics.
    public static func shape(_ settings: BrushSettings, _ s: Sample) -> (angle: Double, roundness: Double) {
        var angle = settings.angle, roundness = settings.roundness
        let lean = min((s.tilt.x * s.tilt.x + s.tilt.y * s.tilt.y).squareRoot(), 1)
        if settings.tiltAngle, lean > 0.05 { angle = atan2(s.tilt.y, s.tilt.x) * 180 / .pi }
        if settings.rotationAngle { angle += s.rotation }
        if settings.tiltRoundness { roundness *= max(0.2, 1 - 0.8 * lean) }
        return (angle, roundness)
    }
}
