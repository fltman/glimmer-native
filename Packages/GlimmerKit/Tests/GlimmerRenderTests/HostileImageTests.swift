import CoreGraphics
import Foundation
@testable import GlimmerCore
@testable import GlimmerRender
import ImageIO
import Testing
import UniformTypeIdentifiers
import zlib

/// Image files are untrusted input (the web, sibling apps, agents). These generate broken,
/// lying and oversized files in every format Glimmer opens and check that opening them
/// never crashes, hangs or decodes without bound: each either opens or is refused.
/// The generators are also used to write fixtures for the live API check
/// (`GLIMMER_FIXTURE_DIR=<dir> swift test --filter HostileImageTests`).
enum HostileFiles {
    /// A small valid picture (a colour ramp with noise, so every codec has something to chew on).
    static func picture(width: Int = 96, height: Int = 64) -> CGImage {
        var px = [UInt8](repeating: 255, count: width * height * 4)
        var seed: UInt32 = 7
        for y in 0..<height {
            for x in 0..<width {
                seed = seed &* 1_664_525 &+ 1_013_904_223
                let i = (y * width + x) * 4
                px[i] = UInt8(x * 255 / width)
                px[i + 1] = UInt8(y * 255 / height)
                px[i + 2] = UInt8(seed >> 24)
            }
        }
        let provider = CGDataProvider(data: Data(px) as CFData)!
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    }

