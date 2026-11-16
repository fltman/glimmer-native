import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import GlimmerCore
import PSDTestSupport

/// The writer against the reader, and against the one outside reader this Mac has.
@Suite struct PSDWriterTests {
    static let limits = PSDFile.Limits(maxCanvasPixels: 1_000_000, maxDecodedBytes: 8_000_000)

    /// A file made by the tests' writer, read, written by Glimmer's writer, and read again: the same parts.
    @Test(arguments: [8, 16])
    func whatIsWrittenIsReadBackTheSame(depth: Int) throws {
        var source = PSDTestWriter.sample(depth: depth, compression: 1)
        source.iccProfile = Data("a profile".utf8)
        source.layers[2].extraBlocks = [("SoCo", PSDTestWriter.solidColor(red: 1, green: 2, blue: 3)), ("vmsk", PSDTestWriter.vectorMask([(x: 0, y: 0), (x: 1, y: 0), (x: 1, y: 1)]))]
        let first = try PSDFile(source.data(), limits: Self.limits)
        let written = try PSDWriter.data(for: first)
        let second = try PSDFile(written, limits: Self.limits)
        #expect(second.header == first.header && second.iccProfile == first.iccProfile && second.composite == first.composite)
        #expect(second.layers.count == first.layers.count)
        for (a, b) in zip(first.layers, second.layers) {
            #expect(a.name == b.name && a.rect == b.rect && a.blendKey == b.blendKey && a.opacity == b.opacity, "\(a.name)")
            #expect(a.isClipped == b.isClipped && a.isVisible == b.isVisible && a.group == b.group && a.planes == b.planes, "\(a.name)")
            #expect(a.mask?.rect == b.mask?.rect && a.mask?.defaultColor == b.mask?.defaultColor && a.mask?.isDisabled == b.mask?.isDisabled && a.mask?.pixels == b.mask?.pixels, "\(a.name)")
            #expect(a.blocks == b.blocks, "\(a.name)")
        }
        // Written twice, the same bytes: nothing in the file depends on the time or on chance.
        #expect(try PSDWriter.data(for: second) == written)
    }

    @Test func runLengthRowsComeBackWhateverTheyHold() throws {
        var cases: [Data] = [Data(), Data([7]), Data(repeating: 9, count: 300), Data((0..<300).map { UInt8($0 % 251) }),
                             Data([1, 1, 2, 2, 2, 3, 3, 3, 3, 4, 5, 5, 6, 6, 6]), Data(repeating: 0, count: 128), Data(repeating: 0, count: 129)]
        var generator = SystemRandomNumberGenerator()
        for _ in 0..<200 { cases.append(Data((0..<Int.random(in: 1...400, using: &generator)).map { _ in UInt8.random(in: 0...3, using: &generator) })) }
        for row in cases {
            var out = Data()
            try PSDFile.unpackBits(PSDWriter.packBits(row), into: &out, expecting: row.count)
            #expect(out == row)
        }
    }

