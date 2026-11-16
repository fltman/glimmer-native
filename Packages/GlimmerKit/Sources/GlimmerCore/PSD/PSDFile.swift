#if GLIMMER_PSD   // Config/Features.xcconfig: not in a release until a file from Photoshop has met it
import Compression
import Foundation

/// A Photoshop file as its parts, read from Adobe's published specification ("Adobe Photoshop
/// File Formats Specification", November 2019: "This document is provided for 3rd parties to
/// read and write the Photoshop native file format."). Own code; nothing copied from other readers.
///
/// A PSD is untrusted input. Nothing is allocated from a number in the file until that number
/// has been checked against the format's limits, Glimmer's own, and the bytes that are left.
public struct PSDFile: Sendable {
    public enum ColorMode: UInt16, Sendable { case bitmap = 0, grayscale = 1, indexed = 2, rgb = 3, cmyk = 4, multichannel = 7, duotone = 8, lab = 9 }

    public struct Header: Sendable, Equatable {
        public var isLarge: Bool          // PSB (version 2)
        public var channels: Int          // 1…56
        public var width: Int, height: Int
        public var depth: Int             // 1, 8, 16 or 32 bits per channel
        public var mode: ColorMode
    }

    public struct Rect: Sendable, Equatable {
        public var top: Int, left: Int, bottom: Int, right: Int
        public init(top: Int, left: Int, bottom: Int, right: Int) { self.top = top; self.left = left; self.bottom = bottom; self.right = right }
        public var width: Int { right - left }
        public var height: Int { bottom - top }
    }

    public enum GroupMark: Sendable, Equatable { case none, open, closed, end }

    public struct Mask: Sendable {
        public var rect: Rect
        public var defaultColor: UInt8    // what the mask is outside its rectangle: 0 or 255
        public var isDisabled: Bool
        /// One byte per pixel, `rect.width` × `rect.height`, when the file had the channel.
        public var pixels: Data?
    }

    public struct Layer: Sendable {
        public var name: String
        public var rect: Rect
        public var blendKey: String       // the four-character key, as in the file ("norm", "mul ")
        public var opacity: UInt8
        public var isClipped: Bool
        public var isVisible: Bool
        public var group: GroupMark
        public var mask: Mask?
        /// The keys of the additional-information blocks the layer carries ("TySh", "SoLd", "lfx2" …).
        public var extraKeys: [String]
        /// The bodies of the blocks Glimmer reads further (fills, vector masks, some adjustments, text), each of bounded size.
        public var blocks: [String: Data] = [:]
        /// Decoded planes by channel id (0, 1, 2 = red, green, blue or 0 = gray; -1 = transparency),
        /// each `rect.width` × `rect.height` samples of `bytesPerSample` bytes, big-endian as in the file.
        public var planes: [Int: Data]
        public var bytesPerSample: Int
    }

    public var header: Header
    /// Bottom-most first, as the file stores them.
    public var layers: [Layer]
    /// The flattened image the file carries: planes in channel order, when it could be read.
    public var composite: [Data]
    public var iccProfile: Data?

    public struct Problem: Error, LocalizedError, Equatable, Sendable {
        public let message: String
        public init(_ message: String) { self.message = message }
        public var errorDescription: String? { message }
    }

    /// What a reader may take from a file before it gives up.
    public struct Limits: Sendable {
        /// The most pixels the canvas may have (Glimmer's own limit for this Mac).
        public var maxCanvasPixels: Int
        public var maxLayers = 8_000
        /// The longest a file may take to read. A file built to keep the reader busy is given up on.
        public var seconds: Double = 60
        /// The most bytes of decoded planes for the whole file.
        public var maxDecodedBytes: Int
        public init(maxCanvasPixels: Int = DocumentLimits.maxCanvasPixels(), maxDecodedBytes: Int = DocumentLimits.physicalMemory / 4) {
            self.maxCanvasPixels = maxCanvasPixels
            self.maxDecodedBytes = maxDecodedBytes
        }
    }

    /// The additional-information blocks whose contents the import reads.
    static let keptBlocks: Set<String> = ["SoCo", "vmsk", "vsms", "levl", "curv", "nvrt", "TySh"]

