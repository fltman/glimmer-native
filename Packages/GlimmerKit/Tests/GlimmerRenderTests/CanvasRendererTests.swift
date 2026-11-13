import Metal
import Testing
import simd
@testable import GlimmerRender

@Suite struct CanvasRendererTests {
    /// Renders a 32×32 frame with a 16×16 document at the origin and reads it back.
    private func renderPixels(rotation: Double = 0) throws -> (pixels: [Float16], width: Int) {
        let context = try #require(MetalContext.shared, "Metal is unavailable")
        let renderer = try CanvasRenderer(context: context)
        let width = 32

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: CanvasRenderer.pixelFormat, width: width, height: width, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .shared
        let target = try #require(context.device.makeTexture(descriptor: descriptor))

        let frame = CanvasFrame(
            viewToDocument: matrix_identity_double3x3,
            backingScale: 1,
            documentSize: SIMD2(16, 16),
            pasteboardColor: SIMD4(0.1, 0.2, 0.3, 1),
            checkerSize: 4
        )
        let commandBuffer = try #require(context.commandQueue.makeCommandBuffer())
        renderer.encode(frame, into: commandBuffer, target: target)
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        var pixels = [Float16](repeating: 0, count: width * width * 4)
        pixels.withUnsafeMutableBytes { buffer in
            target.getBytes(buffer.baseAddress!, bytesPerRow: width * 4 * MemoryLayout<Float16>.stride,
                            from: MTLRegionMake2D(0, 0, width, width), mipmapLevel: 0)
        }
        return (pixels, width)
    }

    private func pixel(_ data: (pixels: [Float16], width: Int), _ x: Int, _ y: Int) -> SIMD4<Float> {
        let i = (y * data.width + x) * 4
        return SIMD4(Float(data.pixels[i]), Float(data.pixels[i + 1]), Float(data.pixels[i + 2]), Float(data.pixels[i + 3]))
    }

    @Test func drawsCheckerInsideAndPasteboardOutside() throws {
        let data = try renderPixels()

        // Outside the document: pasteboard colour.
        let outside = pixel(data, 24, 24)
        #expect(abs(outside.x - 0.1) < 0.002 && abs(outside.z - 0.3) < 0.002)

        // Inside: alternating light (white) and dark (0.8 sRGB ≈ 0.604 linear) squares.
        let light = pixel(data, 1, 1)
        let dark = pixel(data, 5, 1)
        #expect(abs(light.x - 1) < 0.002)
        #expect(abs(dark.x - 0.604) < 0.005)
        #expect(light.w == 1 && dark.w == 1)
    }

    @Test func linearization() {
        #expect(LinearColor.linearize(0) == 0)
        #expect(abs(LinearColor.linearize(1) - 1) < 1e-12)
        #expect(abs(LinearColor.linearize(0.5) - 0.214) < 0.001)
    }
}
