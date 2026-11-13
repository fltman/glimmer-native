import Foundation

/// Pen-tablet preferences (Settings › Tablet).
enum TabletSettings {
    static let pressureCurveKey = "tablet.pressureCurve"
    static let useTiltKey = "tablet.useTilt"

    /// Exponent applied to raw pressure: below 1 is softer (less force for the
    /// same effect), above 1 firmer.
    static var pressureExponent: Double {
        let v = UserDefaults.standard.double(forKey: pressureCurveKey)
        return v > 0 ? v : 1
    }

    static var useTilt: Bool {
        UserDefaults.standard.object(forKey: useTiltKey) as? Bool ?? true
    }

    static func curve(_ pressure: Double, exponent: Double = pressureExponent) -> Double {
        pow(min(max(pressure, 0), 1), exponent)
    }
}