    /// The header alone: cheap, and enough to refuse a file before anything else is read.
    public static func readHeader(_ data: Data) throws -> Header {
        var r = PSDBytes(data)
        guard try r.ascii(4) == "8BPS" else { throw Problem("This isn't a Photoshop file.") }
        let version = try r.u16()
        guard version == 1 || version == 2 else { throw Problem("This Photoshop file has a version Glimmer doesn't know (\(version)).") }
        try r.skip(6)
        let channels = Int(try r.u16()), height = Int(try r.u32()), width = Int(try r.u32())
        let depth = Int(try r.u16())
        guard let mode = ColorMode(rawValue: try r.u16()) else { throw Problem("This Photoshop file has a colour mode Glimmer doesn't know.") }
        let side = version == 2 ? 300_000 : 30_000
        guard (1...56).contains(channels), (1...side).contains(width), (1...side).contains(height), [1, 8, 16, 32].contains(depth) else {
            throw Problem("This Photoshop file's header is damaged.")
        }
        return Header(isLarge: version == 2, channels: channels, width: width, height: height, depth: depth, mode: mode)
    }

    public init(_ data: Data, limits: Limits = Limits()) throws {
        let header = try Self.readHeader(data)
        let (pixels, overflow) = header.width.multipliedReportingOverflow(by: header.height)
        guard !overflow, pixels <= limits.maxCanvasPixels else {
            throw Problem(DocumentLimits.refusal(width: header.width, height: header.height) ?? "The image is too large for this Mac.")
        }
        self.header = header
        var r = PSDBytes(data)
        try r.skip(26)
        try r.skip(Int(try r.u32()))                              // colour mode data
        var resources = try r.slice(Int(try r.u32()))             // image resources
        self.iccProfile = Self.iccProfile(in: &resources)
        var budget = limits.maxDecodedBytes
        let deadline = Date().addingTimeInterval(limits.seconds)
        var section = try r.slice(try r.length(large: header.isLarge))   // layer and mask information
        self.layers = try Self.readLayers(&section, header: header, limits: limits, budget: &budget, deadline: deadline)
        // The flattened image. A file may be cut short here and still give its layers.
        self.composite = (try? Self.readComposite(&r, header: header, budget: &budget)) ?? []
    }

    // MARK: Image resources

    private static func iccProfile(in r: inout PSDBytes) -> Data? {
        while r.remaining >= 12 {
            guard (try? r.ascii(4)) == "8BIM", let id = try? r.u16(), let nameLength = try? r.u8() else { return nil }
            // A Pascal string padded to an even size, counting its length byte.
            guard (try? r.skip(Int(nameLength) + (nameLength % 2 == 0 ? 1 : 0))) != nil, let size = try? r.u32() else { return nil }
            guard let body = try? r.slice(Int(size)) else { return nil }
            if size % 2 == 1 { _ = try? r.skip(1) }
            if id == 1039 { return body.rest }
        }
        return nil
    }

    // MARK: Layers

    static let tookTooLong = Problem("This Photoshop file takes too long to read, so Glimmer gave up on it.")

    private static func readLayers(_ section: inout PSDBytes, header: Header, limits: Limits, budget: inout Int, deadline: Date) throws -> [Layer] {
        guard section.remaining > 0 else { return [] }
        let infoLength = try section.length(large: header.isLarge)
        var info = try section.slice(infoLength)
        var bytesPerSample = max(1, header.depth / 8)
        if infoLength == 0 {
            // 16- and 32-bit documents keep their layers in an additional block ('Lr16', 'Lr32') after the global mask.
            try section.skip(Int(try section.u32()))              // global layer mask info
            guard let block = try findBlock(["Lr16", "Lr32"], in: &section, large: header.isLarge) else { return [] }
            info = block.body
            bytesPerSample = block.key == "Lr32" ? 4 : 2
        }
        guard info.remaining >= 2 else { return [] }
        let count = abs(Int(try info.i16()))
        guard count <= limits.maxLayers else { throw Problem("This Photoshop file says it has \(count) layers, more than Glimmer reads.") }
        var records: [(layer: Layer, channels: [(id: Int, length: Int)])] = []
        for _ in 0..<count {
            guard Date() < deadline else { throw tookTooLong }
            records.append(try readRecord(&info, header: header, bytesPerSample: bytesPerSample))
        }
        var layers: [Layer] = []
        for var record in records {
            for channel in record.channels {
                guard Date() < deadline else { throw tookTooLong }
                var body = try info.slice(channel.length)
                let isMask = channel.id == -2 || channel.id == -3
                let rect = isMask ? record.layer.mask?.rect : record.layer.rect
                guard let rect, rect.width > 0, rect.height > 0 else { continue }
                // A plane no larger than the canvas with a margin: a layer may reach outside it, but not without bound.
                let (samples, overflow) = rect.width.multipliedReportingOverflow(by: rect.height)
                let sampleBytes = isMask ? 1 : bytesPerSample
                guard !overflow, samples <= max(header.width * header.height * 4, 1 << 20), samples * sampleBytes <= budget else {
                    throw Problem("A layer in this Photoshop file is larger than Glimmer can read.")
                }
                let plane = try decodePlane(&body, width: rect.width, height: rect.height, bytesPerSample: sampleBytes, large: header.isLarge)
                budget -= plane.count
                if channel.id == -2 { record.layer.mask?.pixels = plane } else if channel.id != -3 { record.layer.planes[channel.id] = plane }
            }
            layers.append(record.layer)
        }
        return layers
    }

