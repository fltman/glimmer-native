import Foundation
import GlimmerCore
import Metal
import MetalPerformanceShaders

/// Mirrors `LensBlurUniforms` in Composite.metal.
struct LensBlurUniforms {
    var focus: Float
    var maxRadius: Float
    var bokeh: Float
    var size: Float
}

/// Whole-document GPU effects that produce new pixels: depth lens blur and
/// high-quality upscaling. Work in linear Float16, so no 8-bit round trips.
public enum DocumentEffects {
    public struct LensBlurParameters: Sendable, Equatable {
        /// 0 = far … 1 = near.
        public var focus: Double
        /// Fraction of the long side used as the maximum blur radius.
        public var amount: Double
        /// Highlight boost for bokeh shapes, 0...1.
        public var bokeh: Double
        /// Depth range that stays sharp, 0...1.
        public var focusRange: Double

        public init(focus: Double = 0.8, amount: Double = 0.02, bokeh: Double = 0.4, focusRange: Double = 0.1) {
            self.focus = focus
            self.amount = amount
            self.bokeh = bokeh
            self.focusRange = focusRange
        }
    }

    /// The flattened document as a linear premultiplied texture (document size).
    static func compositeTexture(_ state: DocumentState, context: MetalContext) throws -> MTLTexture {
        let compositor = try DocumentCompositor(context: context)
        let (buffer, bytesPerRow, rect) = try compositor.renderPixels(state)
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: TileGeometry.pixelFormat,
                                                         width: rect.width, height: rect.height, mipmapped: false)
        d.usage = [.shaderRead, .shaderWrite]
        d.storageMode = .shared
        guard let t = context.device.makeTexture(descriptor: d) else { throw RenderError.resourceCreationFailed("composite") }
        t.replace(region: MTLRegionMake2D(0, 0, rect.width, rect.height), mipmapLevel: 0,
                  withBytes: buffer.contents(), bytesPerRow: bytesPerRow)
        return t
    }

    /// Depth-driven lens blur of the whole document. `depth` is document-sized, 0...1, near = 1.
    public static func lensBlur(_ state: DocumentState, depth: [Float], parameters p: LensBlurParameters,
                                context: MetalContext) throws -> TileGrid {
        let color = try compositeTexture(state, context: context)
        let w = state.width, h = state.height
        let dd = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r32Float, width: w, height: h, mipmapped: false)
        dd.usage = .shaderRead
        dd.storageMode = .shared
        guard let depthTex = context.device.makeTexture(descriptor: dd) else { throw RenderError.resourceCreationFailed("depth") }
        depth.withUnsafeBytes {
            depthTex.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: w * 4)
        }
        let out = try RegionOps.makeTexture(context.device, width: w, height: h)
        let pipelines = try context.tilePipelines()
        guard let fn = context.library.makeFunction(name: "lens_blur"),
              let cb = context.commandQueue.makeCommandBuffer(), let e = cb.makeComputeCommandEncoder() else {
            throw RenderError.libraryUnavailable("lens_blur")
        }
        let pipeline = try context.device.makeComputePipelineState(function: fn)
        var u = LensBlurUniforms(focus: Float(p.focus), maxRadius: Float(p.amount * Double(max(w, h))),
                                 bokeh: Float(p.bokeh), size: Float(p.focusRange))
        e.setComputePipelineState(pipeline)
        e.setTexture(color, index: 0)
        e.setTexture(depthTex, index: 1)
        e.setTexture(out, index: 2)
        e.setBytes(&u, length: MemoryLayout<LensBlurUniforms>.stride, index: 0)
        e.dispatchThreads(MTLSize(width: w, height: h, depth: 1),
                          threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
        e.endEncoding()
        let grid = splitPartial(out, pipelines: pipelines, commandBuffer: cb)
        cb.commit()
        cb.waitUntilCompleted()
        if let error = cb.error { throw error }
        return grid
    }

    /// Lanczos-upscaled document composite (`scale`×), as tiles of the new size.
    public static func upscale(_ state: DocumentState, scale: Int, context: MetalContext) throws -> TileGrid {
        let color = try compositeTexture(state, context: context)
        let w = state.width * scale, h = state.height * scale
        let out = try RegionOps.makeTexture(context.device, width: w, height: h)
        guard let cb = context.commandQueue.makeCommandBuffer() else { throw RenderError.resourceCreationFailed("upscale") }
        let lanczos = MPSImageLanczosScale(device: context.device)
        lanczos.edgeMode = .clamp  // the default (.zero) fades the last rows/columns
        lanczos.encode(commandBuffer: cb, sourceTexture: color, destinationTexture: out)
        let grid = splitPartial(out, pipelines: try context.tilePipelines(), commandBuffer: cb)
        cb.commit()
        cb.waitUntilCompleted()
        if let error = cb.error { throw error }
        return grid
    }

    /// Splits a texture with its top-left at the document origin into tiles;
    /// edge tiles are cleared before the partial copy.
    static func splitPartial(_ texture: MTLTexture, pipelines: TilePipelines, commandBuffer cb: MTLCommandBuffer) -> TileGrid {
        let bounds = PixelRect(x: 0, y: 0, width: texture.width, height: texture.height)
        var grid = TileGrid()
        var partial: [(TileCoord, MTLTexture)] = []
        for coord in bounds.tileCoords {
            let tile = TileTexture.makeTexture(device: pipelines.context.device)
            grid[coord] = .texture(TileTexture(tile))
            if coord.rect.maxX > bounds.maxX || coord.rect.maxY > bounds.maxY { partial.append((coord, tile)) }
        }
        for (_, tile) in partial {
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = tile
            pass.colorAttachments[0].loadAction = .clear
            pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
            pass.colorAttachments[0].storeAction = .store
            cb.makeRenderCommandEncoder(descriptor: pass)?.endEncoding()
        }
        guard let blit = cb.makeBlitCommandEncoder() else { return grid }
        for coord in bounds.tileCoords {
            guard case .texture(let t)? = grid[coord] else { continue }
            let part = coord.rect.intersection(bounds)
            blit.copy(from: texture, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: part.x, y: part.y, z: 0),
                      sourceSize: MTLSize(width: part.width, height: part.height, depth: 1),
                      to: t.texture, destinationSlice: 0, destinationLevel: 0, destinationOrigin: MTLOrigin())
        }
        blit.endEncoding()
        return grid
    }
}
