import Compression
import Foundation
import Testing
@testable import GlimmerCore
import PSDTestSupport

@Suite struct PSDFileTests {
    static let limits = PSDFile.Limits(maxCanvasPixels: 1_000_000, maxDecodedBytes: 4_000_000)

    @Test(arguments: [(8, false, UInt16(0)), (8, false, 1), (8, false, 2), (8, false, 3), (16, false, 0), (16, false, 3), (8, true, 1), (16, true, 2)])
    func readsWhatWasWritten(depth: Int, large: Bool, compression: UInt16) throws {
        let writer = PSDTestWriter.sample(depth: depth, large: large, compression: compression)
        let file = try PSDFile(writer.data(), limits: Self.limits)
        #expect(file.header == PSDFile.Header(isLarge: large, channels: 3, width: 4, height: 3, depth: depth, mode: .rgb))
        #expect(file.layers.map(\.name) == ["Background copy", "</Layer group>", "Blå himmel", "Hidden", "Group 1"])
        #expect(file.layers.map(\.group) == [.none, .end, .none, .none, .open])
        let inner = file.layers[2]
        #expect(inner.blendKey == "mul " && inner.opacity == 128 && inner.isVisible && !inner.isClipped)
        #expect(inner.rect == PSDFile.Rect(top: 1, left: 1, bottom: 3, right: 3))
        let bytes = depth / 8
        #expect(inner.bytesPerSample == bytes && inner.planes.keys.sorted() == [-1, 0, 1, 2])
        #expect(inner.planes[0] == writer.samples([1, 2, 3, 4], bytes: bytes) && inner.planes[-1] == writer.samples([255, 255, 0, 255], bytes: bytes))
        #expect(inner.mask?.rect == PSDFile.Rect(top: 1, left: 1, bottom: 2, right: 3) && inner.mask?.defaultColor == 255 && inner.mask?.pixels == Data([0, 200]))
        let hidden = file.layers[3]
        #expect(!hidden.isVisible && hidden.isClipped && hidden.extraKeys.contains("TySh"))
        #expect(file.layers[0].planes[2] == writer.samples(writer.layers[0].planes[2].samples, bytes: bytes))
        #expect(file.layers[4].blendKey == "pass")
        #expect(file.composite.count == 3 && file.composite[1] == writer.samples(writer.composite[1], bytes: bytes))
    }

    @Test func readsTheProfileAndARunLengthComposite() throws {
        var writer = PSDTestWriter.sample()
        writer.iccProfile = Data("not really a profile".utf8)
        writer.compositeCompression = 1
        let file = try PSDFile(writer.data(), limits: Self.limits)
        #expect(file.iccProfile == Data("not really a profile".utf8))
        #expect(file.composite.count == 3 && file.composite[0] == writer.samples(writer.composite[0], bytes: 1))
    }

    @Test func theHeaderIsCheckedBeforeAnythingElse() throws {
        let good = PSDTestWriter.sample().data()
        func with(_ offset: Int, _ bytes: [UInt8]) -> Data { var d = good; d.replaceSubrange(offset..<(offset + bytes.count), with: bytes); return d }
        #expect(throws: PSDFile.Problem("This isn't a Photoshop file.")) { _ = try PSDFile(with(0, Array("8BPX".utf8)), limits: Self.limits) }
        #expect(throws: PSDFile.Problem.self) { _ = try PSDFile(with(4, [0, 9]), limits: Self.limits) }            // version 9
        #expect(throws: PSDFile.Problem.self) { _ = try PSDFile(with(12, [0, 0]), limits: Self.limits) }           // no channels
        #expect(throws: PSDFile.Problem.self) { _ = try PSDFile(with(12, [0, 57]), limits: Self.limits) }          // 57 channels
        #expect(throws: PSDFile.Problem.self) { _ = try PSDFile(with(14, [0, 0, 0x75, 0x31]), limits: Self.limits) }  // 30,001 high in a PSD
        #expect(throws: PSDFile.Problem.self) { _ = try PSDFile(with(22, [0, 12]), limits: Self.limits) }          // 12 bits
        #expect(throws: PSDFile.Problem.self) { _ = try PSDFile(with(24, [0, 5]), limits: Self.limits) }           // colour mode 5
        #expect(throws: PSDFile.Problem.self) { _ = try PSDFile(Data("8BPS".utf8), limits: Self.limits) }
        #expect(throws: PSDFile.Problem.self) { _ = try PSDFile(Data(), limits: Self.limits) }
        // A canvas within the format's limits and beyond this Mac's is refused from the header alone.
        let huge = with(14, [0, 0, 0x75, 0x30]) |> { var d = $0; d.replaceSubrange(18..<22, with: [0, 0, 0x75, 0x30]); return d }
        #expect(throws: PSDFile.Problem.self) { _ = try PSDFile(huge, limits: Self.limits) }
    }

