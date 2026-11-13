import CoreGraphics
import Foundation
import ImageIO

public enum ImageImportError: Error, LocalizedError {
    case unreadable
    case tooLarge(Int, Int)

    public var errorDescription: String? {
        switch self {
        case .unreadable: "The image could not be read."
        case .tooLarge(let w, let h): "The image is too large (\(w) × \(h) px)."
        }
    }
}

/// Decodes images (any ImageIO format, honouring EXIF orientation and ICC
/// profiles) into linear, premultiplied Float16 tiles.
public enum ImageImporter {
    /// The colour space all document pixels are stored in.
    public static let workingColorSpace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!

    public static func image(from data: Data) throws -> CGImage {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            throw ImageImportError.unreadable
        }
        return try image(from: source)
    }

    public static func image(contentsOf url: URL) throws -> CGImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw ImageImportError.unreadable
        }
        return try image(from: source)
    }

    private static func image(from source: CGImageSource) throws -> CGImage {
        guard let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int,
              let h = props[kCGImagePropertyPixelHeight] as? Int else {
            throw ImageImportError.unreadable
        }
        guard w <= DocumentManifest.maxDimension, h <= DocumentManifest.maxDimension else {
            throw ImageImportError.tooLarge(w, h)
        }
        // The thumbnail API is the one that applies EXIF orientation; asking for
        // the full size gives an upright, full-resolution image.
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(w, h),
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw ImageImportError.unreadable
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
