import CoreGraphics
import Foundation
import GlimmerCore
import ImageIO
import Testing
@testable import GlimmerRender

/// Decodes with ImageIO into premultiplied RGBA8 (what CGContext offers).
private func decodeRGBA(_ data: Data) throws -> (pixels: [UInt8], width: Int, height: Int) {
    let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
    let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
    let w = image.width, h = image.height
    var px = [UInt8](repeating: 0, count: w * h * 4)
    px.withUnsafeMutableBytes { buffer in
        let ctx = CGContext(data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                            space: image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
    }
    return (px, w, h)
}

@Suite struct WebPEncoderTests {
    /// Smooth gradients plus noise: exercises every predictor and long Huffman codes.
    private func testPixels(width: Int, height: Int, alpha: Bool) -> [UInt8] {
        var rng = SystemRandomNumberGenerator()
        var px = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let i = (y * width + x) * 4
                let noise = Int.random(in: -6...6, using: &rng)
                px[i] = UInt8(clamping: x * 255 / max(width - 1, 1) + noise)
                px[i + 1] = UInt8(clamping: y * 255 / max(height - 1, 1) - noise)
                px[i + 2] = UInt8(clamping: (x ^ y) & 0xff)
                px[i + 3] = alpha ? (x < width / 3 ? 0 : (x < 2 * width / 3 ? 255 : 255)) : 255
            }
        }
        return px
    }

    @Test(arguments: [(1, 1), (7, 3), (64, 64), (333, 129)])
    func opaqueImagesRoundTripExactly(size: (Int, Int)) throws {
        let (w, h) = size
        let px = testPixels(width: w, height: h, alpha: false)
        let data = try WebPEncoder.encode(rgba: px, width: w, height: h)
        let decoded = try decodeRGBA(data)
        #expect(decoded.width == w && decoded.height == h)
        #expect(decoded.pixels == px)
    }

    @Test func alphaRoundTrips() throws {
        let w = 120, h = 40
        let px = testPixels(width: w, height: h, alpha: true)
        let decoded = try decodeRGBA(try WebPEncoder.encode(rgba: px, width: w, height: h))
        for i in stride(from: 0, to: px.count, by: 4) {
            #expect(decoded.pixels[i + 3] == px[i + 3])
            if px[i + 3] == 255 { #expect(Array(decoded.pixels[i..<i + 3]) == Array(px[i..<i + 3])) }
        }
    }

    @Test func flatImagesUseSimpleCodes() throws {
        // One colour: every prefix code collapses to a single symbol.
        let px: [UInt8] = (0..<(50 * 50 * 4)).map { $0 % 4 == 3 ? 255 : 77 }
        let data = try WebPEncoder.encode(rgba: px, width: 50, height: 50)
        #expect(data.count < 1000)  // 10 kB raw
        #expect(try decodeRGBA(data).pixels == px)
    }

    @Test func embedsTheICCProfile() throws {
        let icc = try #require(CGColorSpace(name: CGColorSpace.displayP3)?.copyICCData() as Data?)
        let px = testPixels(width: 16, height: 16, alpha: false)
        let data = try WebPEncoder.encode(rgba: px, width: 16, height: 16, iccProfile: icc)
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        #expect((props?[kCGImagePropertyProfileName] as? String)?.contains("P3") == true)
    }

    @Test func rejectsHugeImages() {
        #expect(throws: WebPEncoder.Error.self) { try WebPEncoder.encode(rgba: [], width: 20_000, height: 1) }
    }

    @Test func exportsADocumentAsWebP() throws {
        let state = DocumentState(width: 300, height: 200, layers: [solidLayer(SIMD4(1, 0, 0, 1), size: 300)])
        let flat = try ImageExporter.flatten(state, context: try context())
        let data = try ImageExporter.encode(flat, options: ExportOptions(format: .webp))
        #expect(data.prefix(4) == Data("RIFF".utf8))
        let decoded = try decodeRGBA(data)
        #expect(decoded.width == 300 && decoded.pixels[0] == 255 && decoded.pixels[1] == 0)
    }

    @Test func floatTIFFKeepsHDRValues() throws {
        // Linear 2.0 (brighter than white) must survive as a float above 1.
        let state = DocumentState(width: 64, height: 64, layers: [solidLayer(SIMD4(2, 0.5, 0, 1), size: 64)])
        let flat = try ImageExporter.flatten(state, context: try context())
        let options = ExportOptions(format: .tiff, bitDepth: .float32)
        #expect(options.effectiveBitDepth == .float32)
        #expect(ExportOptions(format: .png, bitDepth: .float32).effectiveBitDepth == .sixteen)
        let data = try ImageExporter.encode(flat, options: options)
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(image.bitsPerComponent == 32)
        #expect(image.bitmapInfo.contains(.floatComponents))
        var px = [Float](repeating: 0, count: 4)
        px.withUnsafeMutableBytes { buffer in
            let ctx = CGContext(data: buffer.baseAddress, width: 1, height: 1, bitsPerComponent: 32, bytesPerRow: 16,
                                space: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.floatComponents.rawValue
                                    | CGBitmapInfo.byteOrder32Little.rawValue)!
            ctx.draw(image, in: CGRect(x: -10, y: -10, width: 64, height: 64))
        }
        #expect(abs(px[0] - 2) < 0.01 && abs(px[1] - 0.5) < 0.01, "\(px)")
    }
}

@Suite struct WebPPerformanceTests {
    @Test func photoSizedImageEncodesSmall() throws {
        // A 2048 × 1536 smooth image with grain: WebP must stay well below raw size.
        let w = 2048, h = 1536
        var px = [UInt8](repeating: 255, count: w * h * 4)
        var seed: UInt32 = 1
        for y in 0..<h {
            for x in 0..<w {
                seed = seed &* 1_664_525 &+ 1_013_904_223
                let n = Int(seed >> 29)
                let i = (y * w + x) * 4
                px[i] = UInt8(clamping: (x * 200 / w) + n)
                px[i + 1] = UInt8(clamping: (y * 180 / h) + n)
                px[i + 2] = UInt8(clamping: 90 + ((x + y) >> 5) % 40)
            }
        }
        let start = Date()
        let data = try WebPEncoder.encode(rgba: px, width: w, height: h)
        print("WebP 2048×1536: \(data.count / 1024) kB in \(String(format: "%.2f", Date().timeIntervalSince(start))) s")
        #expect(data.count < px.count / 3)
        // Near-lossless: clearly smaller, and no channel off by more than the rounding step.
        for bits in [1, 2] {
            let small = try WebPEncoder.encode(rgba: px, width: w, height: h, nearLossless: bits)
            print("  near-lossless \(bits) bit: \(small.count / 1024) kB")
            #expect(Double(small.count) < Double(data.count) * (bits == 1 ? 0.9 : 0.75))
            let decoded = try decodeRGBA(small).pixels
            var worst = 0
            for i in stride(from: 0, to: px.count, by: 97) { worst = max(worst, abs(Int(decoded[i]) - Int(px[i]))) }
            #expect(worst <= 1 << (bits - 1) + (bits == 1 ? 0 : 1))
        }
    }
}