    /// ImageIO is the one reader on this Mac that Glimmer didn't write: it must show the flattened picture as written.
    @Test func macOSReadsTheFlattenedPictureOfAWrittenFile() throws {
        let width = 16, height = 12
        func plane(_ value: (Int, Int) -> Int) -> Data { Data((0..<(width * height)).map { UInt8(value($0 % width, $0 / width)) }) }
        let composite = [plane { x, _ in 10 + x * 15 }, plane { _, y in 20 + y * 18 }, plane { x, y in (x + y) % 2 == 0 ? 200 : 40 }]
        let layer = PSDFile.Layer(name: "Bakgrund åäö", rect: PSDFile.Rect(top: 0, left: 0, bottom: height, right: width), blendKey: "norm", opacity: 255,
                                  isClipped: false, isVisible: true, group: .none, mask: nil, extraKeys: [], planes: [0: composite[0], 1: composite[1], 2: composite[2]], bytesPerSample: 1)
        let srgb = CGColorSpace(name: CGColorSpace.sRGB)!.copyICCData()! as Data
        let file = PSDFile(header: PSDFile.Header(isLarge: false, channels: 3, width: width, height: height, depth: 8, mode: .rgb), layers: [layer], composite: composite, iccProfile: srgb)
        let data = try PSDWriter.data(for: file)
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        #expect(CGImageSourceGetType(source) as String? == "com.adobe.photoshop-image")
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(image.width == width && image.height == height)
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        pixels.withUnsafeMutableBytes { raw in
            let ctx = CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        var worst = 0
        for i in 0..<(width * height) { for c in 0..<3 { worst = max(worst, abs(Int(pixels[i * 4 + c]) - Int(composite[c][i]))) } }
        print("PSD written by Glimmer, flattened picture as macOS decodes it: largest difference \(worst) of 255")
        #expect(worst <= 1)
        // And Glimmer's own reader takes the same file, with the Unicode name.
        #expect(try PSDFile(data, limits: Self.limits).layers.first?.name == "Bakgrund åäö")
    }

    @Test func theWriterRefusesWhatItsReaderWouldRefuse() {
        func file(width: Int = 4, height: Int = 4, depth: Int = 8, large: Bool = false, mode: PSDFile.ColorMode = .rgb, planeBytes: Int? = nil, layers: Int = 1) -> PSDFile {
            let size = planeBytes ?? width * height * (depth / 8)
            let plane = Data(count: max(0, min(size, 1 << 20)))
            let layer = PSDFile.Layer(name: "L", rect: PSDFile.Rect(top: 0, left: 0, bottom: min(height, 64), right: min(width, 64)), blendKey: "norm", opacity: 255, isClipped: false, isVisible: true,
                                      group: .none, mask: nil, extraKeys: [], planes: [:], bytesPerSample: depth / 8)
            return PSDFile(header: PSDFile.Header(isLarge: large, channels: 3, width: width, height: height, depth: depth, mode: mode),
                           layers: Array(repeating: layer, count: layers), composite: [plane, plane, plane], iccProfile: nil)
        }
        #expect((try? PSDWriter.data(for: file())) != nil)
        #expect(throws: PSDFile.Problem.self) { _ = try PSDWriter.data(for: file(width: 30_001)) }
        #expect(throws: PSDFile.Problem.self) { _ = try PSDWriter.data(for: file(width: 0)) }
        #expect(throws: PSDFile.Problem.self) { _ = try PSDWriter.data(for: file(depth: 32)) }
        #expect(throws: PSDFile.Problem.self) { _ = try PSDWriter.data(for: file(large: true)) }
        #expect(throws: PSDFile.Problem.self) { _ = try PSDWriter.data(for: file(mode: .cmyk)) }
        #expect(throws: PSDFile.Problem.self) { _ = try PSDWriter.data(for: file(planeBytes: 3)) }      // a flattened picture of the wrong size
        #expect(throws: PSDFile.Problem.self) { _ = try PSDWriter.data(for: file(layers: 8_001)) }
        var bad = file()
        bad.layers[0].planes = [0: Data(count: 5)]                                                       // a plane that doesn't fit its rectangle
        #expect(throws: PSDFile.Problem.self) { _ = try PSDWriter.data(for: bad) }
    }

    /// Every written file goes back through the hostile-file checks: cut anywhere, any byte changed, no crash.
    @Test func aWrittenFileSurvivesTheSameAbuseAsAnyOther() throws {
        let first = try PSDFile(PSDTestWriter.sample(depth: 8, compression: 0).data(), limits: Self.limits)
        let good = try PSDWriter.data(for: first)
        for length in 0..<good.count { _ = try? PSDFile(good.prefix(length), limits: Self.limits) }
        for index in good.indices {
            for value: UInt8 in [0x00, 0xFF] where good[index] != value {
                var bad = good
                bad[index] = value
                if let file = try? PSDFile(bad, limits: Self.limits) {
                    #expect(file.layers.reduce(0) { $0 + $1.planes.values.reduce(0) { $0 + $1.count } } <= Self.limits.maxDecodedBytes)
                }
            }
        }
    }
}
