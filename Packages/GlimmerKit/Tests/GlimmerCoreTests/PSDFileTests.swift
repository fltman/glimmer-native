import Compression
import Foundation
import Testing
@testable import GlimmerCore

/// Writes Photoshop files for the tests, from the same specification as the reader but as
/// separate code: valid ones to read back, and the pieces hostile ones are made of.
struct PSDTestWriter {
    struct Layer {
        var name = "Layer"
        var rect = PSDFile.Rect(top: 0, left: 0, bottom: 2, right: 2)
        var blendKey = "norm"
        var opacity: UInt8 = 255
        var clipped = false
        var visible = true
        var group: UInt32? = nil                 // 1 open, 2 closed, 3 end
        var planes: [(id: Int, samples: [UInt16])] = []
        var mask: (rect: PSDFile.Rect, color: UInt8, pixels: [UInt8])? = nil
        var compression: UInt16 = 0
        var extraBlocks: [(key: String, body: Data)] = []
    }

    var large = false
    var depth = 8
    var mode: UInt16 = 3
    var width = 2, height = 2
    var channels = 3
    var layers: [Layer] = []
    var composite: [[UInt16]] = []
    var compositeCompression: UInt16 = 0
    var iccProfile: Data?

    static func be16(_ v: UInt16) -> Data { Data([UInt8(v >> 8), UInt8(v & 0xFF)]) }
    static func be32(_ v: UInt32) -> Data { be16(UInt16(v >> 16)) + be16(UInt16(v & 0xFFFF)) }
    func length(_ n: Int) -> Data { large ? Self.be32(UInt32(n >> 32)) + Self.be32(UInt32(n & 0xFFFF_FFFF)) : Self.be32(UInt32(n)) }

    func samples(_ values: [UInt16], bytes: Int) -> Data {
        var d = Data()
        for v in values { if bytes == 2 { d += Self.be16(v) } else { d.append(UInt8(truncatingIfNeeded: v)) } }
        return d
    }

    static func packBits(_ row: Data) -> Data {
        // Literal runs only, at most 128 bytes each: valid PackBits, if not the smallest.
        var out = Data(), i = row.startIndex
        while i < row.endIndex {
            let n = min(128, row.endIndex - i)
            out.append(UInt8(n - 1)); out += row[i..<(i + n)]; i += n
        }
        return out
    }

    static func zlib(_ data: Data) -> Data {
        var out = Data(count: data.count + 64)
        let n = out.withUnsafeMutableBytes { d in data.withUnsafeBytes { s in
            compression_encode_buffer(d.bindMemory(to: UInt8.self).baseAddress!, d.count, s.bindMemory(to: UInt8.self).baseAddress!, s.count, nil, COMPRESSION_ZLIB) } }
        return Data([0x78, 0x9C]) + out.prefix(n) + Data([0, 0, 0, 0])   // a zlib header, the stream, a checksum nobody reads
    }

    func plane(_ values: [UInt16], width: Int, height: Int, bytes: Int, compression: UInt16) -> Data {
        var raw = samples(values, bytes: bytes)
        switch compression {
        case 1:
            let rowBytes = width * bytes
            var counts = Data(), rows = Data()
            for y in 0..<height {
                let packed = Self.packBits(raw.subdata(in: (y * rowBytes)..<((y + 1) * rowBytes)))
                counts += large ? Self.be32(UInt32(packed.count)) : Self.be16(UInt16(packed.count))
                rows += packed
            }
            return Self.be16(1) + counts + rows
        case 2:
            return Self.be16(2) + Self.zlib(raw)
        case 3:
            // Differences from the sample to the left, row by row.
            let rowBytes = width * bytes
            for y in 0..<height {
                for x in stride(from: width - 1, to: 0, by: -1) {
                    let a = y * rowBytes + x * bytes
                    if bytes == 2 {
                        let cur = UInt16(raw[a]) << 8 | UInt16(raw[a + 1]), prev = UInt16(raw[a - 2]) << 8 | UInt16(raw[a - 1])
                        let d = cur &- prev
                        raw[a] = UInt8(d >> 8); raw[a + 1] = UInt8(d & 0xFF)
                    } else {
                        raw[a] = raw[a] &- raw[a - 1]
                    }
                }
            }
            return Self.be16(3) + Self.zlib(raw)
        default:
            return Self.be16(0) + raw
        }
    }

    func record(_ layer: Layer, planes: [Data], maskPlane: Data?) -> Data {
        var d = Data()
        for v in [layer.rect.top, layer.rect.left, layer.rect.bottom, layer.rect.right] { d += Self.be32(UInt32(bitPattern: Int32(v))) }
        d += Self.be16(UInt16(planes.count + (maskPlane == nil ? 0 : 1)))
        for (i, p) in planes.enumerated() { d += Self.be16(UInt16(bitPattern: Int16(layer.planes[i].id))) + length(p.count) }
        if let maskPlane { d += Self.be16(UInt16(bitPattern: -2)) + length(maskPlane.count) }
        d += Data("8BIM".utf8) + Data(layer.blendKey.utf8)
        d.append(layer.opacity); d.append(layer.clipped ? 1 : 0); d.append(layer.visible ? 0 : 2); d.append(0)
        var extra = Data()
        if let mask = layer.mask {
            var m = Data()
            for v in [mask.rect.top, mask.rect.left, mask.rect.bottom, mask.rect.right] { m += Self.be32(UInt32(bitPattern: Int32(v))) }
            m.append(mask.color); m.append(0); m += Data([0, 0])
            extra += Self.be32(UInt32(m.count)) + m
        } else {
            extra += Self.be32(0)
        }
        extra += Self.be32(0)                                    // blending ranges
        var name = Data([UInt8(min(layer.name.utf8.count, 255))]) + Data(layer.name.utf8.prefix(255))
        while name.count % 4 != 0 { name.append(0) }
        extra += name
        var blocks = layer.extraBlocks
        let utf16 = Array(layer.name.utf16)
        blocks.append(("luni", Self.be32(UInt32(utf16.count)) + utf16.reduce(Data()) { $0 + Self.be16($1) }))
        if let group = layer.group { blocks.append(("lsct", Self.be32(group))) }
        for block in blocks {
            var body = block.body
            if body.count % 2 == 1 { body.append(0) }
            extra += Data("8BIM".utf8) + Data(block.key.utf8) + Self.be32(UInt32(body.count)) + body
        }
        return d + Self.be32(UInt32(extra.count)) + extra
    }