    private static func readRecord(_ r: inout PSDBytes, header: Header, bytesPerSample: Int) throws -> (layer: Layer, channels: [(id: Int, length: Int)]) {
        let rect = Rect(top: Int(try r.i32()), left: Int(try r.i32()), bottom: Int(try r.i32()), right: Int(try r.i32()))
        guard rect.bottom >= rect.top, rect.right >= rect.left, [rect.top, rect.left, rect.bottom, rect.right].allSatisfy({ abs($0) <= 1_000_000 }) else {
            throw Problem("A layer in this Photoshop file has a damaged rectangle.")
        }
        let channelCount = Int(try r.u16())
        guard channelCount <= 60 else { throw Problem("A layer in this Photoshop file has too many channels.") }
        var channels: [(id: Int, length: Int)] = []
        for _ in 0..<channelCount { channels.append((Int(try r.i16()), try r.length(large: header.isLarge))) }
        guard try r.ascii(4) == "8BIM" else { throw Problem("A layer in this Photoshop file is damaged.") }
        let blendKey = try r.ascii(4)
        let opacity = try r.u8(), clipping = try r.u8(), flags = try r.u8()
        try r.skip(1)
        var extra = try r.slice(Int(try r.u32()))
        var layer = Layer(name: "", rect: rect, blendKey: blendKey, opacity: opacity, isClipped: clipping != 0, isVisible: flags & 2 == 0,
                          group: .none, mask: nil, extraKeys: [], planes: [:], bytesPerSample: bytesPerSample)
        // Layer mask data.
        var mask = try extra.slice(Int(try extra.u32()))
        if mask.remaining >= 18 {
            let maskRect = Rect(top: Int(try mask.i32()), left: Int(try mask.i32()), bottom: Int(try mask.i32()), right: Int(try mask.i32()))
            let color = try mask.u8(), maskFlags = try mask.u8()
            if maskRect.bottom >= maskRect.top, maskRect.right >= maskRect.left {
                layer.mask = Mask(rect: maskRect, defaultColor: color, isDisabled: maskFlags & 2 != 0, pixels: nil)
            }
        }
        try extra.skip(Int(try extra.u32()))                      // blending ranges
        // The name: a Pascal string padded to a multiple of four, counting its length byte.
        let nameLength = Int(try extra.u8())
        layer.name = String(decoding: try extra.slice(nameLength).rest, as: UTF8.self)
        try extra.skip((4 - (nameLength + 1) % 4) % 4)
        // Additional layer information.
        while extra.remaining >= 12 {
            let signature = try extra.ascii(4)
            guard signature == "8BIM" || signature == "8B64" else { break }
            let key = try extra.ascii(4)
            let length = try extra.length(large: header.isLarge && PSDBytes.longKeys.contains(key))
            var body = try extra.slice(length)
            if length % 2 == 1, extra.remaining > 0 { try extra.skip(1) }
            layer.extraKeys.append(key)
            if Self.keptBlocks.contains(key), length <= 4 << 20 { layer.blocks[key] = body.rest }
            switch key {
            case "luni":
                let units = Int(try body.u32())
                guard units <= body.remaining / 2 else { break }
                var utf16: [UInt16] = []
                for _ in 0..<units { utf16.append(try body.u16()) }
                layer.name = String(decoding: utf16, as: UTF16.self).trimmingCharacters(in: CharacterSet(charactersIn: "\0"))
            case "lsct", "lsdk":
                switch try body.u32() {
                case 1: layer.group = .open
                case 2: layer.group = .closed
                case 3: layer.group = .end
                default: break
                }
                // The group's own blend mode follows when the block is long enough.
                if body.remaining >= 8, (try? body.ascii(4)) == "8BIM", let key = try? body.ascii(4) { layer.blendKey = key }
            default:
                break
            }
        }
        return (layer, channels)
    }

