import Foundation

/// Where each tile's visible pixels are, remembered by the tile's identity.
///
/// The tight bounds of a layer's content need every pixel's alpha, and reading a 24-megapixel layer through
/// takes seconds. But a step changes few tiles, and a tile that was not changed is the same tile (same
/// identity) as before: only the tiles a step touched are read again.
public final class TileBoundsCache: @unchecked Sendable {
    /// A tile's content inside the tile, as offsets from its origin; nil when nothing in it is visible.
    typealias Local = (minX: Int, minY: Int, maxX: Int, maxY: Int)?
    private var local: [UInt64: Local] = [:]
    private let lock = NSLock()
    private let limit: Int
    /// How many tiles were read through since the cache was made (for tests and measuring).
    public private(set) var tilesRead = 0

    public init(limit: Int = 200_000) { self.limit = limit }

    func bounds(of texture: TileTexture, read: () -> [Float16]) -> Local {
        lock.lock()
        if let hit = local[texture.id] { lock.unlock(); return hit }
        lock.unlock()
        let pixels = read()
        let s = TileGeometry.size
        var minX = Int.max, minY = Int.max, maxX = Int.min, maxY = Int.min
        pixels.withUnsafeBufferPointer { p in
            for y in 0..<s {
                let row = y * s * 4 + 3
                for x in 0..<s where p[row + x * 4] > 0.002 {
                    if x < minX { minX = x }
                    if x >= maxX { maxX = x + 1 }
                    if y < minY { minY = y }
                    maxY = y + 1
                }
            }
        }
        let found: Local = minX < maxX ? (minX, minY, maxX, maxY) : nil
        lock.lock()
        if local.count > limit { local.removeAll() }
        local[texture.id] = found
        tilesRead += 1
        lock.unlock()
        return found
    }
}

extension TileGrid {
    /// The tight bounds of the pixels that are not transparent (alpha above 0.002), in the grid's own coordinates.
    /// Each texture tile is read through once per identity (`cache`); a solid tile is all or nothing.
    public func contentBounds(cache: TileBoundsCache) -> PixelRect? {
        var minX = Int.max, minY = Int.max, maxX = Int.min, maxY = Int.min
        for (coord, tile) in tiles {
            let origin = coord.rect
            switch tile {
            case .solid(let c):
                guard c.w > 0.002 else { continue }
                minX = Swift.min(minX, origin.x); minY = Swift.min(minY, origin.y)
                maxX = Swift.max(maxX, origin.maxX); maxY = Swift.max(maxY, origin.maxY)
            case .texture(let texture):
                guard let b = cache.bounds(of: texture, read: { tile.pixels() }) else { continue }
                minX = Swift.min(minX, origin.x + b.minX); minY = Swift.min(minY, origin.y + b.minY)
                maxX = Swift.max(maxX, origin.x + b.maxX); maxY = Swift.max(maxY, origin.y + b.maxY)
            }
        }
        guard minX < maxX else { return nil }
        return PixelRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
}
