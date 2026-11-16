import Compression
import Foundation
import GlimmerCore

/// Writes Photoshop files for the tests, from the same specification as the reader but as
/// separate code: valid ones to read back, and the pieces hostile ones are made of.
public struct PSDTestWriter {
    public init() {}
    public struct Layer {
        public init(name: String = "Layer", rect: PSDFile.Rect = PSDFile.Rect(top: 0, left: 0, bottom: 2, right: 2), blendKey: String = "norm",
                    opacity: UInt8 = 255, clipped: Bool = false, visible: Bool = true, group: UInt32? = nil,
                    planes: [(id: Int, samples: [UInt16])] = [], compression: UInt16 = 0) {
            self.name = name; self.rect = rect; self.blendKey = blendKey; self.opacity = opacity; self.clipped = clipped
            self.visible = visible; self.group = group; self.planes = planes; self.compression = compression
        }
        public var name = "Layer"
        public var rect = PSDFile.Rect(top: 0, left: 0, bottom: 2, right: 2)
        public var blendKey = "norm"
        public var opacity: UInt8 = 255
        public var clipped = false
        public var visible = true
        public var group: UInt32? = nil                 // 1 open, 2 closed, 3 end
        public var planes: [(id: Int, samples: [UInt16])] = []
        public var mask: (rect: PSDFile.Rect, color: UInt8, pixels: [UInt8])? = nil
        public var compression: UInt16 = 0
        public var extraBlocks: [(key: String, body: Data)] = []
    }

    public var large = false
    public var depth = 8
    public var mode: UInt16 = 3
    public var width = 2, height = 2
    public var channels = 3
    public var layers: [Layer] = []
    public var composite: [[UInt16]] = []
    public var compositeCompression: UInt16 = 0
    public var iccProfile: Data?

    public static func be16(_ v: UInt16) -> Data { Data([UInt8(v >> 8), UInt8(v & 0xFF)]) }
    public static func be32(_ v: UInt32) -> Data { be16(UInt16(v >> 16)) + be16(UInt16(v & 0xFFFF)) }
    public func length(_ n: Int) -> Data { large ? Self.be32(UInt32(n >> 32)) + Self.be32(UInt32(n & 0xFFFF_FFFF)) : Self.be32(UInt32(n)) }

    public func samples(_ values: [UInt16], bytes: Int) -> Data {
        var d = Data()
        for v in values { if bytes == 2 { d += Self.be16(v) } else { d.append(UInt8(truncatingIfNeeded: v)) } }
        return d
    }

    public static func packBits(_ row: Data) -> Data {
        // Literal runs only, at most 128 bytes each: valid PackBits, if not the smallest.
        var out = Data(), i = row.startIndex
        while i < row.endIndex {
            let n = min(128, row.endIndex - i)
            out.append(UInt8(n - 1)); out += row[i..<(i + n)]; i += n
        }
        return out
    }

    public static func zlib(_ data: Data) -> Data {
        var out = Data(count: data.count + 64)
        let n = out.withUnsafeMutableBytes { d in data.withUnsafeBytes { s in
            compression_encode_buffer(d.bindMemory(to: UInt8.self).baseAddress!, d.count, s.bindMemory(to: UInt8.self).baseAddress!, s.count, nil, COMPRESSION_ZLIB) } }
        return Data([0x78, 0x9C]) + out.prefix(n) + Data([0, 0, 0, 0])   // a zlib header, the stream, a checksum nobody reads
    }

