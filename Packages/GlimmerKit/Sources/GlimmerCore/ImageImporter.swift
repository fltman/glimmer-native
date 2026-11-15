import CoreGraphics
import Foundation
import ImageIO

public enum ImageImportError: Error, LocalizedError {
    case unreadable
    case tooLarge(Int, Int)
    /// The file starts like an image but is cut short or broken inside.
    case damaged

    public var errorDescription: String? {
        switch self {
        case .unreadable: "The image could not be read."
        case .damaged: "The image file is damaged or incomplete."
        case .tooLarge(let w, let h):
            "The image is too large (\(w) × \(h) pixels). Glimmer opens images up to \(ImageImporter.maxPixels / 1_000_000) megapixels and \(DocumentManifest.maxDimension) pixels a side."
        }
    }
}

/// Decodes images (any ImageIO format, honouring EXIF orientation and ICC
/// profiles) into linear, premultiplied Float16 tiles.
public enum ImageImporter {
    /// The colour space all document pixels are stored in.
    public static let workingColorSpace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!

    /// The most pixels an opened image may have (256 megapixels: 16 000 × 16 000, well past
    /// any camera). Decoded, such an image takes about 1 GB, and 2 GB as tiles.
    public static let maxPixels = 256_000_000

    public static func image(from data: Data) throws -> CGImage {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            throw ImageImportError.unreadable
        }
        return try image(from: source, data: data)
    }

    public static func image(contentsOf url: URL) throws -> CGImage {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { throw ImageImportError.unreadable }
        return try image(from: data)
    }

    /// Whether a PNG, JPEG, HEIC/AVIF, TIFF or WebP file has its end: ImageIO decodes what it
    /// can of a file that is cut short and fills the rest with grey or black, without saying
    /// so. Other formats pass (ImageIO refuses most of their broken files itself).
    static func looksComplete(_ data: Data) -> Bool {
        let n = data.count
        guard n >= 12 else { return true }
        return data.withUnsafeBytes { (b: UnsafeRawBufferPointer) -> Bool in
            func be32(_ i: Int) -> Int { Int(b[i]) << 24 | Int(b[i + 1]) << 16 | Int(b[i + 2]) << 8 | Int(b[i + 3]) }
            func tag(_ i: Int, _ t: String) -> Bool { i + t.utf8.count <= n && zip(t.utf8, b[i..<(i + t.utf8.count)]).allSatisfy { $0 == $1 } }
            if b[0] == 0x89, tag(1, "PNG") {
                // Walk the chunks to IEND (whatever follows it, such as an appended file, is ignored).
                var at = 8
                while at + 12 <= n {
                    let length = be32(at)
                    if tag(at + 4, "IEND") { return true }
                    guard length >= 0, at + 12 + length <= n else { return false }
                    at += 12 + length
                }
                return false
            }
            if b[0] == 0xFF, b[1] == 0xD8 {
                // Walk the segments to the end-of-image marker of the first picture (phones
                // append a video or a second picture after it; that is fine).
                var at = 2
                while at + 4 <= n {
                    guard b[at] == 0xFF else { return false }
                    let marker = b[at + 1]
                    if marker == 0xD9 { return true }
                    if marker == 0xFF { at += 1; continue }  // fill byte
                    if marker == 0x01 || (0xD0...0xD7).contains(marker) { at += 2; continue }
                    let length = Int(b[at + 2]) << 8 | Int(b[at + 3])
                    guard length >= 2, at + 2 + length <= n else { return false }
                    at += 2 + length
                    if marker == 0xDA {
                        // Entropy-coded data runs to the next real marker.
                        while at + 1 < n, !(b[at] == 0xFF && b[at + 1] != 0x00 && !(0xD0...0xD7).contains(b[at + 1])) { at += 1 }
                    }
                }
                return at + 1 < n && b[at] == 0xFF && b[at + 1] == 0xD9
            }
            if tag(0, "RIFF"), tag(8, "WEBP") {
                let size = Int(b[4]) | Int(b[5]) << 8 | Int(b[6]) << 16 | Int(b[7]) << 24
                return size + 8 == n || size + 9 == n
            }
            if tag(4, "ftyp") {
                // ISO media boxes must tile the file exactly.
                var at = 0
                while at + 8 <= n {
                    var size = be32(at)
                    if size == 1 {
                        guard at + 16 <= n, be32(at + 8) == 0 else { return false }
                        size = be32(at + 12)
                    } else if size == 0 {
                        return true  // "to the end of the file"
                    }
                    guard size >= 8, at + size <= n else { return false }
                    at += size
                }
                return at == n
            }
            let little = b[0] == 0x49 && b[1] == 0x49, big = b[0] == 0x4D && b[1] == 0x4D
            if little || big {
                func u16(_ i: Int) -> Int { little ? Int(b[i]) | Int(b[i + 1]) << 8 : Int(b[i]) << 8 | Int(b[i + 1]) }
                func u32(_ i: Int) -> Int {
                    little ? Int(b[i]) | Int(b[i + 1]) << 8 | Int(b[i + 2]) << 16 | Int(b[i + 3]) << 24 : be32(i)
                }
                guard u16(2) == 42 else { return true }  // BigTIFF and others: left to ImageIO
                let ifd = u32(4)
                guard ifd + 2 <= n else { return false }
                let count = u16(ifd)
                guard ifd + 2 + count * 12 <= n else { return false }
                // Every strip or tile (offset + byte count) must lie inside the file.
                func values(_ entry: Int) -> [Int]? {
                    let type = u16(entry + 2), k = u32(entry + 4)
                    let width = type == 3 ? 2 : (type == 4 ? 4 : 0)
                    guard width > 0, k >= 1, k <= 1_000_000 else { return nil }
                    let base = k * width <= 4 ? entry + 8 : u32(entry + 8)
                    guard base + k * width <= n else { return nil }
                    return (0..<k).map { width == 2 ? u16(base + $0 * 2) : u32(base + $0 * 4) }
                }
                var offsets: [Int]?, lengths: [Int]?
                let unit = [1: 1, 2: 1, 6: 1, 7: 1, 3: 2, 8: 2, 4: 4, 9: 4, 11: 4, 13: 4, 5: 8, 10: 8, 12: 8]
                for e in 0..<count {
                    let entry = ifd + 2 + e * 12
                    // Whatever an entry points at (a colour profile, metadata) must be in the file too.
                    if let size = unit[u16(entry + 2)] {
                        let bytes = u32(entry + 4) * size
                        if bytes > 4, u32(entry + 8) + bytes > n { return false }
                    }
                    switch u16(entry) {
                    case 273, 324:
                        guard let v = values(entry) else { return false }
                        offsets = v
                    case 279, 325:
                        guard let v = values(entry) else { return false }
                        lengths = v
                    default: break
                    }
                }
                if let offsets, let lengths, offsets.count == lengths.count {
                    return zip(offsets, lengths).allSatisfy { $0 + $1 <= n }
                }
                return true
            }
            return true
        }
    }

    private static func image(from source: CGImageSource, data: Data) throws -> CGImage {
        guard let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int,
              let h = props[kCGImagePropertyPixelHeight] as? Int else {
            throw ImageImportError.unreadable
        }
        // Checked on the header, before anything is decoded: a small file can claim a huge
        // picture (a decompression bomb), and decoding is what takes the memory.
        guard w >= 1, h >= 1, w <= DocumentManifest.maxDimension, h <= DocumentManifest.maxDimension,
              w * h <= maxPixels else {
            throw ImageImportError.tooLarge(w, h)
        }
        guard looksComplete(data) else { throw ImageImportError.damaged }
        // The thumbnail API is the one that applies EXIF orientation; asking for
        // the full size gives an upright, full-resolution image.
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(w, h),
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw ImageImportError.damaged
        }
        // ImageIO decodes what it can of a file that is cut short or broken (the rest comes out
        // grey or black). Say so instead of opening half a picture.
        guard CGImageSourceGetStatus(source) == .statusComplete,
              CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete else {
            throw ImageImportError.damaged
        }
        return image
    }

    /// Converts `image` to tiles with its top-left at `origin` (document pixels).
    public static func tiles(from image: CGImage, origin: SIMD2<Int> = .zero) throws -> TileGrid {
        let width = image.width, height = image.height
        let s = TileGeometry.size
        // Work in tile-aligned strips so memory stays bounded for huge images.
        let startTileX = PixelRect.floorDiv(origin.x, s), endTileX = PixelRect.floorDiv(origin.x + width - 1, s)
        let startTileY = PixelRect.floorDiv(origin.y, s), endTileY = PixelRect.floorDiv(origin.y + height - 1, s)
        let stripWidth = (endTileX - startTileX + 1) * s
        let bytesPerRow = stripWidth * TileGeometry.bytesPerPixel
        let bitmapInfo = CGBitmapInfo.floatComponents.rawValue
            | CGBitmapInfo.byteOrder16Little.rawValue
            | CGImageAlphaInfo.premultipliedLast.rawValue

        var grid = TileGrid()
        for ty in startTileY...endTileY {
            guard let ctx = CGContext(data: nil, width: stripWidth, height: s, bitsPerComponent: 16,
                                      bytesPerRow: bytesPerRow, space: workingColorSpace,
                                      bitmapInfo: bitmapInfo) else {
                throw ImageImportError.unreadable
            }
            ctx.interpolationQuality = .none
            ctx.setBlendMode(.copy)
            // Strip covers document rows [ty*s, ty*s + s) and columns from startTileX*s.
            // CG is y-up: image row r (top-down, doc y = origin.y + r) lands at strip
            // memory row (doc y - ty*s) when drawn at y = s - (origin.y + height - ty*s).
            let drawX = origin.x - startTileX * s
            let drawY = s - (origin.y + height - ty * s)
            ctx.draw(image, in: CGRect(x: drawX, y: drawY, width: width, height: height))
            guard let base = ctx.data else { throw ImageImportError.unreadable }

            for tx in startTileX...endTileX {
                let offset = (tx - startTileX) * s * TileGeometry.bytesPerPixel
                if let tile = Tile.make(pixels: UnsafeRawPointer(base + offset), bytesPerRow: bytesPerRow) {
                    grid[TileCoord(tx, ty)] = tile
                }
            }
        }
        return grid
    }
}
