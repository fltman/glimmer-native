import Foundation
import GlimmerCore
import Metal

/// Mirrors `ApplyUniforms` in Composite.metal.
struct ApplyUniforms {
    var color: SIMD4<Float>
    var mode: Int32
    var opacity: Float
    var maskTarget: Float
    var pad: Float = 0
}

/// GPU pixel operations producing new tiles (originals are never written).
public final class PixelOps {
    public enum Mode: Int32, Sendable {
        /// Paint `color` with coverage × opacity.
        case paint = 0
        /// Erase alpha with coverage × opacity.
        case erase = 1
        /// Move a mask value toward `maskTarget`.
        case mask = 2
        /// Keep only the selected part (multiply by the selection).
        case keepSelected = 3
        /// Blend toward a precomputed effect (clone, heal, blur, sharpen tools).
        case towardEffect = 4
        /// Dodge / burn: `color.x` exposure, `color.y` range (0 shadows, 1 midtones, 2 highlights).
        case dodge = 5
        case burn = 6
    }

    let context: MetalContext
    let pipelines: TilePipelines
    let apply: MTLRenderPipelineState
    let dab: MTLRenderPipelineState

    public init(context: MetalContext) throws {
        self.context = context
        self.pipelines = try context.tilePipelines()
        let library = context.library
        let a = MTLRenderPipelineDescriptor()
        a.vertexFunction = library.makeFunction(name: "tile_quad_vertex")
        a.fragmentFunction = library.makeFunction(name: "pixel_apply_fragment")
        a.colorAttachments[0].pixelFormat = TileGeometry.pixelFormat
        let d = MTLRenderPipelineDescriptor()
        d.vertexFunction = library.makeFunction(name: "dab_vertex")
        d.fragmentFunction = library.makeFunction(name: "dab_fragment")
        let c = d.colorAttachments[0]!
        c.pixelFormat = TileGeometry.pixelFormat
        c.isBlendingEnabled = true
        c.sourceRGBBlendFactor = .one
        c.sourceAlphaBlendFactor = .one
        c.destinationRGBBlendFactor = .oneMinusSourceAlpha
        c.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        guard a.fragmentFunction != nil, d.vertexFunction != nil else {
            throw RenderError.libraryUnavailable("pixel ops shaders")
        }
        apply = try context.device.makeRenderPipelineState(descriptor: a)
        dab = try context.device.makeRenderPipelineState(descriptor: d)
    }

    /// Applies `mode` on `coords`, returning the new tiles (nil = became empty).
    /// - Parameters:
    ///   - source: the tiles being edited; `sourceDefault` fills missing ones (masks).
    ///   - coverage: per-tile coverage (R); missing = full coverage when `fullCoverage`.
    func encode(coords: [TileCoord], source: TileGrid, sourceDefault: Float?, coverage: [TileCoord: MTLTexture],
                fullCoverage: Bool, selection: Selection?, mode: Mode, color: SIMD4<Float>, opacity: Float,
                maskTarget: Float, effect: TileGrid? = nil, commandBuffer: MTLCommandBuffer) -> [TileCoord: Tile] {
        var out: [TileCoord: Tile] = [:]
        for coord in coords {
            guard let texture = TileTexture.makeTextureOrNote(device: context.device) else { continue }   // no memory: this tile is left as it was
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = texture
            pass.colorAttachments[0].loadAction = .dontCare
            pass.colorAttachments[0].storeAction = .store
            guard let e = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { continue }
            e.setRenderPipelineState(apply)
            let original = source[coord] ?? sourceDefault.map { .solid(SIMD4(repeating: $0)) } ?? .solid(.zero)
            e.setFragmentTexture(pipelines.texture(for: original), index: 0)
            e.setFragmentTexture(coverage[coord] ?? (fullCoverage ? pipelines.white : pipelines.clear), index: 1)
            e.setFragmentTexture(selection.map { pipelines.texture(for: $0.tile(at: coord)) } ?? pipelines.white, index: 2)
            e.setFragmentTexture(pipelines.texture(for: effect?[coord] ?? original), index: 3)
            var u = ApplyUniforms(color: color, mode: mode.rawValue, opacity: opacity, maskTarget: maskTarget)
            e.setFragmentBytes(&u, length: MemoryLayout<ApplyUniforms>.stride, index: 0)
            pipelines.drawQuad(e, rect: TilePipelines.fullTile)
            e.endEncoding()
            out[coord] = .texture(TileTexture(texture))
        }
        return out
    }

    /// One-shot operation over the selected area (or `region`), e.g. clear, keep-selected, fill.
    public func run(_ mode: Mode, on source: TileGrid, sourceDefault: Float? = nil, selection: Selection?,
                    coords: [TileCoord], coverage: [TileCoord: MTLTexture] = [:], fullCoverage: Bool = true,
                    color: SIMD4<Float> = .zero, opacity: Float = 1, maskTarget: Float = 0) throws -> TileGrid {
        guard let cb = context.commandQueue.makeCommandBuffer() else { throw RenderError.resourceCreationFailed("pixel ops") }
        let tiles = encode(coords: coords, source: source, sourceDefault: sourceDefault, coverage: coverage,
                           fullCoverage: fullCoverage, selection: selection, mode: mode, color: color,
                           opacity: opacity, maskTarget: maskTarget, commandBuffer: cb)
        cb.commit()
        cb.waitUntilCompleted()
        if let error = cb.error { throw error }
        var result = source
        for (c, t) in tiles { result[c] = t }
        return result
    }

    /// Coverage textures from a selection-like grid (e.g. a flood-fill mask), for `run`.
    public func coverage(from selection: Selection, coords: [TileCoord]) -> [TileCoord: MTLTexture] {
        var out: [TileCoord: MTLTexture] = [:]
        for c in coords { out[c] = pipelines.texture(for: selection.tile(at: c)) }
        return out
    }
}
