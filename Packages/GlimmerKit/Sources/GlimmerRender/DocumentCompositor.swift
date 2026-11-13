import Foundation
import GlimmerCore
import Metal

/// Temporary, non-undoable changes shown while a tool is active (e.g. a layer
/// being dragged). Committed edits go into `DocumentState`.
public struct LayerOverrides: Equatable, Sendable {
    /// Integer pixel offsets per layer id.
    public var offsets: [UUID: SIMD2<Int>]

    public init(offsets: [UUID: SIMD2<Int>] = [:]) {
        self.offsets = offsets
    }

    public static let none = LayerOverrides()
}

/// Composites a document into a cache of 256×256 tiles in document space,
/// re-rendering only tiles whose inputs changed.
///
/// Each cached tile is RGBA16Float, premultiplied linear, with a full mip chain
/// so the canvas can minify without aliasing.
public final class DocumentCompositor {
    public static let mipLevels = 9  // 256 → 1

    private struct Entry {
        var signature: Int
        /// nil when nothing visible contributes (fully transparent).
        var texture: MTLTexture?
    }

    private let context: MetalContext
    private let pipelines: TilePipelines
    private var cache: [TileCoord: Entry] = [:]
    private var pool: [MTLTexture] = []

    public init(context: MetalContext) throws {
        self.context = context
        self.pipelines = try context.tilePipelines()
    }

    /// One layer's contribution to a document tile.
    private struct Contribution {
        var tile: Tile
        /// Quad in output-tile pixels.
        var rect: SIMD4<Float>
        var source: SourceUniforms
    }

    private func contributions(
        at coord: TileCoord, in state: DocumentState, overrides: LayerOverrides
    ) -> (signature: Int, items: [Contribution]) {
        var hasher = Hasher()
        hasher.combine(state.blendSpace)
        var items: [Contribution] = []
        let gamma: Int32 = state.blendSpace == .gamma ? 1 : 0
        let target = coord.rect

        for layer in state.layers where layer.isVisible && layer.opacity > 0 {
            let offset = overrides.offsets[layer.id] ?? .zero
            let source = SourceUniforms(mode: layer.blendMode.shaderIndex,
                                        opacity: Float(layer.opacity), gammaSpace: gamma)
            let grid = layer.tiles
            // Layer tiles whose shifted footprint overlaps this output tile.
            let needed = offset == .zero ? [coord] : target.offsetBy(-offset.x, -offset.y).tileCoords
            var contributed = false
            for lc in needed {
                guard let tile = grid[lc] else { continue }
                if !contributed {
                    hasher.combine(layer.blendMode)
                    hasher.combine(layer.opacity)
                    hasher.combine(offset.x); hasher.combine(offset.y)
                    contributed = true
                }
                hasher.combine(lc)
                tile.combineIdentity(into: &hasher)
                let o = lc.origin &+ offset &- coord.origin
                let size = Float(TileGeometry.size)
                items.append(Contribution(tile: tile,
                                          rect: SIMD4(Float(o.x), Float(o.y), size, size),
                                          source: source))
            }
        }
        return (hasher.finalize(), items)
    }

    /// Re-composites up to `budget` stale tiles from `coords` (in priority order).
    /// Returns true when stale tiles remain.
    @discardableResult
    public func update(
        _ state: DocumentState,
        overrides: LayerOverrides = .none,
        coords: [TileCoord],
        budget: Int = .max,
        commandBuffer: MTLCommandBuffer
    ) -> Bool {
        var done = 0
        var remaining = false
        var mipTargets: [MTLTexture] = []
        let size = SIMD2<Float>(Float(TileGeometry.size), Float(TileGeometry.size))

        for coord in coords {
            let (signature, items) = contributions(at: coord, in: state, overrides: overrides)
            if cache[coord]?.signature == signature { continue }
            if done >= budget {
                remaining = true
                break
            }
            done += 1

            if items.isEmpty {
                if let old = cache[coord]?.texture { pool.append(old) }
                cache[coord] = Entry(signature: signature, texture: nil)
                continue
            }

            let texture = cache[coord]?.texture ?? makeTexture()
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = texture
            pass.colorAttachments[0].loadAction = .clear
            pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
            pass.colorAttachments[0].storeAction = .store
            guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { continue }
            encoder.label = "Composite \(coord.x),\(coord.y)"
            encoder.setRenderPipelineState(pipelines.blend)
            for item in items {
                pipelines.draw(item.tile, rect: item.rect, targetSize: size, source: item.source, encoder: encoder)
            }
            encoder.endEncoding()
            mipTargets.append(texture)
            cache[coord] = Entry(signature: signature, texture: texture)
        }

        if !mipTargets.isEmpty, let blit = commandBuffer.makeBlitCommandEncoder() {
            blit.label = "Composite mips"
            for texture in mipTargets { blit.generateMipmaps(for: texture) }
            blit.endEncoding()
        }
        return remaining
    }