    private static func findBlock(_ keys: Set<String>, in r: inout PSDBytes, large: Bool) throws -> (key: String, body: PSDBytes)? {
        while r.remaining >= 12 {
            let signature = try r.ascii(4)
            guard signature == "8BIM" || signature == "8B64" else { return nil }
            let key = try r.ascii(4)
            let length = try r.length(large: large && PSDBytes.longKeys.contains(key))
            let body = try r.slice(length)
            // Blocks at this level are padded to a multiple of four.
            let pad = (4 - length % 4) % 4
            if pad > 0, r.remaining >= pad { try r.skip(pad) }
            if keys.contains(key) { return (key, body) }
        }
        return nil
    }

    // MARK: Planes

    /// One channel's samples: `width` × `height` × `bytesPerSample` bytes exactly, whatever the file claims.
    static func decodePlane(_ r: inout PSDBytes, width: Int, height: Int, bytesPerSample: Int, large: Bool) throws -> Data {
        let rowBytes = width * bytesPerSample, size = rowBytes * height
        switch try r.u16() {
        case 0:
            return try r.slice(size).rest
        case 1:
            var counts: [Int] = []
            counts.reserveCapacity(height)
            for _ in 0..<height { counts.append(large ? Int(try r.u32()) : Int(try r.u16())) }
            var out = Data(capacity: size)
            for count in counts { try unpackBits(try r.slice(count).rest, into: &out, expecting: rowBytes) }
            return out
        case 2:
            return try inflate(r.rest, size: size)
        case 3:
            var out = try inflate(r.rest, size: size)
            undoPrediction(&out, width: width, height: height, bytesPerSample: bytesPerSample)
            return out
        default:
            throw Problem("A layer in this Photoshop file is compressed in a way Glimmer doesn't know.")
        }
    }

    /// PackBits, one row. Exactly `expecting` bytes come out or the row is damaged.
    static func unpackBits(_ row: Data, into out: inout Data, expecting: Int) throws {
        var produced = 0, i = row.startIndex
        while i < row.endIndex, produced < expecting {
            let n = Int(Int8(bitPattern: row[i])); i += 1
            if n >= 0 {
                let count = n + 1
                guard i + count <= row.endIndex, produced + count <= expecting else { throw Problem("A layer in this Photoshop file is damaged.") }
                out.append(row[i..<(i + count)]); i += count; produced += count
            } else if n != -128 {
                let count = 1 - n
                guard i < row.endIndex, produced + count <= expecting else { throw Problem("A layer in this Photoshop file is damaged.") }
                out.append(contentsOf: repeatElement(row[i], count: count)); i += 1; produced += count
            }
        }
        guard produced == expecting else { throw Problem("A layer in this Photoshop file is damaged.") }
    }

    /// zlib data into exactly `size` bytes. The output buffer is the declared size and no larger,
    /// so a file that would expand without end stops there.
    static func inflate(_ data: Data, size: Int) throws -> Data {
        guard data.count > 2, size > 0 else { throw Problem("A layer in this Photoshop file is damaged.") }
        // One byte of room beyond the plane: a stream that holds more than the plane is damaged
        // or hostile, and is refused rather than cut to fit.
        var out = Data(count: size + 1)
        let written = out.withUnsafeMutableBytes { (destination: UnsafeMutableRawBufferPointer) -> Int in
            data.dropFirst(2).withUnsafeBytes { (source: UnsafeRawBufferPointer) -> Int in   // past the two-byte zlib header
                compression_decode_buffer(destination.bindMemory(to: UInt8.self).baseAddress!, size + 1,
                                          source.bindMemory(to: UInt8.self).baseAddress!, source.count, nil, COMPRESSION_ZLIB)
            }
        }
        guard written == size else { throw Problem("A layer in this Photoshop file is damaged.") }
        out.removeLast()
        return out
    }

