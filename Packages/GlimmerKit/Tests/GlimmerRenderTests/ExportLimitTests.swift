import CoreGraphics
import Foundation
@testable import GlimmerRender
import ImageIO
import Testing

@Suite struct ExportLimitTests {
    /// A detailed, noisy image that compresses badly.
    static func noisy(width: Int = 1600, height: Int = 1200) -> CGImage {
        var px = [UInt8](repeating: 255, count: width * height * 4)
        var seed: UInt32 = 3
        for y in 0..<height {
            for x in 0..<width {
                seed = seed &* 1_664_525 &+ 1_013_904_223
                let i = (y * width + x) * 4
                px[i] = UInt8((x * 255 / width + Int(seed >> 26)) & 255)
                px[i + 1] = UInt8((y * 255 / height + Int((seed >> 20) & 63)) & 255)
                px[i + 2] = UInt8(seed >> 24)
            }
        }
        let ctx = CGContext(data: &px, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return ctx.makeImage()!
    }

    static func size(of data: Data) -> (Int, Int) {
        let src = CGImageSourceCreateWithData(data as CFData, nil)!
        let img = CGImageSourceCreateImageAtIndex(src, 0, nil)!
        return (img.width, img.height)
    }

    @Test func longestSideIsLimited() throws {
        let data = try ImageExporter.encode(Self.noisy(), options: ExportOptions(format: .png, maxPixelSide: 400))
        let (w, h) = Self.size(of: data)
        #expect(w == 400 && h == 300)
    }

    @Test func jpegFitsTheByteLimit() throws {
        let limit = 120_000
        let unlimited = try ImageExporter.encode(Self.noisy(), options: ExportOptions(format: .jpeg, quality: 0.92))
        #expect(unlimited.count > limit)
        let data = try ImageExporter.encode(Self.noisy(), options: ExportOptions(format: .jpeg, quality: 0.92, maxBytes: limit))
        #expect(data.count <= limit)
        #expect(data.count > limit / 3)  // used most of the budget, not the lowest quality
    }

    @Test func aTinyLimitShrinksTheImageToo() throws {
        let data = try ImageExporter.encode(Self.noisy(width: 600, height: 400),
                                            options: ExportOptions(format: .webp, quality: 0.9, maxBytes: 6_000))
        #expect(data.count <= 6_000)
        let (w, _) = Self.size(of: data)
        #expect(w < 600)
    }

    @Test func pngIgnoresTheByteLimit() throws {
        let a = try ImageExporter.encode(Self.noisy(width: 200, height: 100), options: ExportOptions(format: .png))
        let b = try ImageExporter.encode(Self.noisy(width: 200, height: 100), options: ExportOptions(format: .png, maxBytes: 10))
        #expect(a == b)
    }
}
