import Foundation
import GlimmerCore
import Metal

/// Mirrors `LiquifyBrush` in Filters.metal.
struct LiquifyBrushUniforms {
    var centre: SIMD2<Float>
    var delta: SIMD2<Float>
    var fieldOrigin: SIMD2<Float>
    var fieldScale: Float
    var radius: Float
    var strength: Float
    var mode: Int32
    var boxOrigin: SIMD2<Int32>
}

/// Liquify on one raster layer: a displacement field edited by brushes and
/// rendered on demand. Large layers use a coarser field (bilinear) to stay light.
public final class LiquifyEngine {
    public enum Mode: Int32, CaseIterable, Sendable {
        case forward = 0, restore, pucker, bloat, twirlClockwise, twirlCounterClockwise

        public var title: String {
            switch self {
            case .forward: "Forward Warp"
            case .restore: "Reconstruct"
            case .pucker: "Pucker"
            case .bloat: "Bloat"
            case .twirlClockwise: "Twirl Clockwise"
            case .twirlCounterClockwise: "Twirl Counter-clockwise"
            }
        }
    }

    public let original: TileGrid
    public let region: PixelRect
    private let context: MetalContext
    private let pipelines: TilePipelines
    private let brushPipeline: MTLComputePipelineState
    private let renderPipeline: MTLComputePipelineState
    private let source: MTLTexture
    private var field: MTLTexture
    private var scratch: MTLTexture
    private let fieldScale: Float
    public private(set) var isIdentity = true

    /// `region`: the area that can change (usually the document).
    public init(context: MetalContext, tiles: TileGrid, region: PixelRect) throws {
        self.context = context
        self.original = tiles
        self.region = RegionOps.tileAligned(region)
        pipelines = try context.tilePipelines()
        func compute(_ name: String) throws -> MTLComputePipelineState {
            guard let f = context.library.makeFunction(name: name) else { throw RenderError.libraryUnavailable(name) }
            return try context.device.makeComputePipelineState(function: f)
        }
        brushPipeline = try compute("liquify_brush")
        renderPipeline = try compute("liquify_render")
        let longSide = max(self.region.width, self.region.height)
        fieldScale = longSide > 4096 ? Float((longSide + 4095) / 4096) : 1
        let fw = Int((Float(self.region.width) / fieldScale).rounded(.up)), fh = Int((Float(self.region.height) / fieldScale).rounded(.up))
        field = try RegionOps.makeTexture(context.device, width: fw, height: fh, format: .rg32Float)
        scratch = try RegionOps.makeTexture(context.device, width: fw, height: fh, format: .rg32Float)
        guard let cb = context.commandQueue.makeCommandBuffer() else { throw RenderError.resourceCreationFailed("liquify") }
        source = try RegionOps.assemble(tiles, region: self.region, pipelines: pipelines, commandBuffer: cb)
        for t in [field, scratch] {
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = t
            pass.colorAttachments[0].loadAction = .clear
            pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
            pass.colorAttachments[0].storeAction = .store
            cb.makeRenderCommandEncoder(descriptor: pass)?.endEncoding()
        }
        cb.commit()
    }

    /// One brush dab (document coordinates).
    public func dab(_ mode: Mode, at centre: SIMD2<Double>, delta: SIMD2<Double>, radius: Double, strength: Double) {
        guard let cb = context.commandQueue.makeCommandBuffer() else { return }
        let s = Double(fieldScale)
        let fx0 = Int(((centre.x - radius - Double(region.x)) / s).rounded(.down)) - 1
        let fy0 = Int(((centre.y - radius - Double(region.y)) / s).rounded(.down)) - 1
        let size = Int((2 * radius / s).rounded(.up)) + 3
        let box = PixelRect(x: fx0, y: fy0, width: size, height: size)
            .intersection(PixelRect(x: 0, y: 0, width: field.width, height: field.height))
        guard !box.isEmpty, let e = cb.makeComputeCommandEncoder() else { return }
        var u = LiquifyBrushUniforms(centre: SIMD2(Float(centre.x), Float(centre.y)), delta: SIMD2(Float(delta.x), Float(delta.y)),
                                     fieldOrigin: SIMD2(Float(region.x), Float(region.y)), fieldScale: fieldScale,
                                     radius: Float(radius), strength: Float(strength), mode: mode.rawValue,
                                     boxOrigin: SIMD2(Int32(box.x), Int32(box.y)))
        e.setComputePipelineState(brushPipeline)
        e.setTexture(field, index: 0)
        e.setTexture(scratch, index: 1)
        e.setBytes(&u, length: MemoryLayout<LiquifyBrushUniforms>.stride, index: 0)
        e.dispatchThreads(MTLSize(width: box.width, height: box.height, depth: 1),
                          threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
        e.endEncoding()
        if let blit = cb.makeBlitCommandEncoder() {
            blit.copy(from: scratch, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: box.x, y: box.y, z: 0),
                      sourceSize: MTLSize(width: box.width, height: box.height, depth: 1),
                      to: field, destinationSlice: 0, destinationLevel: 0, destinationOrigin: MTLOrigin(x: box.x, y: box.y, z: 0))
            blit.endEncoding()
        }
        cb.commit()
        isIdentity = false
    }

    /// The warped layer (tiles outside `region` are untouched).
    public func render() throws -> TileGrid {
        guard !isIdentity else { return original }
        guard let cb = context.commandQueue.makeCommandBuffer(), let e = cb.makeComputeCommandEncoder() else {
            throw RenderError.resourceCreationFailed("liquify render")
        }
        let out = try RegionOps.makeTexture(context.device, width: region.width, height: region.height)
        var geometry = SIMD4<Float>(Float(region.x), Float(region.y), Float(region.x), Float(region.y))
        var scale = fieldScale
        e.setComputePipelineState(renderPipeline)
        e.setTexture(source, index: 0)
        e.setTexture(field, index: 1)
        e.setTexture(out, index: 2)
        e.setBytes(&geometry, length: 16, index: 0)
        e.setBytes(&scale, length: 4, index: 1)
        e.dispatchThreads(MTLSize(width: region.width, height: region.height, depth: 1),
                          threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
        e.endEncoding()
        let tiles = RegionOps.split(out, region: region, device: context.device, commandBuffer: cb)
        cb.commit()
        cb.waitUntilCompleted()
        if let error = cb.error { throw error }
        var result = original
        for (c, t) in tiles.tiles { result[c] = t }
        return result
    }
}
