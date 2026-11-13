import Foundation
import GlimmerCore
import Metal

/// Mirrors `QuadUniforms` in Composite.metal.
struct QuadUniforms {
    var rect: SIMD4<Float>
    var uvRect: SIMD4<Float>
    var targetSize: SIMD2<Float>
}

/// Mirrors `LayerUniforms` in Composite.metal.
struct LayerUniforms {
    var overlay: SIMD4<Float> = .zero
    var patternForeground: SIMD4<Float> = .zero
    var patternBackground: SIMD4<Float> = .zero
    var gradientStart: SIMD2<Float> = .zero
    var gradientEnd: SIMD2<Float> = .zero
    var tileOrigin: SIMD2<Float> = .zero
    var mode: Int32 = 0
    var opacity: Float = 1
    var gammaSpace: Int32 = 0
    var sourceKind: Int32 = 0
    var maskDensity: Float = 0
    var clipDensity: Float = 0
    var overlayMode: Int32 = 0
    var patternKind: Int32 = 0
    var patternScale: Float = 1
    var gradientReverse: Int32 = 0
}

/// Mirrors `AdjustUniforms` in Composite.metal.
struct AdjustUniforms {
    var p0: SIMD4<Float> = .zero, p1: SIMD4<Float> = .zero, p2: SIMD4<Float> = .zero, p3: SIMD4<Float> = .zero
    var p4: SIMD4<Float> = .zero, p5: SIMD4<Float> = .zero, p6: SIMD4<Float> = .zero
    var kind: Int32 = 0
    var mode: Int32 = 0
    var opacity: Float = 1
    var gammaSpace: Int32 = 0
    var maskDensity: Float = 0
    var clipDensity: Float = 0
    var pad0: Int32 = 0
    var pad1: Int32 = 0

    mutating func setParameters(_ values: [Float]) {
        var v = values + [Float](repeating: 0, count: max(0, 28 - values.count))
        func q(_ i: Int) -> SIMD4<Float> { SIMD4(v[i], v[i + 1], v[i + 2], v[i + 3]) }
        p0 = q(0); p1 = q(4); p2 = q(8); p3 = q(12); p4 = q(16); p5 = q(20); p6 = q(24)
        v.removeAll()
    }
}

/// Pipeline states and small shared textures for tile rendering.
final class TilePipelines: @unchecked Sendable {
    let context: MetalContext
    let layer: MTLRenderPipelineState
    let passthroughMix: MTLRenderPipelineState
    let adjust: MTLRenderPipelineState
    let copy: MTLRenderPipelineState
    let thumbnail: MTLRenderPipelineState
    let smart: MTLRenderPipelineState
    let effectAlpha: MTLComputePipelineState
    let effectBinary: MTLComputePipelineState
    let effectColorize: MTLComputePipelineState

    private let lock = NSLock()
    private var solids: [SIMD4<Float>: MTLTexture] = [:]
    private var luts: [Int: MTLTexture] = [:]

    init(context: MetalContext) throws {
        self.context = context
        let library = context.library
        let device = context.device

        func render(_ fragment: String, vertex: String = "tile_quad_vertex",
                    blending: Bool = false) throws -> MTLRenderPipelineState {
            let d = MTLRenderPipelineDescriptor()
            d.label = fragment
            d.vertexFunction = library.makeFunction(name: vertex)
            d.fragmentFunction = library.makeFunction(name: fragment)
            guard d.vertexFunction != nil, d.fragmentFunction != nil else {
                throw RenderError.libraryUnavailable("missing \(fragment)")
            }
            let a = d.colorAttachments[0]!
            a.pixelFormat = TileGeometry.pixelFormat
            if blending {
                a.isBlendingEnabled = true
                a.sourceRGBBlendFactor = .one
                a.sourceAlphaBlendFactor = .one
                a.destinationRGBBlendFactor = .oneMinusSourceAlpha
                a.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            }
            return try device.makeRenderPipelineState(descriptor: d)
        }
        func compute(_ name: String) throws -> MTLComputePipelineState {
            guard let f = library.makeFunction(name: name) else { throw RenderError.libraryUnavailable("missing \(name)") }
            return try device.makeComputePipelineState(function: f)
        }

        layer = try render("composite_layer_fragment")
        passthroughMix = try render("passthrough_mix_fragment")
        adjust = try render("adjust_fragment")
        copy = try render("tile_copy_fragment")
        thumbnail = try render("thumbnail_fragment", blending: true)
        smart = try render("smart_fragment", vertex: "smart_vertex")
        effectAlpha = try compute("effect_alpha")
        effectBinary = try compute("effect_binary")
        effectColorize = try compute("effect_colorize")
    }

