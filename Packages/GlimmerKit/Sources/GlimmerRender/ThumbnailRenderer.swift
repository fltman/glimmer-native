import CoreGraphics
import Foundation
import GlimmerCore
import Metal

/// Renders small previews of layers for the Layers panel.
public final class ThumbnailRenderer {
    private let context: MetalContext
    private let pipelines: TilePipelines

    public init(context: MetalContext) throws {
        self.context = context
        self.pipelines = try context.tilePipelines()
    }

    /// A preview of `grid`, clipped to `documentBounds`, at most `maxPixels` on its long side.
    public func thumbnail(of grid: TileGrid, documentBounds: PixelRect, maxPixels: Int) -> CGImage? {
        guard !documentBounds.isEmpty, maxPixels > 0 else { return nil }
        let scale = Double(maxPixels) / Double(max(documentBounds.width, documentBounds.height))
        let w = max(1, Int((Double(documentBounds.width) * scale).rounded()))
        let h = max(1, Int((Double(documentBounds.height) * scale).rounded()))

        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: TileGeometry.pixelFormat,
                                                         width: w, height: h, mipmapped: false)
        d.usage = [.renderTarget, .shaderRead]
        d.storageMode = .shared
        guard let target = context.device.makeTexture(descriptor: d),
              let cb = context.commandQueue.makeCommandBuffer() else { return nil }

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = cb.makeRenderCommandEncoder(descriptor: pass) else { return nil }
        encoder.setRenderPipelineState(pipelines.thumbnail)

        let size = SIMD2<Float>(Float(w), Float(h))
        let s = Double(TileGeometry.size)
        for coord in documentBounds.tileCoords {
            guard let tile = grid[coord] else { continue }
            let r = coord.rect.intersection(documentBounds)
            let u0 = Double(r.x - coord.rect.x) / s, v0 = Double(r.y - coord.rect.y) / s
            let rect = SIMD4<Float>(Float(Double(r.x - documentBounds.x) * scale),
                                    Float(Double(r.y - documentBounds.y) * scale),
                                    Float(Double(r.width) * scale), Float(Double(r.height) * scale))
            let uv = SIMD4<Float>(Float(u0), Float(v0),
                                  Float(u0 + Double(r.width) / s), Float(v0 + Double(r.height) / s))
            pipelines.draw(tile, rect: rect, uvRect: uv, targetSize: size,
                           source: SourceUniforms(), encoder: encoder)
        }
        encoder.endEncoding()
        cb.commit()
        cb.waitUntilCompleted()

        let bytesPerRow = w * TileGeometry.bytesPerPixel
        var bytes = Data(count: bytesPerRow * h)
        bytes.withUnsafeMutableBytes { buffer in
            target.getBytes(buffer.baseAddress!, bytesPerRow: bytesPerRow,
                            from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
        }
        guard let provider = CGDataProvider(data: bytes as CFData) else { return nil }
        return CGImage(width: w, height: h, bitsPerComponent: 16, bitsPerPixel: 64, bytesPerRow: bytesPerRow,
                       space: ImageImporter.workingColorSpace,
                       bitmapInfo: CGBitmapInfo(rawValue: CGBitmapInfo.floatComponents.rawValue
                           | CGBitmapInfo.byteOrder16Little.rawValue
                           | CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}
