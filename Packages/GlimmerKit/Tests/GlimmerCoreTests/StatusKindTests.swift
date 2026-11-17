import Testing
@testable import GlimmerCore

/// The states said in the window (SIBLINGS.md, "Tillstånd i fönstret"): one symbol each, and a colour that
/// stands out from every surface it is shown on.
@Suite struct StatusKindTests {
    static func rgb(_ hex: UInt32) -> (red: Double, green: Double, blue: Double) {
        (Double((hex >> 16) & 0xff) / 255, Double((hex >> 8) & 0xff) / 255, Double(hex & 0xff) / 255)
    }
    /// Glimmer's own surfaces (App/Theme.swift): background, panel, raised. These are exact.
    static let glimmerDark: [UInt32] = [0x0c0d11, 0x16171c, 0x1f2027]
    /// The system's surfaces where Settings and sheets stand. Approximate until sampled from pictures
    /// (window and form row, dark and light); the limits below leave room for that.
    static let systemDark: [UInt32] = [0x323232, 0x3a3a3c]
    /// Light: sampled from a picture of Settings (window #ffffff, form row #f7f7f7, 2026-11-17); #ececec kept as the darker bound.
    static let systemLight: [UInt32] = [0xececec, 0xf7f7f7, 0xffffff]

    @Test func eachKindHasItsOwnSymbolAndTheTriangleIsOnlyAWarning() {
        let symbols = StatusKind.allCases.compactMap(\.symbol)
        #expect(Set(symbols).count == symbols.count, "one symbol, one meaning")
        #expect(StatusKind.warning.symbol?.contains("triangle") == true)
        #expect(StatusKind.error.symbol?.contains("octagon") == true && StatusKind.error.symbol?.contains("triangle") == false)
        #expect(StatusKind.working.symbol == nil)
        #expect(StatusKind.error.prefix == "Error:" && StatusKind.warning.prefix == "Warning:")
    }

    @Test func theSymbolColourStandsOutFromEverySurface() {
        for kind in StatusKind.allCases {
            for surface in Self.glimmerDark + Self.systemDark {
                let ratio = StatusKind.contrast(kind.color(onDark: true), Self.rgb(surface))
                #expect(ratio >= 3, "\(kind) on dark \(String(surface, radix: 16)): \(ratio)")
            }
            // On Glimmer's own surfaces the colours would pass as text too.
            for surface in Self.glimmerDark {
                #expect(StatusKind.contrast(kind.color(onDark: true), Self.rgb(surface)) >= 4.5, "\(kind) on \(String(surface, radix: 16))")
            }
            for surface in Self.systemLight {
                let ratio = StatusKind.contrast(kind.color(onDark: false), Self.rgb(surface))
                #expect(ratio >= 4.5, "\(kind) on light \(String(surface, radix: 16)): \(ratio)")
            }
        }
    }

    /// The figures behind the rule: without hue, an error and a warning are the same colour. Kept as a test so the
    /// claim in the notes is a measured one; it is the shape and the prefix that tell them apart.
    @Test func errorAndWarningAreNotToldApartByLuminance() {
        let dark = StatusKind.contrast(StatusKind.error.color(onDark: true), StatusKind.warning.color(onDark: true))
        let light = StatusKind.contrast(StatusKind.error.color(onDark: false), StatusKind.warning.color(onDark: false))
        #expect(dark < 1.6 && light < 1.05, "dark \(dark), light \(light)")
    }

    /// The status colours are not the accent (indigo, #6d7dff): each is far from it in hue, or has no hue (the grey).
    @Test func noStatusColourIsTheAccent() {
        func hue(_ c: (red: Double, green: Double, blue: Double)) -> (hue: Double, saturation: Double) {
            let hi = max(c.red, c.green, c.blue), lo = min(c.red, c.green, c.blue), d = hi - lo
            guard d > 0 else { return (0, 0) }
            var h = hi == c.red ? (c.green - c.blue) / d : hi == c.green ? 2 + (c.blue - c.red) / d : 4 + (c.red - c.green) / d
            h = (h * 60).truncatingRemainder(dividingBy: 360); if h < 0 { h += 360 }
            return (h, d / hi)
        }
        let accent = hue(Self.rgb(0x6d7dff))
        for kind in StatusKind.allCases {
            for dark in [true, false] {
                let c = hue(kind.color(onDark: dark))
                let apart = min(abs(c.hue - accent.hue), 360 - abs(c.hue - accent.hue))
                #expect(apart >= 60 || c.saturation < 0.2, "\(kind) (dark: \(dark)) is \(apart)° from the accent, saturation \(c.saturation)")
            }
        }
    }
}
