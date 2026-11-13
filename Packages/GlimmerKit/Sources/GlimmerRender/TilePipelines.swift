import Foundation
import GlimmerCore
import Metal

/// Mirrors `QuadUniforms` in Tiles.metal.
struct QuadUniforms {
    var rect: SIMD4<Float>
    var uvRect: SIMD4<Float>
    var targetSize: SIMD2<Float>
}

/// Mirrors `SourceUniforms` in Tiles.metal.
struct SourceUniforms {
    var solidColor: SIMD4<Float> = .zero
    var isSolid: Int32 = 0
    var mode: Int32 = 0
    var opacity: Float = 1
    var gammaSpace: Int32 = 0
}

/// Pipeline states for drawing tiles into tiles.
final class TilePipelines: @unchecked Sendable {
    let context: MetalContext
    let blend: MTLRenderPipelineState
    let copy: MTLRenderPipelineState
    let thumbnail: MTLRenderPipelineState
    /// Bound in place of a texture for solid tiles.
    let placeholder: MTLTexture

    init(context: MetalContext) throws {
        self.context = context
        let library = context.library

        func make(_ fragment: String, label: String, configure: (MTLRenderPipelineColorAttachmentDescriptor) -> Void = { _ in }) throws -> MTLRenderPipelineState {
            let d = MTLRenderPipelineDescriptor()
            d.label = label
            d.vertexFunction = library.makeFunction(name: "tile_quad_vertex")
            d.fragmentFunction = library.makeFunction(name: fragment)
            guard d.vertexFunction != nil, d.fragmentFunction != nil else {
                throw RenderError.libraryUnavailable("missing \(fragment)")
            }
            d.colorAttachments[0].pixelFormat = TileGeometry.pixelFormat
            configure(d.colorAttachments[0])
            return try context.device.makeRenderPipelineState(descriptor: d)
        }

        blend = try make("composite_blend_fragment", label: "Composite blend")
        copy = try make("tile_copy_fragment", label: "Tile copy")
        thumbnail = try make("thumbnail_fragment", label: "Thumbnail") { a in
            a.isBlendingEnabled = true
            a.sourceRGBBlendFactor = .one
            a.sourceAlphaBlendFactor = .one
            a.destinationRGBBlendFactor = .oneMinusSourceAlpha
            a.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        }

        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: TileGeometry.pixelFormat, width: 1, height: 1, mipmapped: false)
        desc.usage = .shaderRead
        guard let placeholder = context.device.makeTexture(descriptor: desc) else {
            throw RenderError.resourceCreationFailed("placeholder texture")
        }
        self.placeholder = placeholder
    }

    /// Draws `tile` into the current encoder as a quad covering `rect` (target pixels).
    func draw(_ tile: Tile, rect: SIMD4<Float>, uvRect: SIMD4<Float> = SIMD4(0, 0, 1, 1),
              targetSize: SIMD2<Float>, source: SourceUniforms, encoder: MTLRenderCommandEncoder) {
        var quad = QuadUniforms(rect: rect, uvRect: uvRect, targetSize: targetSize)
        var src = source
        switch tile {
        case .solid(let color):
            src.isSolid = 1
            src.solidColor = color
            encoder.setFragmentTexture(placeholder, index: 0)
        case .texture(let t):
            src.isSolid = 0
            encoder.setFragmentTexture(t.texture, index: 0)
        }
        encoder.setVertexBytes(&quad, length: MemoryLayout<QuadUniforms>.stride, index: 0)
        encoder.setFragmentBytes(&src, length: MemoryLayout<SourceUniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
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

