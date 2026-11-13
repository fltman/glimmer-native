import Foundation
import GlimmerCore
import Metal
import MetalPerformanceShaders
import simd

/// A rendered effect: premultiplied colour tiles composited with `mode`.
struct EffectGrid {
    var grid: TileGrid
    var mode: BlendMode
}

/// Mirrors `EffectColorUniforms` in Composite.metal.
struct EffectColorUniforms {
    var color: SIMD4<Float>
    var stroke: SIMD4<Float>
}

/// Renders layer styles (shadows, glow, stroke) from a layer's masked alpha.
/// These need pixels around each tile, so they work on an assembled region.
final class LayerStyleRenderer {
    struct Rendered {
        var below: [EffectGrid] = []
        var above: [EffectGrid] = []
    }

    private let pipelines: TilePipelines
    private var device: MTLDevice { pipelines.context.device }

    init(pipelines: TilePipelines) {
        self.pipelines = pipelines
    }

    func render(pixels: TileGrid, mask: ResolvedMask?, effects: LayerEffects, limit: PixelRect) throws -> Rendered {
        guard effects.hasSpatialEffects, let content = pixels.tileBounds else { return Rendered() }
        let region = RegionOps.tileAligned(RegionOps.expand(content, by: effects.reach).intersection(limit))
        guard !region.isEmpty, region.width <= 16384, region.height <= 16384 else { return Rendered() }

        guard let cb = pipelines.context.commandQueue.makeCommandBuffer() else {
            throw RenderError.resourceCreationFailed("effects command buffer")
        }
        cb.label = "Layer styles"
        let pix = try RegionOps.assemble(pixels, region: region, pipelines: pipelines, commandBuffer: cb)
        let maskTex = try RegionOps.assemble(mask?.tiles ?? TileGrid(), region: region,
                                             clearValue: mask?.defaultValue ?? 1,
                                             pipelines: pipelines, commandBuffer: cb)
        // Effects follow the mask's shape; mask density is not applied to them.

        var result = Rendered()
        func field() throws -> MTLTexture {
            try RegionOps.makeTexture(device, width: region.width, height: region.height, format: .r32Float)
        }
        func colorize(_ a: MTLTexture, _ b: MTLTexture? = nil, color: SRGBColor, opacity: Double,
                      stroke: SIMD4<Float> = .zero) throws -> TileGrid {
            let out = try RegionOps.makeTexture(device, width: region.width, height: region.height)
            var u = EffectColorUniforms(color: SIMD4(color.linear, Float(opacity)), stroke: stroke)
            dispatch(pipelines.effectColorize, cb, size: region) { e in
                e.setTexture(a, index: 0)
                e.setTexture(b ?? a, index: 1)
                e.setTexture(pix, index: 2)
                e.setTexture(maskTex, index: 3)
                e.setTexture(out, index: 4)
                e.setBytes(&u, length: MemoryLayout<EffectColorUniforms>.stride, index: 0)
            }
            return RegionOps.split(out, region: region, device: device, commandBuffer: cb)
        }
        func alpha(offset: SIMD2<Double>, spread: Double, invert: Bool) throws -> MTLTexture {
            let out = try field()
            var p = SIMD4<Float>(Float(offset.x), Float(offset.y), Float(spread), invert ? 1 : 0)
            dispatch(pipelines.effectAlpha, cb, size: region) { e in
                e.setTexture(pix, index: 0)
                e.setTexture(maskTex, index: 1)
                e.setTexture(out, index: 2)
                e.setBytes(&p, length: 16, index: 0)
            }
            return out
        }
        func blurred(_ t: MTLTexture, size: Double) throws -> MTLTexture {
            guard size > 0.5 else { return t }
            let out = try field()
            let blur = MPSImageGaussianBlur(device: device, sigma: Float(size / 2))
            blur.edgeMode = .clamp
            blur.encode(commandBuffer: cb, sourceTexture: t, destinationTexture: out)
            return out
        }

        if let s = effects.dropShadow, s.isEnabled {
            let a = try blurred(try alpha(offset: s.offset, spread: s.spread, invert: false), size: s.size)
            result.below.append(EffectGrid(grid: try colorize(a, color: s.color, opacity: s.opacity), mode: s.blendMode))
        }
        if let g = effects.outerGlow, g.isEnabled {
            let a = try blurred(try alpha(offset: .zero, spread: g.spread, invert: false), size: g.size)
            result.below.append(EffectGrid(grid: try colorize(a, color: g.color, opacity: g.opacity), mode: g.blendMode))
        }
        if let s = effects.innerShadow, s.isEnabled {
            let a = try blurred(try alpha(offset: s.offset, spread: s.spread, invert: true), size: s.size)
            result.above.append(EffectGrid(grid: try colorize(a, color: s.color, opacity: s.opacity,
                                                               stroke: SIMD4(0, 0, 2, 0)), mode: s.blendMode))
        }
        if let st = effects.stroke, st.isEnabled, st.width > 0 {
            func distance(invert: Bool) throws -> MTLTexture {
                let binary = try field()
                var inv: Float = invert ? 1 : 0
                dispatch(pipelines.effectBinary, cb, size: region) { e in
                    e.setTexture(pix, index: 0)
                    e.setTexture(maskTex, index: 1)
                    e.setTexture(binary, index: 2)
                    e.setBytes(&inv, length: 4, index: 0)
                }
                let out = try field()
                MPSImageEuclideanDistanceTransform(device: device)
                    .encode(commandBuffer: cb, sourceTexture: binary, destinationTexture: out)
                return out
            }
            let position: Float = switch st.position {
            case .outside: 0
            case .inside: 1
            case .center: 2
            }
            let grid = try colorize(try distance(invert: false), try distance(invert: true),
                                    color: st.color, opacity: st.opacity,
                                    stroke: SIMD4(Float(st.width), position, 1, 0))
            result.above.append(EffectGrid(grid: grid, mode: st.blendMode))
        }

        cb.commit()
        cb.waitUntilCompleted()
        if let error = cb.error { throw error }
        return result
    }

