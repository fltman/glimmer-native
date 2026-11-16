#if GLIMMER_PSD   // Config/Features.xcconfig
import Foundation

/// Writes a Photoshop file from its parts, by the same specification the reader follows and
/// as separate code. It refuses to write what its own reader would refuse to read: sizes,
/// counts and plane lengths are checked before a byte is produced.
public enum PSDWriter {
    public static func data(for file: PSDFile) throws -> Data {
        let header = file.header
        guard !header.isLarge else { throw PSDFile.Problem("Glimmer doesn't write the large document format yet.") }
        guard (1...30_000).contains(header.width), (1...30_000).contains(header.height) else {
            throw PSDFile.Problem("A Photoshop file can be at most 30,000 pixels on a side. This document is \(header.width) × \(header.height).")
        }
        guard header.depth == 8 || header.depth == 16, header.mode == .rgb || header.mode == .grayscale else {
            throw PSDFile.Problem("Glimmer writes Photoshop files in RGB or grayscale with 8 or 16 bits per channel.")
        }
        let bytes = header.depth / 8
        let colorChannels = header.mode == .rgb ? 3 : 1
        guard file.composite.count == colorChannels, file.composite.allSatisfy({ $0.count == header.width * header.height * bytes }) else {
            throw PSDFile.Problem("The flattened picture doesn't fit the document.")
        }
        guard file.layers.count <= 8_000 else { throw PSDFile.Problem("A Photoshop file from Glimmer can hold at most 8,000 layers.") }
        for layer in file.layers { try check(layer, bytes: bytes) }

        var out = Data("8BPS".utf8) + be16(1) + Data(count: 6)
        out += be16(UInt16(colorChannels)) + be32(UInt32(header.height)) + be32(UInt32(header.width)) + be16(UInt16(header.depth)) + be16(header.mode.rawValue)
        out += be32(0)                                            // colour mode data
        var resources = Data()
        if let icc = file.iccProfile, !icc.isEmpty {
            resources += Data("8BIM".utf8) + be16(1039) + Data([0, 0]) + be32(UInt32(icc.count)) + icc
            if icc.count % 2 == 1 { resources.append(0) }
        }
        out += be32(UInt32(resources.count)) + resources

        var info = Data()
        if !file.layers.isEmpty {
            var records = Data(), pixels = Data()
            for layer in file.layers {
                let ids = layer.planes.keys.sorted()
                let planes = ids.map { plane(layer.planes[$0]!, width: layer.rect.width, height: layer.rect.height, bytes: bytes) }
                let maskPlane = layer.mask.flatMap { mask in mask.pixels.map { plane($0, width: mask.rect.width, height: mask.rect.height, bytes: 1) } }
                records += record(layer, ids: ids, lengths: planes.map(\.count), maskLength: maskPlane?.count)
                for p in planes { pixels += p }
                if let maskPlane { pixels += maskPlane }
            }
            info = be16(UInt16(file.layers.count)) + records + pixels
            if info.count % 2 == 1 { info.append(0) }
        }
        var section = Data()
        if header.depth == 16, !info.isEmpty {
            // 16-bit documents keep their layers in an 'Lr16' block after an empty layer info and global mask.
            section += be32(0) + be32(0)
            var block = Data("8BIM".utf8) + Data("Lr16".utf8) + be32(UInt32(info.count)) + info
            while block.count % 4 != 0 { block.append(0) }
            section += block
        } else {
            section += be32(UInt32(info.count)) + info + be32(0)
        }
        out += be32(UInt32(section.count)) + section

        // The flattened picture, run-length compressed: the counts of every row of every channel, then the rows.
        var counts = Data(), rows = Data()
        let rowBytes = header.width * bytes
        for channel in file.composite {
            for y in 0..<header.height {
                let packed = packBits(channel.subdata(in: (channel.startIndex + y * rowBytes)..<(channel.startIndex + (y + 1) * rowBytes)))
                counts += be16(UInt16(packed.count)); rows += packed
            }
        }
        out += be16(1) + counts + rows
        return out
    }

    private static func check(_ layer: PSDFile.Layer, bytes: Int) throws {
        let r = layer.rect
        guard r.bottom >= r.top, r.right >= r.left, [r.top, r.left, r.bottom, r.right].allSatisfy({ abs($0) <= 1_000_000 }) else {
            throw PSDFile.Problem("The layer “\(layer.name)” has a rectangle a Photoshop file can't hold.")
        }
        guard layer.planes.count <= 56, layer.planes.values.allSatisfy({ $0.count == r.width * r.height * bytes }),
              layer.blendKey.utf8.count == 4 else {
            throw PSDFile.Problem("The layer “\(layer.name)” doesn't fit a Photoshop file.")
        }
        if let mask = layer.mask, let pixels = mask.pixels {
            guard mask.rect.bottom >= mask.rect.top, mask.rect.right >= mask.rect.left, pixels.count == mask.rect.width * mask.rect.height else {
                throw PSDFile.Problem("The mask of the layer “\(layer.name)” doesn't fit a Photoshop file.")
            }
        }
        // A row a kilobyte wide can't make a run-length count overflow its two bytes, but a very wide one could.
        guard r.width * bytes <= 32_000 || layer.planes.isEmpty else { throw PSDFile.Problem("The layer “\(layer.name)” is too wide for a Photoshop file.") }
    }