    // MARK: Shared textures

    /// A 1×1 texture of `color`, so solid tiles sample like any other.
    func solid(_ color: SIMD4<Float>) -> MTLTexture {
        lock.withLock {
            if let t = solids[color] { return t }
            if solids.count > 1024 { solids.removeAll() }
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: TileGeometry.pixelFormat, width: 1, height: 1, mipmapped: false)
            d.usage = .shaderRead
            d.storageMode = .shared
            let t = context.device.makeTexture(descriptor: d)!
            var h = SIMD4<Float16>(color)
            t.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: &h, bytesPerRow: 8)
            solids[color] = t
            return t
        }
    }

    var white: MTLTexture { solid(SIMD4(1, 1, 1, 1)) }
    var clear: MTLTexture { solid(.zero) }

    func texture(for tile: Tile) -> MTLTexture {
        switch tile {
        case .solid(let c): solid(c)
        case .texture(let t): t.texture
        }
    }

    /// A 1024×1 lookup texture (RGBA32Float), cached by `key`.
    func lut(key: Int, _ make: () -> [SIMD4<Float>]) -> MTLTexture {
        lock.withLock {
            if let t = luts[key] { return t }
            if luts.count > 256 { luts.removeAll() }
            var values = make()
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba32Float, width: values.count, height: 1, mipmapped: false)
            d.usage = .shaderRead
            d.storageMode = .shared
            let t = context.device.makeTexture(descriptor: d)!
            t.replace(region: MTLRegionMake2D(0, 0, values.count, 1), mipmapLevel: 0,
                      withBytes: &values, bytesPerRow: values.count * 16)
            luts[key] = t
            return t
        }
    }

    // MARK: Drawing

    static let tileSize = SIMD2<Float>(Float(TileGeometry.size), Float(TileGeometry.size))
    static let fullTile = SIMD4<Float>(0, 0, Float(TileGeometry.size), Float(TileGeometry.size))

    func drawQuad(_ encoder: MTLRenderCommandEncoder, rect: SIMD4<Float>,
                  uvRect: SIMD4<Float> = SIMD4(0, 0, 1, 1), targetSize: SIMD2<Float> = tileSize) {
        var quad = QuadUniforms(rect: rect, uvRect: uvRect, targetSize: targetSize)
        encoder.setVertexBytes(&quad, length: MemoryLayout<QuadUniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
    }

    /// Draws `tile` as a straight copy (the encoder must use `copy` or `thumbnail`).
    func drawTile(_ tile: Tile, rect: SIMD4<Float>, uvRect: SIMD4<Float> = SIMD4(0, 0, 1, 1),
                  targetSize: SIMD2<Float> = tileSize, encoder: MTLRenderCommandEncoder) {
        encoder.setFragmentTexture(texture(for: tile), index: 0)
        drawQuad(encoder, rect: rect, uvRect: uvRect, targetSize: targetSize)
    }
}

extension MetalContext {
    private static let pipelineCache = PipelineCache()

    /// Shared tile pipelines for this context (built once).
    func tilePipelines() throws -> TilePipelines {
        try Self.pipelineCache.get(for: self)
    }
}

private final class PipelineCache: @unchecked Sendable {
    private let lock = NSLock()
    private var pipelines: [ObjectIdentifier: TilePipelines] = [:]