    private func dispatch(_ pipeline: MTLComputePipelineState, _ cb: MTLCommandBuffer, size: PixelRect,
                          _ bind: (MTLComputeCommandEncoder) -> Void) {
        guard let e = cb.makeComputeCommandEncoder() else { return }
        e.setComputePipelineState(pipeline)
        bind(e)
        let w = pipeline.threadExecutionWidth
        let h = max(1, pipeline.maxTotalThreadsPerThreadgroup / w)
        e.dispatchThreads(MTLSize(width: size.width, height: size.height, depth: 1),
                          threadsPerThreadgroup: MTLSize(width: w, height: h, depth: 1))
        e.endEncoding()
    }
}

/// Non-destructive mask feather: a Gaussian blur of the mask's stored tiles.
final class MaskFeatherRenderer {
    private let pipelines: TilePipelines

    init(pipelines: TilePipelines) {
        self.pipelines = pipelines
    }

    func feather(_ mask: LayerMask, limit: PixelRect) throws -> TileGrid {
        guard mask.feather > 0.25, let stored = mask.tiles.tileBounds else { return mask.tiles }
        let reach = Int((mask.feather * 3).rounded(.up))
        let region = RegionOps.tileAligned(RegionOps.expand(stored, by: reach).intersection(limit))
        guard !region.isEmpty else { return mask.tiles }
        guard let cb = pipelines.context.commandQueue.makeCommandBuffer() else { return mask.tiles }
        let src = try RegionOps.assemble(mask.tiles, region: region, clearValue: mask.defaultValue,
                                         pipelines: pipelines, commandBuffer: cb)
        let dst = try RegionOps.makeTexture(pipelines.context.device, width: region.width, height: region.height)
        let blur = MPSImageGaussianBlur(device: pipelines.context.device, sigma: Float(mask.feather))
        blur.edgeMode = .clamp
        blur.encode(commandBuffer: cb, sourceTexture: src, destinationTexture: dst)
        let grid = RegionOps.split(dst, region: region, device: pipelines.context.device, commandBuffer: cb)
        cb.commit()
        cb.waitUntilCompleted()
        if let error = cb.error { throw error }
        return grid
    }
}

/// Mirrors `SmartUniforms` in Composite.metal.
struct SmartUniforms {
    var sourceToClip: simd_float3x3
    var sourceSize: SIMD2<Float>
}

/// Renders a smart object's source through its transform into document tiles.
final class SmartObjectRenderer {
    private let pipelines: TilePipelines
    private var sources: [Int: MTLTexture] = [:]

    init(pipelines: TilePipelines) {
        self.pipelines = pipelines
    }

    func render(_ smart: SmartObject, limit: PixelRect) throws -> TileGrid {
        let region = RegionOps.tileAligned(smart.bounds.intersection(limit))
        guard !region.isEmpty, smart.width > 0, smart.height > 0 else { return TileGrid() }
        guard let cb = pipelines.context.commandQueue.makeCommandBuffer() else { return TileGrid() }
        cb.label = "Smart object"

        let key = smart.source.contentSignature
        let source: MTLTexture
        if let cached = sources[key] {
            source = cached
        } else {
            if sources.count > 8 { sources.removeAll() }
            source = try RegionOps.assemble(smart.source, region: PixelRect(x: 0, y: 0, width: smart.width, height: smart.height),
                                            pipelines: pipelines, commandBuffer: cb, mipmapped: true)
            if let blit = cb.makeBlitCommandEncoder() {
                blit.generateMipmaps(for: source)
                blit.endEncoding()
            }
            sources[key] = source
        }

        var grid = TileGrid()
        let t = smart.transform
        let srcToDoc = simd_double3x3(columns: (SIMD3(t.a, t.b, 0), SIMD3(t.c, t.d, 0), SIMD3(t.tx, t.ty, 1)))
        let s = Double(TileGeometry.size)
        for coord in region.tileCoords {
            let o = SIMD2(Double(coord.rect.x), Double(coord.rect.y))
            let docToClip = simd_double3x3(columns: (SIMD3(2 / s, 0, 0), SIMD3(0, -2 / s, 0),
                                                     SIMD3(-2 * o.x / s - 1, 2 * o.y / s + 1, 1)))
            let m = docToClip * srcToDoc
            let texture = TileTexture.makeTexture(device: pipelines.context.device)
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = texture
            pass.colorAttachments[0].loadAction = .clear
            pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
            pass.colorAttachments[0].storeAction = .store
            guard let e = cb.makeRenderCommandEncoder(descriptor: pass) else { continue }
            e.setRenderPipelineState(pipelines.smart)
            var u = SmartUniforms(sourceToClip: CanvasRenderer.float3x3(m),
                                  sourceSize: SIMD2(Float(smart.width), Float(smart.height)))
            e.setVertexBytes(&u, length: MemoryLayout<SmartUniforms>.stride, index: 0)
            e.setFragmentTexture(source, index: 0)
            e.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            e.endEncoding()
            grid[coord] = .texture(TileTexture(texture))
        }
        cb.commit()
        cb.waitUntilCompleted()
        if let error = cb.error { throw error }
        return grid
    }
}