    static func encoded(_ image: CGImage, _ type: UTType) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, nil)
        return CGImageDestinationFinalize(dest) ? data as Data : nil
    }

    static func be32(_ v: UInt32) -> [UInt8] { [UInt8(v >> 24), UInt8(v >> 16 & 255), UInt8(v >> 8 & 255), UInt8(v & 255)] }
    static func be16(_ v: UInt16) -> [UInt8] { [UInt8(v >> 8), UInt8(v & 255)] }

    /// A minimal flat PSD: header, three empty sections, raw planar RGB.
    static func psd(width: Int, height: Int, withPixels: Bool = true) -> Data {
        var d: [UInt8] = Array("8BPS".utf8) + be16(1) + [0, 0, 0, 0, 0, 0] + be16(3)
        d += be32(UInt32(height)) + be32(UInt32(width)) + be16(8) + be16(3)
        d += be32(0) + be32(0) + be32(0) + be16(0)
        if withPixels { d += [UInt8](repeating: 128, count: width * height * 3) }
        return Data(d)
    }

    static func pngChunk(_ type: String, _ body: [UInt8]) -> [UInt8] {
        let t = Array(type.utf8)
        let crc = (t + body).withUnsafeBufferPointer { UInt32(crc32(0, $0.baseAddress, UInt32($0.count))) }
        return be32(UInt32(body.count)) + t + body + be32(crc)
    }

    static let pngSignature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]

    /// A well-formed PNG whose header claims `width` × `height` (1-bit grey) over one tiny IDAT.
    static func pngClaiming(width: UInt32, height: UInt32) -> Data {
        let ihdr = be32(width) + be32(height) + [1, 0, 0, 0, 0]
        let idat: [UInt8] = [0x78, 0x9C, 0x63, 0x60, 0x00, 0x00, 0x00, 0x02, 0x00, 0x01]  // zlib of two zero bytes
        return Data(pngSignature + pngChunk("IHDR", ihdr) + pngChunk("IDAT", idat) + pngChunk("IEND", []))
    }

    /// A real decompression bomb: a valid 1-bit PNG of `side` × `side` zeros. The file is
    /// around a hundred kilobytes; decoded as RGBA it would be side² × 4 bytes.
    static func pngBomb(side: Int) -> Data {
        let rowBytes = 1 + (side + 7) / 8
        var stream = z_stream()
        deflateInit_(&stream, Z_BEST_COMPRESSION, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
        var out = [UInt8]()
        var buffer = [UInt8](repeating: 0, count: 1 << 16)
        let row = [UInt8](repeating: 0, count: rowBytes)
        for y in 0..<side {
            row.withUnsafeBufferPointer { src in
                stream.next_in = UnsafeMutablePointer(mutating: src.baseAddress)
                stream.avail_in = UInt32(rowBytes)
                repeat {
                    buffer.withUnsafeMutableBufferPointer { dst in
                        stream.next_out = dst.baseAddress
                        stream.avail_out = UInt32(dst.count)
                        deflate(&stream, y == side - 1 ? Z_FINISH : Z_NO_FLUSH)
                        out.append(contentsOf: dst.prefix(dst.count - Int(stream.avail_out)))
                    }
                } while stream.avail_out == 0
            }
        }
        deflateEnd(&stream)
        let ihdr = be32(UInt32(side)) + be32(UInt32(side)) + [1, 0, 0, 0, 0]
        return Data(pngSignature + pngChunk("IHDR", ihdr) + pngChunk("IDAT", out) + pngChunk("IEND", []))
    }

    /// A little-endian TIFF header whose only directory claims `width` × `height` with no pixel data.
    static func tiffClaiming(width: UInt32, height: UInt32) -> Data {
        func le16(_ v: UInt16) -> [UInt8] { [UInt8(v & 255), UInt8(v >> 8)] }
        func le32(_ v: UInt32) -> [UInt8] { [UInt8(v & 255), UInt8(v >> 8 & 255), UInt8(v >> 16 & 255), UInt8(v >> 24)] }
        func entry(_ tag: UInt16, _ type: UInt16, _ value: UInt32) -> [UInt8] { le16(tag) + le16(type) + le32(1) + le32(value) }
        var d: [UInt8] = [0x49, 0x49] + le16(42) + le32(8)
        let entries = [entry(256, 4, width), entry(257, 4, height), entry(258, 3, 8), entry(259, 3, 1), entry(262, 3, 1),
                       entry(273, 4, 1000), entry(277, 3, 1), entry(278, 4, height), entry(279, 4, 16)]
        d += le16(UInt16(entries.count)) + entries.flatMap { $0 } + le32(0)
        return Data(d)
    }

    /// Valid files in every format Glimmer opens.
    static func valid() throws -> [(name: String, data: Data)] {
        let image = picture()
        var files: [(String, Data)] = []
        for (name, type) in [("png", UTType.png), ("jpeg", .jpeg), ("heic", .heic), ("tiff", .tiff)] {
            if let data = encoded(image, type) { files.append((name, data)) }
        }
        var rgba = [UInt8](repeating: 255, count: 96 * 64 * 4)
        for i in stride(from: 0, to: rgba.count, by: 4) { rgba[i] = UInt8(i / 4 % 256) }
        files.append(("webp", try WebPEncoder.encode(rgba: rgba, width: 96, height: 64)))
        files.append(("psd", psd(width: 96, height: 64)))
        return files
    }

    /// Every broken variant of the valid files, plus the liars and the garbage.
    static func hostile() throws -> [(name: String, data: Data)] {
        var out: [(String, Data)] = []
        for (name, data) in try valid() {
            for percent in [1, 10, 50, 90, 99] {
                out.append(("\(name)-truncated-\(percent)", data.prefix(max(1, data.count * percent / 100))))
            }
            // Flipped bytes at fixed places (the same file every run).
            var seed: UInt32 = 99
            for round in 0..<6 {
                var bytes = [UInt8](data)
                for _ in 0..<(round + 1) * 4 {
                    seed = seed &* 1_664_525 &+ 1_013_904_223
                    let at = Int(seed >> 8) % bytes.count
                    bytes[at] ^= UInt8(truncatingIfNeeded: seed >> 3) | 1
                }
                out.append(("\(name)-corrupt-\(round)", Data(bytes)))
            }
            out.append(("\(name)-header-only", data.prefix(16)))
            out.append(("\(name)-then-garbage", data.prefix(64) + Data(repeating: 0xA5, count: 4096)))
        }
        out.append(("empty", Data()))
        out.append(("one-byte", Data([0xFF])))
        out.append(("text", Data("this is not an image\n".utf8)))
        out.append(("zeros", Data(repeating: 0, count: 65_536)))
        out.append(("random", Data((0..<65_536).map { UInt8(truncatingIfNeeded: $0 &* 2_654_435_761 >> 7) })))
        out.append(("png-claims-100000x100000", pngClaiming(width: 100_000, height: 100_000)))
        out.append(("png-claims-max", pngClaiming(width: 0x7FFF_FFFF, height: 0x7FFF_FFFF)))
        out.append(("png-claims-zero", pngClaiming(width: 0, height: 0)))
        out.append(("png-claims-wide", pngClaiming(width: 32_768, height: 30_000)))
        out.append(("psd-claims-300000x300000", psd(width: 300_000, height: 300_000, withPixels: false)))
        out.append(("psd-claims-30000x30000-no-pixels", psd(width: 30_000, height: 30_000, withPixels: false)))
        out.append(("tiff-claims-200000x200000", tiffClaiming(width: 200_000, height: 200_000)))
        out.append(("tiff-claims-20000x20000-no-pixels", tiffClaiming(width: 20_000, height: 20_000)))
        return out
    }
}