    /// The composited tile at `coord`, if it has been rendered and isn't empty.
    public func texture(at coord: TileCoord) -> MTLTexture? {
        cache[coord]?.texture
    }

    /// Drops cached tiles outside `bounds` (e.g. after the document shrinks).
    public func purge(outside bounds: PixelRect) {
        let keep = Set(bounds.tileCoords)
        for (coord, entry) in cache where !keep.contains(coord) {
            if let t = entry.texture { pool.append(t) }
            cache[coord] = nil
        }
    }

    private func makeTexture() -> MTLTexture {
        if let reused = pool.popLast() { return reused }
        let d = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: TileGeometry.pixelFormat,
            width: TileGeometry.size, height: TileGeometry.size, mipmapped: true)
        d.mipmapLevelCount = Self.mipLevels
        d.usage = [.renderTarget, .shaderRead]
        d.storageMode = .private
        guard let texture = context.device.makeTexture(descriptor: d) else {
            fatalError("Out of GPU memory allocating a composite tile")
        }
        texture.label = "Composite tile"
        return texture
    }

    // MARK: Full-document rendering (export, thumbnails, tests)

    /// Composites every tile of the document and returns premultiplied linear
    /// Float16 RGBA pixels for `region` (default: the whole document).
    public func renderPixels(
        _ state: DocumentState, overrides: LayerOverrides = .none, region: PixelRect? = nil
    ) throws -> (buffer: MTLBuffer, bytesPerRow: Int, rect: PixelRect) {
        let rect = (region ?? state.bounds).intersection(state.bounds)
        guard !rect.isEmpty else { throw RenderError.resourceCreationFailed("empty region") }
        let bytesPerRow = rect.width * TileGeometry.bytesPerPixel
        guard let buffer = context.device.makeBuffer(length: bytesPerRow * rect.height, options: .storageModeShared) else {
            throw RenderError.resourceCreationFailed("export buffer")
        }
        memset(buffer.contents(), 0, buffer.length)

        let coords = rect.tileCoords
        // Batch so huge documents don't build one enormous command buffer.
        for batch in stride(from: 0, to: coords.count, by: 64) {
            let slice = Array(coords[batch..<min(batch + 64, coords.count)])
            guard let cb = context.commandQueue.makeCommandBuffer() else { continue }
            update(state, overrides: overrides, coords: slice, commandBuffer: cb)
            if let blit = cb.makeBlitCommandEncoder() {
                for coord in slice {
                    guard let texture = texture(at: coord) else { continue }
                    let part = coord.rect.intersection(rect)
                    let src = MTLOrigin(x: part.x - coord.rect.x, y: part.y - coord.rect.y, z: 0)
                    let offset = (part.y - rect.y) * bytesPerRow + (part.x - rect.x) * TileGeometry.bytesPerPixel
                    blit.copy(from: texture, sourceSlice: 0, sourceLevel: 0, sourceOrigin: src,
                              sourceSize: MTLSize(width: part.width, height: part.height, depth: 1),
                              to: buffer, destinationOffset: offset,
                              destinationBytesPerRow: bytesPerRow,
                              destinationBytesPerImage: bytesPerRow * rect.height)
                }
                blit.endEncoding()
            }
            cb.commit()
            cb.waitUntilCompleted()
        }
        return (buffer, bytesPerRow, rect)
    }
}

