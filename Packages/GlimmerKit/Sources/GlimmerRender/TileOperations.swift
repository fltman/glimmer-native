import GlimmerCore
import Metal

/// GPU operations that produce new tile grids (never mutating existing tiles).
public enum TileOperations {
    /// Shifts a grid by whole pixels.
    public static func translate(
        _ grid: TileGrid, by offset: SIMD2<Int>, context: MetalContext
    ) throws -> TileGrid {
        guard offset != .zero, !grid.isEmpty else { return grid }
        let s = TileGeometry.size

        // Whole-tile moves only re-key the grid.
        if offset.x % s == 0, offset.y % s == 0 {
            var moved = TileGrid()
            for (c, tile) in grid.tiles { moved[TileCoord(c.x + offset.x / s, c.y + offset.y / s)] = tile }
            return moved
        }

        // Which source tiles land on each destination tile.
        var sources: [TileCoord: [(TileCoord, Tile)]] = [:]
        for (c, tile) in grid.tiles {
            for dest in c.rect.offsetBy(offset.x, offset.y).tileCoords {
                sources[dest, default: []].append((c, tile))
            }
        }

        let pipelines = try context.tilePipelines()
        guard let cb = context.commandQueue.makeCommandBuffer() else {
            throw RenderError.resourceCreationFailed("command buffer")
        }
        cb.label = "Translate layer"
        var result = TileGrid()
        let size = SIMD2<Float>(Float(s), Float(s))

        for (dest, parts) in sources {
            // A solid colour that covers the whole destination stays solid.
            if case .solid(let color) = parts.first!.1,
               parts.allSatisfy({ if case .solid(let c) = $0.1 { c == color } else { false } }),
               coversFully(dest: dest, parts: parts.map(\.0), offset: offset) {
                result[dest] = .solid(color)
                continue
            }
            let texture = TileTexture.makeTexture(device: context.device)
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = texture
            pass.colorAttachments[0].loadAction = .clear
            pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
            pass.colorAttachments[0].storeAction = .store
            guard let encoder = cb.makeRenderCommandEncoder(descriptor: pass) else { continue }
            encoder.setRenderPipelineState(pipelines.copy)
            for (src, tile) in parts {
                let o = src.origin &+ offset &- dest.origin
                pipelines.drawTile(tile, rect: SIMD4(Float(o.x), Float(o.y), Float(s), Float(s)),
                                   targetSize: size, encoder: encoder)
            }
            encoder.endEncoding()
            result[dest] = .texture(TileTexture(texture))
        }
        cb.commit()
        cb.waitUntilCompleted()
        if let error = cb.error { throw error }
        return result
    }

    private static func coversFully(dest: TileCoord, parts: [TileCoord], offset: SIMD2<Int>) -> Bool {
        // Sum of overlap areas equals the tile area (source tiles never overlap each other).
        let target = dest.rect
        let area = parts.reduce(0) { sum, src in
            let r = src.rect.offsetBy(offset.x, offset.y).intersection(target)
            return sum + r.width * r.height
        }
        return area == target.width * target.height
    }

    /// Moves a whole layer: pixels, mask, smart-object placement, gradient
    /// points and (for groups) every descendant.
    public static func translate(_ layer: Layer, by offset: SIMD2<Int>, context: MetalContext) throws -> Layer {
        guard offset != .zero else { return layer }
        var moved = layer
        let d = SIMD2(Double(offset.x), Double(offset.y))
        if var mask = layer.mask {
            mask.tiles = try translate(mask.tiles, by: offset, context: context)
            moved.mask = mask
        }
        switch layer.content {
        case .raster(let grid):
            moved.content = .raster(try translate(grid, by: offset, context: context))
        case .smart(var smart):
            smart.transform = smart.transform.translated(by: d)
            moved.content = .smart(smart)
        case .fill(.gradient(var g)):
            g.start += d
            g.end += d
            moved.content = .fill(.gradient(g))
        case .group(var group):
            group.children = try group.children.map { try translate($0, by: offset, context: context) }
            moved.content = .group(group)
        case .fill, .adjustment:
            break
        }
        return moved
    }
}