@Suite struct HostileImageTests {
    private static func megabytes() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let ok = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return ok == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : 0
    }

    /// Opens `data` the way every path into Glimmer does. Returns what happened.
    private static func open(_ data: Data) -> String {
        do {
            let image = try ImageImporter.image(from: data)
            guard image.width >= 1, image.height >= 1, image.width * image.height <= ImageImporter.maxPixels else {
                return "opened with a bad size \(image.width)×\(image.height)"
            }
            _ = try ImageImporter.tiles(from: image)
            return "opened \(image.width)×\(image.height)"
        } catch let e as ImageImportError {
            return "refused: \(e.errorDescription ?? "")"
        } catch {
            return "other error: \(error)"
        }
    }

    @Test func theValidFilesOpen() throws {
        let files = try HostileFiles.valid()
        #expect(Set(files.map(\.name)) == ["png", "jpeg", "heic", "tiff", "webp", "psd"], "every format has a generator")
        for (name, data) in files { #expect(Self.open(data) == "opened 96×64", "\(name)") }
    }

    @Test func brokenFilesAreRefusedOrOpenedButNeverCrashHangOrBalloon() throws {
        let files = try HostileFiles.hostile()
        #expect(files.count > 80)
        let before = Self.megabytes()
        var slow: [String] = [], odd: [String] = []
        for (name, data) in files {
            let start = Date()
            let result = Self.open(data)
            let seconds = Date().timeIntervalSince(start)
            if seconds > 5 { slow.append("\(name) \(seconds)") }
            if !(result.hasPrefix("refused: The image") || result.hasPrefix("opened ")) || result.contains("bad size") { odd.append("\(name): \(result)") }
            // A file that is cut short never opens as half a picture.
            if name.contains("truncated") || name.contains("header-only") || name.contains("then-garbage") {
                if !result.hasPrefix("refused") { odd.append("\(name) opened: \(result)") }
            }
        }
        #expect(slow.isEmpty, "\(slow)")
        #expect(odd.isEmpty, "\(odd)")
        #expect(Self.megabytes() - before < 600, "memory stays bounded over \(files.count) hostile files")
    }

    @Test func wholeFilesWithSomethingAppendedStillOpen() throws {
        // Phones append a video after a JPEG (motion photos), and tools append data after a PNG.
        let trailer = Data(repeating: 0x5A, count: 300_000)
        for (name, data) in try HostileFiles.valid() where ["png", "jpeg"].contains(name) {
            #expect(Self.open(data + trailer) == "opened 96×64", "\(name) with a trailer")
        }
        // A progressive, larger JPEG with restart-free scans and an embedded thumbnail-like marker run.
        let big = try #require(HostileFiles.encoded(HostileFiles.picture(width: 1200, height: 800), .jpeg))
        #expect(Self.open(big) == "opened 1200×800")
        #expect(Self.open(big.prefix(big.count - 2)).hasPrefix("refused"), "without its end marker it is cut short")
    }

    @Test func aFileThatClaimsAHugePictureIsRefusedOnItsHeader() throws {
        for (name, data) in try HostileFiles.hostile() where name.contains("claims") {
            let start = Date()
            let result = Self.open(data)
            #expect(result.hasPrefix("refused"), "\(name): \(result)")
            #expect(Date().timeIntervalSince(start) < 1, "\(name) is refused without decoding")
        }
        let message = ImageImportError.tooLarge(100_000, 100_000).errorDescription ?? ""
        #expect(message.contains("100000 × 100000") && message.contains("256 megapixels"))
    }

    @Test func aDecompressionBombIsRefusedWithoutBeingDecoded() {
        // 30 000 × 30 000 pixels in a file of about 100 kB; as RGBA it would take 3.6 GB.
        let bomb = HostileFiles.pngBomb(side: 30_000)
        #expect(bomb.count < 2_000_000, "\(bomb.count) bytes")
        let before = Self.megabytes()
        let start = Date()
        let result = Self.open(bomb)
        #expect(result.hasPrefix("refused: The image is too large (30000 × 30000"), "\(result)")
        #expect(Date().timeIntervalSince(start) < 2)
        #expect(Self.megabytes() - before < 200)
    }

    @Test func aLargeButAllowedPictureStillOpens() throws {
        // 12 000 × 8 000 (96 megapixels) is under the limit and must still open.
        let side = (12_000, 8_000)
        #expect(side.0 * side.1 <= ImageImporter.maxPixels)
        let image = try ImageImporter.image(from: HostileFiles.pngClaimingFlat(width: side.0, height: side.1))
        #expect(image.width == 12_000 && image.height == 8_000)
    }

    /// Writes the fixtures for the live API check when asked to.
    @Test func writesFixturesWhenAsked() throws {
        guard let dir = ProcessInfo.processInfo.environment["GLIMMER_FIXTURE_DIR"], !dir.isEmpty else { return }
        let url = URL(fileURLWithPath: dir, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        for (name, data) in try HostileFiles.hostile() + [("png-bomb-30000", HostileFiles.pngBomb(side: 30_000))] {
            try data.write(to: url.appendingPathComponent(name + ".bin"))
        }
        for (name, data) in try HostileFiles.valid() { try data.write(to: url.appendingPathComponent("valid-" + name + ".bin")) }
    }
}

extension HostileFiles {
    /// A valid, fully encoded 1-bit PNG of zeros (like the bomb, at an allowed size).
    static func pngClaimingFlat(width: Int, height: Int) -> Data {
        let rowBytes = 1 + (width + 7) / 8
        var raw = [UInt8](repeating: 0, count: rowBytes * height)
        var bound = compressBound(UInt(raw.count))
        var out = [UInt8](repeating: 0, count: Int(bound))
        compress2(&out, &bound, &raw, UInt(raw.count), Z_BEST_SPEED)
        let ihdr = be32(UInt32(width)) + be32(UInt32(height)) + [1, 0, 0, 0, 0]
        return Data(pngSignature + pngChunk("IHDR", ihdr) + pngChunk("IDAT", Array(out.prefix(Int(bound)))) + pngChunk("IEND", []))
    }
}
