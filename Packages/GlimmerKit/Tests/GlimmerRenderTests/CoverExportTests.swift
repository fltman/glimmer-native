import CoreGraphics
import Foundation
import ImageIO
@testable import GlimmerRender
import Testing

@Suite struct CoverExportTests {
    /// A wide test photo: red left third, blue right third, noisy green middle (hard to compress).
    static func photo(width: Int = 2400, height: Int = 1200) -> CGImage {
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let px = ctx.data!.assumingMemoryBound(to: UInt8.self)
        var seed: UInt32 = 7
        for y in 0..<height {
            for x in 0..<width {
                seed = seed &* 1_664_525 &+ 1_013_904_223
                let i = y * ctx.bytesPerRow + x * 4
                let third = x * 3 / width
                px[i] = third == 0 ? 220 : 0
                px[i + 1] = third == 1 ? UInt8(truncatingIfNeeded: seed >> 24) : 0
                px[i + 2] = third == 2 ? 220 : 0
                px[i + 3] = 255
            }
        }
        return ctx.makeImage()!
    }

    static func size(of data: Data) -> (Int, Int)? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int else { return nil }
        return (w, h)
    }

    @Test func coverIsTheCentreSquareAtExactlyTheSize() throws {
        let cover = try ImageExporter.squareCover(Self.photo(), side: 3000)  // up from 1200
        #expect(cover.width == 3000 && cover.height == 3000)
        let small = try ImageExporter.squareCover(Self.photo(), side: 1400)
        #expect(small.width == 1400 && small.height == 1400)
        // The centre square of a 2:1 image drops the outer quarters: the edges are the red and blue thirds' inner parts.
        let data = try ImageExporter.encode(small, options: ExportOptions(format: .png))
        let decoded = CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithData(data as CFData, nil)!, 0, nil)!
        let ctx = CGContext(data: nil, width: 1400, height: 1400, bitsPerComponent: 8, bytesPerRow: 1400 * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(decoded, in: CGRect(x: 0, y: 0, width: 1400, height: 1400))
        let px = ctx.data!.assumingMemoryBound(to: UInt8.self)
        let row = 700 * 1400 * 4
        #expect(px[row + 10 * 4] > 150 && px[row + 10 * 4 + 2] < 60, "left edge is red")
        #expect(px[row + 1390 * 4 + 2] > 150 && px[row + 1390 * 4] < 60, "right edge is blue")
    }

    @Test func byteLimitLowersQualityButNeverTheSize() throws {
        let cover = try ImageExporter.squareCover(Self.photo(), side: 3000)
        let limit = 900_000
        let data = try ImageExporter.encode(cover, options: ExportOptions(format: .jpeg, quality: 0.95, maxBytes: limit), keepSize: true)
        #expect(data.count <= limit)
        #expect(Self.size(of: data).map { $0 == (3000, 3000) } == true)
    }

    @Test func anImpossibleLimitSaysSo() throws {
        let cover = try ImageExporter.squareCover(Self.photo(), side: 1400)
        #expect(throws: ExportLimitError.self) {
            try ImageExporter.encode(cover, options: ExportOptions(format: .jpeg, maxBytes: 2_000), keepSize: true)
        }
        #expect(throws: ExportLimitError.self) {
            try ImageExporter.encode(cover, options: ExportOptions(format: .png, maxBytes: 50_000), keepSize: true)
        }
    }

    @Test func transparentAreasGetTheBackground() throws {
        let ctx = CGContext(data: nil, width: 100, height: 100, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let cover = try ImageExporter.squareCover(ctx.makeImage()!, side: 1400, background: SIMD3(1, 1, 1))
        let data = try ImageExporter.encode(cover, options: ExportOptions(format: .png))
        let img = CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithData(data as CFData, nil)!, 0, nil)!
        let out = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        out.draw(img, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        let p = out.data!.assumingMemoryBound(to: UInt8.self)
        #expect(p[0] > 250 && p[3] == 255)
    }
}
