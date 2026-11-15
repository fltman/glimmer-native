import Foundation

/// How large a document this Mac can hold, and when to say that one is getting too big.
///
/// Pixels are kept as 16-bit floating point RGBA (8 bytes a pixel) in memory. Measured on a
/// 6000 × 4000 document with 60 layers (3 full layers, 30 photo layers, 12 smart objects,
/// effects): about 4,100 layer tiles of 512 kB and a footprint of 5.5 GB, so a document needs
/// roughly two and a half times its own tiles (caches for smart objects, effects and the
/// flattened image) plus a base.
public enum DocumentLimits {
    public static let bytesPerPixel = 8
    public static var physicalMemory: Int { Int(clamping: ProcessInfo.processInfo.physicalMemory) }

    /// The most pixels a canvas may have: one full layer may take two fifths of the memory.
    public static func maxCanvasPixels(memory: Int = physicalMemory) -> Int {
        memory / 5 * 2 / bytesPerPixel
    }

    private static func gigabytes(_ bytes: Int) -> String {
        let gb = Double(bytes) / 1_073_741_824
        return gb >= 10 ? String(format: "%.0f GB", gb) : String(format: "%.1f GB", gb)
    }

    /// Why a canvas of this size can't be made on this Mac, or nil when it can. The sides'
    /// own limit (`DocumentManifest.maxDimension`) is checked by the caller.
    public static func refusal(width: Int, height: Int, memory: Int = physicalMemory) -> String? {
        guard width > 0, height > 0 else { return nil }
        let (pixels, overflow) = width.multipliedReportingOverflow(by: height)
        let limit = maxCanvasPixels(memory: memory)
        guard overflow || pixels > limit else { return nil }
        let need = overflow ? "more memory than any Mac has" : gigabytes(pixels * bytesPerPixel)
        let side = Int(Double(limit).squareRoot() / 1000) * 1000
        return "A canvas of \(width) × \(height) pixels needs \(need) for a single layer, and this Mac has \(gigabytes(memory)) of memory. "
            + "The largest canvas here is \(limit / 1_000_000) megapixels, for example \(side) × \(side)."
    }

    /// About how much memory a document with this many pixel tiles takes while it is open.
    public static func estimatedBytes(textureTiles: Int) -> Int {
        textureTiles * TileGeometry.byteCount / 2 * 5 + 400 * 1_048_576
    }

    /// What to tell the person once when a document outgrows this Mac, or nil while it fits
    /// comfortably (under three fifths of the memory).
    public static func comfortNotice(textureTiles: Int, memory: Int = physicalMemory) -> String? {
        let need = estimatedBytes(textureTiles: textureTiles)
        guard need > memory / 5 * 3 else { return nil }
        return "This document needs about \(gigabytes(need)) of memory, and this Mac has \(gigabytes(memory)). Glimmer keeps working, but it may get slow. "
            + "Merging layers you no longer need apart, or making the image smaller with Image › Image Size, helps."
    }
}
