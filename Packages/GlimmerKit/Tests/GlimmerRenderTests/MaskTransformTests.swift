import Foundation
@testable import GlimmerCore
@testable import GlimmerRender
import Testing

/// A layer mask follows its layer through Free Transform.
@Suite struct MaskTransformTests {
    func value(_ grid: TileGrid, _ x: Int, _ y: Int, default d: Float) -> Float {
        func fd(_ a: Int) -> Int { a >= 0 ? a / TileGeometry.size : -((-a + TileGeometry.size - 1) / TileGeometry.size) }
        let coord = TileCoord(fd(x), fd(y))
        guard let tile = grid[coord] else { return d }
        let px = tile.pixels()
        let lx = x - coord.x * TileGeometry.size, ly = y - coord.y * TileGeometry.size
        return Float(px[(ly * TileGeometry.size + lx) * 4 + 3])
    }
    let limit = PixelRect(x: -512, y: -512, width: 2048, height: 2048)

    /// Hide-all mask revealing a rectangle 100…200 × 100…160.
    static var hideAll: LayerMask { Selection.rectangle(CGRectLike(x0: 100, y0: 100, x1: 200, y1: 160)).asMask }
    /// Reveal-all mask hiding the same rectangle.
    static var revealAll: LayerMask { Selection.rectangle(CGRectLike(x0: 100, y0: 100, x1: 200, y1: 160)).inverted().asMask }

    @Test func aHideAllMaskScalesAndMovesWithTheLayer() throws {
        let context = try #require(MetalContext.shared)
        let mask = Self.hideAll
        #expect(mask.defaultValue == 0)
        // ×2 about the origin, then 300 right: the rectangle becomes 500…700 × 200…320.
        let t = GlimmerCore.AffineTransform(a: 2, d: 2, tx: 300)
        let out = try MaskTransform.apply(mask, transform: t, limit: limit, context: context)
        #expect(value(out, 600, 260, default: 0) > 0.99)
        #expect(value(out, 510, 210, default: 0) > 0.99 && value(out, 690, 310, default: 0) > 0.99)
        #expect(value(out, 490, 260, default: 0) < 0.01 && value(out, 600, 330, default: 0) < 0.01)
        #expect(value(out, 150, 130, default: 0) < 0.01, "nothing is left where the rectangle was")
    }

    @Test func aRevealAllMaskStaysWhiteOutsideWhatMoved() throws {
        let context = try #require(MetalContext.shared)
        let mask = Self.revealAll
        #expect(mask.defaultValue == 1)
        // Half size about the origin: the hidden rectangle becomes 50…100 × 50…80, well inside
        // one tile, so the rest of that tile must be white, not left black by the resampling.
        let t = GlimmerCore.AffineTransform(a: 0.5, d: 0.5)
        let out = try MaskTransform.apply(mask, transform: t, limit: limit, context: context)
        #expect(value(out, 75, 65, default: 1) < 0.01, "the hidden part moved")
        #expect(value(out, 150, 130, default: 1) > 0.99, "where it was is revealed again")
        #expect(value(out, 200, 200, default: 1) > 0.99 && value(out, 10, 10, default: 1) > 0.99)
        #expect(value(out, 400, 400, default: 1) > 0.99 && value(out, -100, 50, default: 1) > 0.99)
    }

    @Test func aQuarterTurnTurnsTheMask() throws {
        let context = try #require(MetalContext.shared)
        // (x, y) → (400 − y, x): the rectangle 100…200 × 100…160 becomes 240…300 × 100…200.
        let t = GlimmerCore.AffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 400)
        for mask in [Self.hideAll, Self.revealAll] {
            let inside: Float = mask.defaultValue == 0 ? 1 : 0, d = mask.defaultValue
            let out = try MaskTransform.apply(mask, transform: t, limit: limit, context: context)
            #expect(abs(value(out, 270, 150, default: d) - inside) < 0.01)
            #expect(abs(value(out, 250, 110, default: d) - inside) < 0.01 && abs(value(out, 290, 190, default: d) - inside) < 0.01)
            #expect(abs(value(out, 230, 150, default: d) - d) < 0.01 && abs(value(out, 270, 210, default: d) - d) < 0.01)
            #expect(abs(value(out, 150, 130, default: d) - d) < 0.01)
        }
    }

    @Test func thePreviewAgreesWhereTheLayerHasContent() throws {
        let context = try #require(MetalContext.shared)
        let mask = Self.revealAll
        let t = GlimmerCore.AffineTransform(a: 0.5, d: 0.5)
        let cover = PixelRect(x: 0, y: 0, width: 600, height: 600)  // the layer's pixels
        let quick = try MaskTransform.apply(mask, transform: t, limit: limit, exact: false, cover: cover, context: context)
        let exact = try MaskTransform.apply(mask, transform: t, limit: limit, context: context)
        for (x, y) in [(75, 65), (150, 130), (10, 10), (250, 250), (290, 20)] {  // inside the moved content, 0…300
            #expect(abs(value(quick, x, y, default: 1) - value(exact, x, y, default: 1)) < 0.01, "\(x),\(y)")
        }
    }

    @Test func aMaskWithoutTilesIsLeftAlone() throws {
        let context = try #require(MetalContext.shared)
        let out = try MaskTransform.apply(.revealAll, transform: GlimmerCore.AffineTransform(a: 2, d: 2), limit: limit, context: context)
        #expect(out.tiles.isEmpty)
    }
}