    public func plane(_ values: [UInt16], width: Int, height: Int, bytes: Int, compression: UInt16) -> Data {
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

    public func record(_ layer: Layer, planes: [Data], maskPlane: Data?) -> Data {
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

    public func header() -> Data {
        var d = Data("8BPS".utf8) + Self.be16(large ? 2 : 1) + Data(count: 6)
        d += Self.be16(UInt16(channels)) + Self.be32(UInt32(height)) + Self.be32(UInt32(width)) + Self.be16(UInt16(depth)) + Self.be16(mode)
        return d
    }

    public func layerInfo() -> Data {
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

    public func data() -> Data {
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
    public static func sample(depth: Int = 8, large: Bool = false, compression: UInt16 = 0) -> PSDTestWriter {
        var w = PSDTestWriter()
        w.large = large; w.depth = depth; w.width = 4; w.height = 3
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

    /// A 64 × 48 document with things that come through as more than pixels (a Levels layer, a
    /// shape) and things an import can't keep (a text layer, a Vibrance layer, a layer in
    /// Lighter Color), inside a group, over a plain background.
    public static func mixed() -> PSDTestWriter {
        var w = PSDTestWriter()
        w.width = 64; w.height = 48
        let full = PSDFile.Rect(top: 0, left: 0, bottom: 48, right: 64)
        func plane(_ value: (Int, Int) -> Int) -> [UInt16] { (0..<(64 * 48)).map { UInt16(value($0 % 64, $0 / 64)) } }
        let back = Layer(name: "Background", rect: full, planes: [(0, plane { x, _ in 60 + x * 3 }), (1, plane { _, y in 60 + y * 4 }), (2, plane { _, _ in 150 })], compression: 1)
        let end = Layer(name: "</Layer group>", rect: PSDFile.Rect(top: 0, left: 0, bottom: 0, right: 0), group: 3)
        let box = PSDFile.Rect(top: 12, left: 16, bottom: 36, right: 48)
        func solid(_ r: Int, _ g: Int, _ b: Int) -> [(id: Int, samples: [UInt16])] {
            let n = box.width * box.height
            return [(-1, Array(repeating: 255, count: n)), (0, Array(repeating: UInt16(r), count: n)), (1, Array(repeating: UInt16(g), count: n)), (2, Array(repeating: UInt16(b), count: n))]
        }
        var title = Layer(name: "Title", rect: box, planes: solid(250, 240, 200), compression: 1)
        title.extraBlocks = [("TySh", typeTool("Summer Sale"))]
        var levels = Layer(name: "Levels 1", rect: PSDFile.Rect(top: 0, left: 0, bottom: 0, right: 0))
        levels.extraBlocks = [("levl", Self.levels([(10, 240, 0, 255, 120)]))]
        var vibrance = Layer(name: "Vibrance 1", rect: PSDFile.Rect(top: 0, left: 0, bottom: 0, right: 0))
        vibrance.extraBlocks = [("vibA", Data([0, 0, 0, 16]))]
        var badge = Layer(name: "Badge", rect: PSDFile.Rect(top: 0, left: 0, bottom: 0, right: 0))
        badge.extraBlocks = [("SoCo", solidColor(red: 220, green: 40, blue: 60)),
                             ("vmsk", vectorMask([(x: 0.7, y: 0.1), (x: 0.95, y: 0.1), (x: 0.95, y: 0.4), (x: 0.7, y: 0.4)]))]
        let glow = Layer(name: "Glow", rect: box, blendKey: "lgCl", opacity: 200, planes: solid(255, 200, 120), compression: 2)
        let folder = Layer(name: "Heading", rect: PSDFile.Rect(top: 0, left: 0, bottom: 0, right: 0), blendKey: "pass", group: 1)
        w.layers = [back, end, title, levels, vibrance, badge, glow, folder]
        w.composite = [plane { x, _ in 60 + x * 3 }, plane { _, y in 60 + y * 4 }, plane { _, _ in 150 }]
        return w
    }

    // MARK: Settings blocks (descriptors, paths, adjustments), as the specification lays them out

    public static func be64(_ v: UInt64) -> Data { be32(UInt32(v >> 32)) + be32(UInt32(v & 0xFFFF_FFFF)) }
    public static func double(_ v: Double) -> Data { be64(v.bitPattern) }
    public static func unicode(_ text: String) -> Data {
        let units = Array(text.utf16)
        return be32(UInt32(units.count)) + units.reduce(Data()) { $0 + be16($1) }
    }
    /// "4 bytes (length), followed either by string or (if length is zero) 4-byte ID".
    public static func id(_ key: String) -> Data { key.utf8.count == 4 ? be32(0) + Data(key.utf8) : be32(UInt32(key.utf8.count)) + Data(key.utf8) }
    public static func descriptor(_ classID: String, _ items: [(key: String, type: String, value: Data)]) -> Data {
        var d = unicode("") + id(classID) + be32(UInt32(items.count))
        for item in items { d += id(item.key) + Data(item.type.utf8) + item.value }
        return d
    }

    /// A solid colour fill's block ('SoCo'): version 16 and a descriptor holding the colour.
    public static func solidColor(red: Double, green: Double, blue: Double) -> Data {
        let color = descriptor("RGBC", [("Rd  ", "doub", double(red)), ("Grn ", "doub", double(green)), ("Bl  ", "doub", double(blue))])
        return be32(16) + descriptor("null", [("Clr ", "Objc", color)])
    }

    /// A vector mask's block ('vmsk'): version 3, flags, then 26-byte path records for one closed
    /// path with corner points, given as shares of the image (x, y from 0 to 1).
    public static func vectorMask(_ corners: [(x: Double, y: Double)], flags: UInt32 = 0) -> Data {
        func fixed(_ share: Double) -> Data { be32(UInt32(bitPattern: Int32((share * 16_777_216).rounded()))) }
        var d = be32(3) + be32(flags)
        d += be16(6) + Data(count: 24)                                   // the fill rule record
        d += be16(0) + be16(UInt16(corners.count)) + Data(count: 22)     // a closed subpath of that many knots
        for c in corners {
            let point = fixed(c.y) + fixed(c.x)                          // vertical first
            d += be16(1) + point + point + point                         // control before, anchor, control after
        }
        return d
    }

    /// A Levels block ('levl'): version 2 and 29 sets of five shorts; the first four are given.
    public static func levels(_ sets: [(inFloor: UInt16, inCeiling: UInt16, outFloor: UInt16, outCeiling: UInt16, gamma: UInt16)]) -> Data {
        var d = be16(2)
        for i in 0..<29 {
            let set = i < sets.count ? sets[i] : (0, 255, 0, 255, 100)
            d += be16(set.0) + be16(set.1) + be16(set.2) + be16(set.3) + be16(set.4)
        }
        return d
    }

    /// A Curves block ('curv'), version 4: each curve is its points as (input, output), 0 to 255.
    public static func curves(_ curves: [[(input: UInt16, output: UInt16)]]) -> Data {
        var d = be16(4) + be16(UInt16(curves.count))
        for curve in curves {
            d += be16(UInt16(curve.count))
            for point in curve { d += be16(point.output) + be16(point.input) }   // output first
        }
        return d
    }

    /// A type layer's block ('TySh') holding these words.
    public static func typeTool(_ words: String) -> Data {
        var d = be16(1)
        for v in [1.0, 0, 0, 1, 0, 0] { d += double(v) }
        d += be16(50) + be32(16) + descriptor("TxLr", [("Txt ", "TEXT", unicode(words))])
        d += be16(1) + be32(16) + descriptor("warp", [])
        for v in [0.0, 0, 0, 0] { d += double(v) }
        return d
    }
}