    private static func record(_ layer: PSDFile.Layer, ids: [Int], lengths: [Int], maskLength: Int?) -> Data {
        var d = Data()
        for v in [layer.rect.top, layer.rect.left, layer.rect.bottom, layer.rect.right] { d += be32(UInt32(bitPattern: Int32(v))) }
        d += be16(UInt16(ids.count + (maskLength == nil ? 0 : 1)))
        for (id, length) in zip(ids, lengths) { d += be16(UInt16(bitPattern: Int16(id))) + be32(UInt32(length)) }
        if let maskLength { d += be16(UInt16(bitPattern: -2)) + be32(UInt32(maskLength)) }
        d += Data("8BIM".utf8) + Data(layer.blendKey.utf8)
        d.append(layer.opacity); d.append(layer.isClipped ? 1 : 0); d.append(layer.isVisible ? 0 : 2); d.append(0)

        var extra = Data()
        if let mask = layer.mask {
            var m = Data()
            for v in [mask.rect.top, mask.rect.left, mask.rect.bottom, mask.rect.right] { m += be32(UInt32(bitPattern: Int32(v))) }
            m.append(mask.defaultColor); m.append(mask.isDisabled ? 2 : 0); m += Data([0, 0])
            extra += be32(UInt32(m.count)) + m
        } else {
            extra += be32(0)
        }
        extra += be32(0)                                          // blending ranges
        // The name as a Pascal string, padded to a multiple of four with its length byte; the full name follows in Unicode.
        let short = Data(layer.name.utf8.prefix(255).filter { $0 < 0x80 })
        var name = Data([UInt8(short.count)]) + short
        while name.count % 4 != 0 { name.append(0) }
        extra += name
        let units = Array(layer.name.utf16.prefix(1_000))
        var blocks: [(String, Data)] = [("luni", be32(UInt32(units.count)) + units.reduce(Data()) { $0 + be16($1) })]
        switch layer.group {
        case .open: blocks.append(("lsct", be32(1) + Data("8BIM".utf8) + Data(layer.blendKey.utf8)))
        case .closed: blocks.append(("lsct", be32(2) + Data("8BIM".utf8) + Data(layer.blendKey.utf8)))
        case .end: blocks.append(("lsct", be32(3)))
        case .none: break
        }
        for key in layer.blocks.keys.sorted() where key.utf8.count == 4 && key != "luni" && key != "lsct" { blocks.append((key, layer.blocks[key]!)) }
        for (key, body) in blocks {
            var padded = body
            if padded.count % 2 == 1 { padded.append(0) }
            extra += Data("8BIM".utf8) + Data(key.utf8) + be32(UInt32(padded.count)) + padded
        }
        return d + be32(UInt32(extra.count)) + extra
    }

    /// One plane, run-length compressed: the two-byte count of each row, then the rows.
    private static func plane(_ raw: Data, width: Int, height: Int, bytes: Int) -> Data {
        let rowBytes = width * bytes
        guard rowBytes > 0, height > 0 else { return be16(0) }
        var counts = Data(), rows = Data()
        for y in 0..<height {
            let packed = packBits(raw.subdata(in: (raw.startIndex + y * rowBytes)..<(raw.startIndex + (y + 1) * rowBytes)))
            counts += be16(UInt16(packed.count)); rows += packed
        }
        return be16(1) + counts + rows
    }

    /// PackBits: runs of three or more equal bytes as a count and the byte, the rest as literals.
    static func packBits(_ row: Data) -> Data {
        var out = Data()
        let bytes = [UInt8](row)
        var i = 0
        while i < bytes.count {
            var run = 1
            while i + run < bytes.count, run < 128, bytes[i + run] == bytes[i] { run += 1 }
            if run >= 3 {
                out.append(UInt8(bitPattern: Int8(1 - run))); out.append(bytes[i]); i += run
                continue
            }
            // Literals up to the next run of three, at most 128.
            var end = i
            while end < bytes.count, end - i < 128 {
                if end + 2 < bytes.count, bytes[end] == bytes[end + 1], bytes[end] == bytes[end + 2] { break }
                end += 1
            }
            out.append(UInt8(end - i - 1)); out.append(contentsOf: bytes[i..<end]); i = end
        }
        return out
    }

    static func be16(_ v: UInt16) -> Data { Data([UInt8(v >> 8), UInt8(v & 0xFF)]) }
    static func be32(_ v: UInt32) -> Data { be16(UInt16(v >> 16)) + be16(UInt16(v & 0xFFFF)) }
}
#endif
