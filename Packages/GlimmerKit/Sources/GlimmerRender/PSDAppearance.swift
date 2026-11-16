#if GLIMMER_PSD   // Config/Features.xcconfig: not in a release until a file from Photoshop has met it
import CoreGraphics
import Foundation
import GlimmerCore

/// Measures how far Glimmer's picture of an imported Photoshop file is from the flattened
/// picture the file itself carries. A file saved for compatibility holds that picture, so an
/// import can be checked against what the program that wrote it saw.
public enum PSDAppearance {
    /// The mean difference per channel (0…255) and the share of pixels that differ by more
    /// than 8 in some channel, both over sRGB with the pictures laid on white. Nil when the
    /// file's own picture can't be read or the sizes differ.
    public static func difference(of state: DocumentState, from file: Data, context: MetalContext) -> (mean: Double, shareVisible: Double)? {
        guard let theirs = flattenedPicture(in: file) ?? (try? ImageImporter.image(from: file)), theirs.width == state.width, theirs.height == state.height,
              let ours = try? ImageExporter.flattenedSRGB(state, context: context),
              let a = onWhite(ours), let b = onWhite(theirs), a.count == b.count, !a.isEmpty else { return nil }
        return difference(a, b)
    }

    /// The flattened picture as the file stores it: its colour planes, in the file's profile,
    /// taken as they are. A file with a transparent background stores this picture already laid
    /// on white, with the transparency in a further channel; a general image reader applies
    /// that channel once more and gets a paler picture (seen with files from Photoshop,
    /// 2026-11-16), so the planes are read directly and the extra channel is left alone.
    static func flattenedPicture(in file: Data) -> CGImage? {
        guard let psd = try? PSDFile(file), psd.header.mode == .rgb, psd.composite.count >= 3, psd.header.depth == 8 || psd.header.depth == 16 else { return nil }
        let width = psd.header.width, height = psd.header.height, bytes = psd.header.depth / 8
        let count = width * height * bytes
        guard psd.composite.prefix(3).allSatisfy({ $0.count == count }) else { return nil }
        var interleaved = Data(count: width * height * 3 * bytes)
        interleaved.withUnsafeMutableBytes { (out: UnsafeMutableRawBufferPointer) in
            let o = out.bindMemory(to: UInt8.self)
            for (c, plane) in psd.composite.prefix(3).enumerated() {
                plane.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                    let p = raw.bindMemory(to: UInt8.self)
                    for i in 0..<(width * height) { for b in 0..<bytes { o[(i * 3 + c) * bytes + b] = p[i * bytes + b] } }
                }
            }
        }
        var space = CGColorSpace(name: CGColorSpace.sRGB)!
        if let icc = psd.iccProfile, let profile = CGColorSpace(iccData: icc as CFData), profile.model == .rgb { space = profile }
        var info = CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue)
        if bytes == 2 { info.insert(.byteOrder16Big) }
        guard let provider = CGDataProvider(data: interleaved as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: bytes * 8, bitsPerPixel: 3 * bytes * 8, bytesPerRow: width * 3 * bytes, space: space,
                       bitmapInfo: info, provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    /// The same measure for two pictures already as 8-bit sRGB over white, of the same size.
    static func difference(_ a: [UInt8], _ b: [UInt8]) -> (mean: Double, shareVisible: Double) {
        var total = 0, visible = 0
        let pixels = min(a.count, b.count) / 4
        guard pixels > 0 else { return (0, 0) }
        for i in 0..<pixels {
            var worst = 0
            for c in 0..<3 {
                let d = abs(Int(a[i * 4 + c]) - Int(b[i * 4 + c]))
                total += d
                worst = max(worst, d)
            }
            if worst > 8 { visible += 1 }
        }
        return (Double(total) / Double(pixels * 3), Double(visible) / Double(pixels))
    }

    /// The picture as 8-bit sRGB over white, so that transparency compares as what is seen.
    static func onWhite(_ image: CGImage) -> [UInt8]? {
        let width = image.width, height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = bytes.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
            ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return drawn ? bytes : nil
    }
}
#endif
