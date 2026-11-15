import AppKit
import GlimmerCore
import GlimmerRender
import GlimmerTools
import SwiftUI
import simd

/// `RegionOps` is internal to GlimmerRender; tools only need `expand`.
enum RegionOps_public {
    static func expand(_ r: PixelRect, by n: Int) -> PixelRect {
        PixelRect(x: r.x - n, y: r.y - n, width: r.width + 2 * n, height: r.height + 2 * n)
    }
}

extension TileGrid {
    /// The same tiles (alpha is what selection bounds read).
    func mapAlphaOnly() -> TileGrid { self }
}

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self { min(max(self, range.lowerBound), range.upperBound) }
}

/// A name Glimmer gives a new layer, in the user's language ("Kurvor", "Lager 1").
func layerName(_ english: String) -> String { String(localized: String.LocalizationValue(english)) }
