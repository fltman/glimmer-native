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
        // 100 % quality is lossless: exact colour.
        let data = try ImageExporter.encode(flat, options: ExportOptions(format: .webp, quality: 1))
        #expect(data.prefix(4) == Data("RIFF".utf8))
        let decoded = try decodeRGBA(data)
        #expect(decoded.width == 300 && decoded.pixels[0] == 255 && decoded.pixels[1] == 0)
        // Below that it is lossy (a "VP8 " chunk): close colour, smaller file.
        let lossy = try ImageExporter.encode(flat, options: ExportOptions(format: .webp, quality: 0.8))
        #expect(lossy.subdata(in: 12..<16) == Data("VP8 ".utf8))
        let approx = try decodeRGBA(lossy)
        #expect(approx.width == 300 && approx.pixels[0] > 240 && approx.pixels[1] < 16)
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

@Suite struct WebPLossyTests {
    /// A photo-like test picture: gradients, a disc, a hard-edged box and mild texture.
    private func picture(_ w: Int, _ h: Int, alpha: Bool = false) -> [UInt8] {
        var px = [UInt8](repeating: 255, count: w * h * 4)
        var seed: UInt32 = 7
        for y in 0..<h {
            for x in 0..<w {
                seed = seed &* 1_664_525 &+ 1_013_904_223
                let n = Int(seed >> 30)
                let i = (y * w + x) * 4
                let dx = x - w / 2, dy = y - h / 2
                let inDisc = dx * dx + dy * dy < (min(w, h) / 4) * (min(w, h) / 4)
                let inBox = x > w * 3 / 4 && y < h / 4
                px[i] = UInt8(clamping: (inDisc ? 220 : x * 200 / max(w, 1)) + n)
                px[i + 1] = UInt8(clamping: (inBox ? 30 : y * 180 / max(h, 1) + 40) + n)
                px[i + 2] = UInt8(clamping: (inDisc ? 60 : 140 - x * 60 / max(w, 1)) + n)
                if alpha { px[i + 3] = x < w / 4 ? 0 : (x < w / 2 ? 128 : 255) }
            }
        }
        return px
    }

    private func psnr(_ a: [UInt8], _ b: [UInt8], where include: (Int) -> Bool = { _ in true }) -> Double {
        var sum = 0.0, n = 0.0
        for i in stride(from: 0, to: a.count, by: 4) where include(i) {
            for c in 0..<3 { let d = Double(a[i + c]) - Double(b[i + c]); sum += d * d; n += 1 }
        }
        return sum == 0 ? 99 : 10 * log10(255 * 255 / (sum / n))
    }

    @Test(arguments: [(256, 192), (17, 33), (1, 1), (640, 427)])
    func decodesCloseToTheSource(size: (Int, Int)) throws {
        let (w, h) = size
        let px = picture(w, h)
        let data = try WebPEncoder.encodeLossy(rgba: px, width: w, height: h, quality: 0.9)
        let decoded = try decodeRGBA(data)
        #expect(decoded.width == w && decoded.height == h)
        let quality = psnr(px, decoded.pixels)
        print("lossy \(w)×\(h) q90: \(data.count) bytes, PSNR \(String(format: "%.1f", quality)) dB")
        #expect(quality > (w * h < 1000 ? 24 : 32), "PSNR \(quality)")
    }

    @Test func qualityTradesSizeForFidelity() throws {
        let w = 640, h = 480
        let px = picture(w, h)
        var sizes: [Int] = [], fidelity: [Double] = []
        for q in [0.3, 0.6, 0.9] {
            let data = try WebPEncoder.encodeLossy(rgba: px, width: w, height: h, quality: q)
            sizes.append(data.count)
            fidelity.append(psnr(px, try decodeRGBA(data).pixels))
        }
        let lossless = try WebPEncoder.encode(rgba: px, width: w, height: h).count
        print("lossy sizes \(sizes) vs lossless \(lossless), PSNR \(fidelity.map { String(format: "%.1f", $0) })")
        #expect(sizes[0] < sizes[1] && sizes[1] < sizes[2])
        #expect(fidelity[0] < fidelity[1] && fidelity[1] < fidelity[2])
        #expect(sizes[2] < lossless / 3)
        #expect(fidelity[0] > 26)
    }

