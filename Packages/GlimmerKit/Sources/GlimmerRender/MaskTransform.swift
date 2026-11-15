import Foundation
import GlimmerCore

/// Moves a layer mask through the transform its layer gets (Free Transform), so the mask
/// stays in line with the pixels.
public enum MaskTransform {
    /// The mask's tiles after `transform` (document → document; may be a perspective).
    ///
    /// Stored tiles are resampled. Everywhere else the mask keeps its default value: for a
    /// reveal-all mask (default white) the hidden part is what moves, so nothing outside the
    /// moved area turns black.
    ///
    /// `exact` false is for live previews: it skips the two CPU passes a white-default mask
    /// needs and instead fills the default over `cover` (where the layer's content is) before
    /// resampling. That is right wherever the layer has content; only empty surroundings differ.
    public static func apply(_ mask: LayerMask, transform: GlimmerCore.AffineTransform, limit: PixelRect,
                             exact: Bool = true, cover: PixelRect? = nil, context: MetalContext) throws -> TileGrid {
        guard let stored = mask.tiles.tileBounds else { return mask.tiles }  // one value everywhere: nothing to move
        let renderer = try SmartObjectRenderer(context: context)
        func resample(_ grid: TileGrid) throws -> TileGrid {
            guard let b = grid.tileBounds else { return TileGrid() }
            let source = try TileOperations.translate(grid, by: SIMD2(-b.x, -b.y), context: context)
            let placed = transform.concatenating(GlimmerCore.AffineTransform(tx: Double(b.x), ty: Double(b.y)))
            return try renderer.render(SmartObject(source: source, width: b.width, height: b.height, transform: placed), limit: limit)
        }
        guard mask.defaultValue >= 0.5 else { return try resample(mask.tiles) }
        if !exact {
            var grid = mask.tiles
            var region = stored
            if let c = cover, c.width > 0, c.height > 0 {
                let x0 = min(c.x, stored.x), y0 = min(c.y, stored.y)
                region = RegionOps.tileAligned(PixelRect(x: x0, y: y0, width: max(c.maxX, stored.maxX) - x0,
                                                         height: max(c.maxY, stored.maxY) - y0))
            }
            for coord in region.tileCoords where grid[coord] == nil { grid[coord] = .solid(SIMD4(repeating: 1)) }
            return try resample(grid)
        }
        // Move what the mask hides (1 − value, zero outside the stored tiles), then turn it back.
        var hidden = TileGrid()
        for (coord, tile) in mask.tiles.tiles { hidden[coord] = inverted(tile, emptyAsNil: true) }
        let moved = try resample(hidden)
        var result = TileGrid()
        for (coord, tile) in moved.tiles { result[coord] = inverted(tile, emptyAsNil: false) }
        return result
    }

    /// 1 − value in every channel. A tile that becomes all zero is nil (`emptyAsNil`, for a
    /// sparse source) or stored as solid black (a mask must keep it: missing means default).
    static func inverted(_ tile: Tile, emptyAsNil: Bool) -> Tile? {
        let empty: Tile? = emptyAsNil ? nil : .solid(SIMD4(repeating: 0))
        switch tile {
        case .solid(let c):
            let v = 1 - min(max(c.w, 0), 1)
            return v <= 0 ? empty : .solid(SIMD4(repeating: v))
        case .texture:
            var px = tile.pixels()
            for i in px.indices { px[i] = 1 - min(max(px[i], 0), 1) }
            return px.withUnsafeBytes { Tile.make(pixels: $0.baseAddress!, bytesPerRow: TileGeometry.bytesPerRow) } ?? empty
        }
    }
}