    func get(for context: MetalContext) throws -> TilePipelines {
        try lock.withLock {
            if let p = pipelines[ObjectIdentifier(context)] { return p }
            let p = try TilePipelines(context: context)
            pipelines[ObjectIdentifier(context)] = p
            return p
        }
    }
}

// MARK: Regions

/// Assembling tile grids into one texture and splitting textures back into tiles.
enum RegionOps {
    static func makeTexture(_ device: MTLDevice, width: Int, height: Int,
                            format: MTLPixelFormat = TileGeometry.pixelFormat,
                            usage: MTLTextureUsage = [.renderTarget, .shaderRead, .shaderWrite],
                            mipmapped: Bool = false) throws -> MTLTexture {
        guard width > 0, height > 0, width <= 16384, height <= 16384 else {
            throw RenderError.resourceCreationFailed("region \(width)×\(height) is too large")
        }
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: width, height: height, mipmapped: mipmapped)
        d.usage = usage
        d.storageMode = .private
        guard let t = device.makeTexture(descriptor: d) else {
            throw RenderError.resourceCreationFailed("region texture")
        }
        return t
    }

    /// Draws every tile of `grid` overlapping `region` into a new texture.
    static func assemble(_ grid: TileGrid, region: PixelRect, clearValue: Float = 0,
                         pipelines: TilePipelines, commandBuffer: MTLCommandBuffer,
                         mipmapped: Bool = false) throws -> MTLTexture {
        let texture = try makeTexture(pipelines.context.device, width: region.width, height: region.height,
                                      mipmapped: mipmapped)
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = .clear
        let c = Double(clearValue)
        pass.colorAttachments[0].clearColor = MTLClearColor(red: c, green: c, blue: c, alpha: c)
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else {
            throw RenderError.resourceCreationFailed("assemble encoder")
        }
        encoder.setRenderPipelineState(pipelines.copy)
        let size = SIMD2<Float>(Float(region.width), Float(region.height))
        let s = Float(TileGeometry.size)
        for coord in region.tileCoords {
            guard let tile = grid[coord] else { continue }
            pipelines.drawTile(tile, rect: SIMD4(Float(coord.rect.x - region.x), Float(coord.rect.y - region.y), s, s),
                               targetSize: size, encoder: encoder)
        }
        encoder.endEncoding()
        return texture
    }

    /// Copies a tile-aligned `region` texture into new tiles.
    static func split(_ texture: MTLTexture, region: PixelRect, device: MTLDevice,
                      commandBuffer: MTLCommandBuffer) -> TileGrid {
        var grid = TileGrid()
        guard let blit = commandBuffer.makeBlitCommandEncoder() else { return grid }
        let s = TileGeometry.size
        for coord in region.tileCoords {
            let tile = TileTexture.makeTexture(device: device)
            blit.copy(from: texture, sourceSlice: 0, sourceLevel: 0,
                      sourceOrigin: MTLOrigin(x: coord.rect.x - region.x, y: coord.rect.y - region.y, z: 0),
                      sourceSize: MTLSize(width: s, height: s, depth: 1),
                      to: tile, destinationSlice: 0, destinationLevel: 0, destinationOrigin: MTLOrigin())
            grid[coord] = .texture(TileTexture(tile))
        }
        blit.endEncoding()
        return grid
    }

    /// Expands a rect outward to whole tiles.
    static func tileAligned(_ r: PixelRect) -> PixelRect {
        let s = TileGeometry.size
        let x0 = PixelRect.floorDiv(r.x, s) * s, y0 = PixelRect.floorDiv(r.y, s) * s
        let x1 = (PixelRect.floorDiv(r.maxX - 1, s) + 1) * s, y1 = (PixelRect.floorDiv(r.maxY - 1, s) + 1) * s
        return PixelRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }

    static func expand(_ r: PixelRect, by n: Int) -> PixelRect {
        PixelRect(x: r.x - n, y: r.y - n, width: r.width + 2 * n, height: r.height + 2 * n)
    }
}