    func header() -> Data {
        var d = Data("8BPS".utf8) + Self.be16(large ? 2 : 1) + Data(count: 6)
        d += Self.be16(UInt16(channels)) + Self.be32(UInt32(height)) + Self.be32(UInt32(width)) + Self.be16(UInt16(depth)) + Self.be16(mode)
        return d
    }

    func layerInfo() -> Data {
        let bytes = max(1, depth / 8)
        var records = Data(), pixels = Data()
        for layer in layers {
            let planes = layer.planes.map { plane($0.samples, width: layer.rect.width, height: layer.rect.height, bytes: bytes, compression: layer.compression) }
            let maskPlane = layer.mask.map { plane($0.pixels.map(UInt16.init), width: $0.rect.width, height: $0.rect.height, bytes: 1, compression: layer.compression) }
            records += record(layer, planes: planes, maskPlane: maskPlane)
            for p in planes { pixels += p }
            if let maskPlane { pixels += maskPlane }
        }
        var info = Self.be16(UInt16(layers.count)) + records + pixels
        if info.count % 2 == 1 { info.append(0) }
        return info
    }

    func data() -> Data {
        var d = header()
        d += Self.be32(0)                                        // colour mode data
        var resources = Data()
        if let icc = iccProfile {
            resources += Data("8BIM".utf8) + Self.be16(1039) + Data([0, 0]) + Self.be32(UInt32(icc.count)) + icc
            if icc.count % 2 == 1 { resources.append(0) }
        }
        d += Self.be32(UInt32(resources.count)) + resources
        let info = layerInfo()
        var section = Data()
        if depth == 16 {
            // 16-bit documents: no layer info here; the layers sit in an 'Lr16' block after the global mask.
            section += length(0) + Self.be32(0)
            var block = Data("8BIM".utf8) + Data("Lr16".utf8) + length(info.count) + info
            while block.count % 4 != 0 { block.append(0) }
            section += block
        } else {
            section += length(info.count) + info + Self.be32(0)
        }
        d += length(section.count) + section
        d += Self.be16(compositeCompression)
        let bytes = max(1, depth / 8)
        if compositeCompression == 1 {
            var counts = Data(), rows = Data()
            for channel in composite {
                let raw = samples(channel, bytes: bytes), rowBytes = width * bytes
                for y in 0..<height {
                    let packed = Self.packBits(raw.subdata(in: (y * rowBytes)..<((y + 1) * rowBytes)))
                    counts += large ? Self.be32(UInt32(packed.count)) : Self.be16(UInt16(packed.count)); rows += packed
                }
            }
            d += counts + rows
        } else {
            for channel in composite { d += samples(channel, bytes: bytes) }
        }
        return d
    }

    /// A small document with a little of everything: two pixel layers in a group, a mask, a hidden layer.
    static func sample(depth: Int = 8, large: Bool = false, compression: UInt16 = 0) -> PSDTestWriter {
        var w = PSDTestWriter(large: large, depth: depth, width: 4, height: 3)
        let full = PSDFile.Rect(top: 0, left: 0, bottom: 3, right: 4)
        func ramp(_ start: UInt16) -> [UInt16] { (0..<12).map { start &+ UInt16($0) &* (depth == 16 ? 2570 : 10) } }
        let back = Layer(name: "Background copy", rect: full, planes: [(0, ramp(10)), (1, ramp(20)), (2, ramp(30))], compression: compression)
        let end = Layer(name: "</Layer group>", rect: .init(top: 0, left: 0, bottom: 0, right: 0), group: 3)
        var inner = Layer(name: "Blå himmel", rect: .init(top: 1, left: 1, bottom: 3, right: 3), blendKey: "mul ", opacity: 128,
                          planes: [(-1, [255, 255, 0, 255]), (0, [1, 2, 3, 4]), (1, [5, 6, 7, 8]), (2, [9, 10, 11, 12])], compression: compression)
        inner.mask = (PSDFile.Rect(top: 1, left: 1, bottom: 2, right: 3), 255, [0, 200])
        var hidden = Layer(name: "Hidden", rect: full, visible: false, planes: [(0, ramp(1)), (1, ramp(2)), (2, ramp(3))], compression: compression)
        hidden.clipped = true
        hidden.extraBlocks = [("TySh", Data([1, 2, 3]))]
        let folder = Layer(name: "Group 1", rect: .init(top: 0, left: 0, bottom: 0, right: 0), blendKey: "pass", group: 1)
        w.layers = [back, end, inner, hidden, folder]
        w.composite = [ramp(100), ramp(110), ramp(120)]
        return w
    }
}

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
