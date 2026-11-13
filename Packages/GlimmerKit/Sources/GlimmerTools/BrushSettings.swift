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

        public init(_ position: SIMD2<Double>, pressure: Double = 1) {
            self.position = position
            self.pressure = pressure
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
        return [dab(at: s.position, pressure: s.pressure)]
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
            let pressure = previous.pressure + (s.pressure - previous.pressure) * t
            dabs.append(dab(at: p, pressure: pressure))
            travelled += step
        }
        carry = length - (travelled - step)
        last = s
        return dabs
    }

    mutating func dab(at p: SIMD2<Double>, pressure: Double) -> DabInstance {
        var size = settings.size * (settings.pressureSize ? 0.15 + 0.85 * pressure : 1)
        if settings.sizeJitter > 0 { size *= 1 - settings.sizeJitter * Double.random(in: 0...1, using: &rng) }
        var position = p
        if settings.scatter > 0 {
            let a = Double.random(in: 0..<(2 * .pi), using: &rng)
            let r = settings.scatter * settings.size * Double.random(in: 0...1, using: &rng)
            position += SIMD2(cos(a), sin(a)) * r
        }
        let flow = settings.flow * (settings.pressureOpacity ? 0.1 + 0.9 * pressure : 1)
        return DabInstance(center: SIMD2(Float(position.x), Float(position.y)), radius: Float(max(size, 0.5) / 2),
                           hardness: Float(settings.hardness), roundness: Float(settings.roundness),
                           angle: Float(settings.angle * .pi / 180), flow: Float(flow), textured: settings.textured)
    }
}