    @Test func alphaIsKeptExactly() throws {
        let w = 200, h = 96
        let px = picture(w, h, alpha: true)
        let data = try WebPEncoder.encodeLossy(rgba: px, width: w, height: h, quality: 0.8)
        let decoded = try decodeRGBA(data)
        for i in stride(from: 3, to: px.count, by: 4) { #expect(decoded.pixels[i] == px[i]) }
        // Opaque pixels keep their colour (decoded is premultiplied, so compare where alpha is 255).
        #expect(psnr(px, decoded.pixels) { px[$0 + 3] == 255 } > 30)
    }

    @Test func flatImagesAreTiny() throws {
        let px: [UInt8] = (0..<(320 * 240 * 4)).map { [90, 140, 200, 255][$0 % 4] }
        let data = try WebPEncoder.encodeLossy(rgba: px, width: 320, height: 240, quality: 0.75)
        #expect(data.count < 600)
        let decoded = try decodeRGBA(data)
        #expect(abs(Int(decoded.pixels[0]) - 90) <= 3 && abs(Int(decoded.pixels[2]) - 200) <= 3)
    }
}

/// Encodes a real photo when GLIMMER_PHOTO points at one (writes <photo>.q<N>.webp next to it).
@Suite(.enabled(if: ProcessInfo.processInfo.environment["GLIMMER_PHOTO"] != nil))
struct WebPPhotoTests {
    @Test func encodesAPhoto() throws {
        let path = ProcessInfo.processInfo.environment["GLIMMER_PHOTO"]!
        let source = try #require(CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let w = image.width, h = image.height
        var px = [UInt8](repeating: 0, count: w * h * 4)
        px.withUnsafeMutableBytes { buffer in
            let ctx = CGContext(data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        // For checking against libwebp: `dwebp -nofilter -pgm` must give exactly this luma plane.
        let (frame, luma) = VP8Encoder.encodeWithReconstruction(rgba: px, width: w, height: h, quality: 0.8)
        var file = Data("RIFF".utf8)
        let size = UInt32(4 + 8 + frame.count + frame.count % 2)
        file.append(contentsOf: withUnsafeBytes(of: size.littleEndian) { Array($0) })
        file.append(Data("WEBPVP8 ".utf8))
        file.append(contentsOf: withUnsafeBytes(of: UInt32(frame.count).littleEndian) { Array($0) })
        file.append(frame)
        if frame.count % 2 == 1 { file.append(0) }
        try file.write(to: URL(fileURLWithPath: path + ".recon.webp"))
        try Data(luma).write(to: URL(fileURLWithPath: path + ".recon.y"))
        func psnr(_ decoded: [UInt8]) -> Double {
            var sum = 0.0
            for i in stride(from: 0, to: px.count, by: 4) { for c in 0..<3 { let d = Double(px[i + c]) - Double(decoded[i + c]); sum += d * d } }
            return 10 * log10(255 * 255 / (sum / Double(w * h * 3)))
        }
        if let ref = try? Data(contentsOf: URL(fileURLWithPath: (path as NSString).deletingLastPathComponent + "/ref80.webp")) {
            print("cwebp q80: \(ref.count / 1024) kB, PSNR \(String(format: "%.2f", psnr(try decodeRGBA(ref).pixels)))")
        }
        for q in [50, 80, 95] {
            let start = Date()
            let data = try WebPEncoder.encodeLossy(rgba: px, width: w, height: h, quality: Double(q) / 100)
            let seconds = Date().timeIntervalSince(start)
            print("ours q\(q): \(data.count / 1024) kB, PSNR \(String(format: "%.2f", psnr(try decodeRGBA(data).pixels))), \(String(format: "%.1f", seconds)) s")
            try data.write(to: URL(fileURLWithPath: path + ".q\(q).webp"))
        }
    }
}