    /// "ZIP with prediction": each row holds differences from the sample to its left.
    static func undoPrediction(_ data: inout Data, width: Int, height: Int, bytesPerSample: Int) {
        guard width > 1 else { return }
        data.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) in
            let p = raw.bindMemory(to: UInt8.self)
            let rowBytes = width * bytesPerSample
            for y in 0..<height {
                let row = y * rowBytes
                if bytesPerSample == 2 {
                    for x in 1..<width {
                        let a = row + x * 2, b = a - 2
                        let sum = (UInt16(p[a]) << 8 | UInt16(p[a + 1])) &+ (UInt16(p[b]) << 8 | UInt16(p[b + 1]))
                        p[a] = UInt8(sum >> 8); p[a + 1] = UInt8(sum & 0xFF)
                    }
                } else if bytesPerSample == 1 {
                    for x in 1..<width { p[row + x] = p[row + x] &+ p[row + x - 1] }
                }
                // 32-bit prediction interleaves bytes differently; 32-bit layers are not read in this version.
            }
        }
    }

    // MARK: The flattened image

    private static func readComposite(_ r: inout PSDBytes, header: Header, budget: inout Int) throws -> [Data] {
        let bytesPerSample = max(1, header.depth / 8)
        guard header.depth >= 8 else { return [] }
        let rowBytes = header.width * bytesPerSample, planeSize = rowBytes * header.height
        guard planeSize * header.channels <= budget else { throw Problem("The image is too large for this Mac.") }
        var planes: [Data] = []
        switch try r.u16() {
        case 0:
            for _ in 0..<header.channels { planes.append(try r.slice(planeSize).rest) }
        case 1:
            var counts: [Int] = []
            for _ in 0..<(header.height * header.channels) { counts.append(header.isLarge ? Int(try r.u32()) : Int(try r.u16())) }
            for channel in 0..<header.channels {
                var out = Data(capacity: planeSize)
                for row in 0..<header.height { try unpackBits(try r.slice(counts[channel * header.height + row]).rest, into: &out, expecting: rowBytes) }
                planes.append(out)
            }
        default:
            return []
        }
        budget -= planeSize * header.channels
        return planes
    }
}

/// A cursor over a file's bytes. Every read checks what is left; nothing trusts a length it was given.
struct PSDBytes {
    private let data: Data
    private var offset: Int

    init(_ data: Data) { self.data = data; self.offset = data.startIndex }

    /// The keys whose blocks have 8-byte lengths in a PSB, as the specification lists them.
    static let longKeys: Set<String> = ["LMsk", "Lr16", "Lr32", "Layr", "Mt16", "Mt32", "Mtrn", "Alph", "FMsk", "lnk2", "FEid", "FXid", "PxSD"]

    var remaining: Int { data.endIndex - offset }
    var rest: Data { data[offset..<data.endIndex] }

    private static let cutShort = PSDFile.Problem("This Photoshop file is cut short or damaged.")

    mutating func skip(_ count: Int) throws {
        guard count >= 0, count <= remaining else { throw Self.cutShort }
        offset += count
    }

    /// The next `count` bytes as a cursor of their own, and this one moved past them.
    mutating func slice(_ count: Int) throws -> PSDBytes {
        guard count >= 0, count <= remaining else { throw Self.cutShort }
        defer { offset += count }
        return PSDBytes(data[offset..<(offset + count)])
    }

    mutating func u8() throws -> UInt8 {
        guard remaining >= 1 else { throw Self.cutShort }
        defer { offset += 1 }
        return data[offset]
    }

    mutating func u16() throws -> UInt16 { UInt16(try u8()) << 8 | UInt16(try u8()) }
    mutating func i16() throws -> Int16 { Int16(bitPattern: try u16()) }
    mutating func u32() throws -> UInt32 { UInt32(try u16()) << 16 | UInt32(try u16()) }
    mutating func i32() throws -> Int32 { Int32(bitPattern: try u32()) }

    /// A section length: four bytes, or eight in a PSB where the specification says so.
    mutating func length(large: Bool) throws -> Int {
        guard large else { return Int(try u32()) }
        let high = try u32(), low = try u32()
        guard high < 0x8000 else { throw Self.cutShort }          // far beyond any file
        return Int(high) << 32 | Int(low)
    }

    mutating func ascii(_ count: Int) throws -> String {
        String(decoding: try slice(count).rest, as: UTF8.self)
    }
}
#endif