    /// Cut at every length, the reader throws or returns: it never crashes and never reads past the end.
    @Test func aFileCutAnywhereIsRefusedOrReadWithoutACrash() {
        for writer in [PSDTestWriter.sample(), PSDTestWriter.sample(depth: 16, compression: 3), PSDTestWriter.sample(large: true, compression: 1)] {
            let good = writer.data()
            var read = 0
            for length in 0..<good.count {
                if (try? PSDFile(good.prefix(length), limits: Self.limits)) != nil { read += 1 }
            }
            // Only a cut inside the flattened image at the very end may still give the layers.
            #expect(read <= 3 * 4 * 3 * (writer.depth / 8) + 2, "\(read) of \(good.count) cuts were read")
        }
    }

    /// Every byte of the file changed, one at a time, to several values: no crash, and nothing beyond the budget.
    @Test func aFileWithAnyByteChangedIsRefusedOrReadWithoutACrash() {
        for writer in [PSDTestWriter.sample(compression: 1), PSDTestWriter.sample(depth: 16, compression: 2), PSDTestWriter.sample(large: true, compression: 3)] {
            let good = writer.data()
            for index in good.indices {
                for value: UInt8 in [0x00, 0x7F, 0x80, 0xFF] where good[index] != value {
                    var bad = good
                    bad[index] = value
                    if let file = try? PSDFile(bad, limits: Self.limits) {
                        let decoded = file.layers.reduce(0) { $0 + $1.planes.values.reduce(0) { $0 + $1.count } + ($1.mask?.pixels?.count ?? 0) }
                        #expect(decoded <= Self.limits.maxDecodedBytes)
                    }
                }
            }
        }
    }

    @Test func aFileThatLiesAboutItsSizesIsRefused() throws {
        // A layer said to be enormous, in a tiny file.
        var writer = PSDTestWriter.sample()
        writer.layers[0].rect = PSDFile.Rect(top: 0, left: 0, bottom: 900_000, right: 900_000)
        #expect(throws: PSDFile.Problem.self) { _ = try PSDFile(writer.data(), limits: Self.limits) }
        // More layers than Glimmer reads, by count alone.
        var many = PSDTestWriter.sample().data()
        let countAt = 26 + 4 + 4 + 4 + 4
        many.replaceSubrange(countAt..<(countAt + 2), with: [0x7F, 0xFF])
        #expect(throws: PSDFile.Problem.self) { _ = try PSDFile(many, limits: Self.limits) }
        // A plane that is larger than the whole budget.
        #expect(throws: PSDFile.Problem.self) { _ = try PSDFile(PSDTestWriter.sample().data(), limits: PSDFile.Limits(maxCanvasPixels: 1_000_000, maxDecodedBytes: 8)) }
    }

    @Test func compressedDataNeverGivesMoreThanItsPlaneHolds() throws {
        // A run-length row that would produce more than the row holds.
        var out = Data()
        #expect(throws: PSDFile.Problem.self) { try PSDFile.unpackBits(Data([0x81, 7]), into: &out, expecting: 4) }   // 128 copies into 4
        #expect(throws: PSDFile.Problem.self) { try PSDFile.unpackBits(Data([3, 1, 2]), into: &out, expecting: 4) }   // says 4 literals, has 2
        #expect(throws: PSDFile.Problem.self) { try PSDFile.unpackBits(Data([0, 1]), into: &out, expecting: 4) }      // too short
        // A zlib stream that expands to far more than the plane: stopped at the plane's size, and refused.
        let bomb = PSDTestWriter.zlib(Data(count: 1_000_000))
        #expect(throws: PSDFile.Problem.self) { _ = try PSDFile.inflate(bomb, size: 16) }
        #expect(throws: PSDFile.Problem.self) { _ = try PSDFile.inflate(PSDTestWriter.zlib(Data(count: 8)), size: 16) }   // too little
        #expect(try PSDFile.inflate(PSDTestWriter.zlib(Data(repeating: 7, count: 16)), size: 16) == Data(repeating: 7, count: 16))
    }
}

infix operator |>: AdditionPrecedence
private func |> <A, B>(value: A, transform: (A) -> B) -> B { transform(value) }
