import CoreGraphics
import Foundation

/// 256-bin histograms of an sRGB image (red, green, blue and luminance),
/// counting only visible pixels.
public struct Histogram: Equatable, Sendable {
    public var red: [UInt32]
    public var green: [UInt32]
    public var blue: [UInt32]
    public var luminance: [UInt32]

    public init(red: [UInt32], green: [UInt32], blue: [UInt32], luminance: [UInt32]) {
        self.red = red
        self.green = green
        self.blue = blue
        self.luminance = luminance
    }

    /// Straight-alpha RGBA8 pixels; pixels with alpha below 1/255 are skipped.
    public init(rgba pixels: [UInt8]) {
        var r = [UInt32](repeating: 0, count: 256), g = r, b = r, l = r
        var i = 0
        while i + 3 < pixels.count {
            if pixels[i + 3] > 0 {
                let pr = Int(pixels[i]), pg = Int(pixels[i + 1]), pb = Int(pixels[i + 2])
                r[pr] += 1
                g[pg] += 1
                b[pb] += 1
                // Rec. 709 luma on the encoded values, like Photoshop's RGB histogram.
                l[min((pr * 2126 + pg * 7152 + pb * 722 + 5000) / 10000, 255)] += 1
            }
            i += 4
        }
        self.init(red: r, green: g, blue: b, luminance: l)
    }

    /// Histogram of a CGImage, drawn into an sRGB buffer of at most `maxSide` pixels.
    public init?(image: CGImage, maxSide: Int = 512) {
        let scale = min(1, Double(maxSide) / Double(max(image.width, image.height)))
        let w = max(1, Int(Double(image.width) * scale)), h = max(1, Int(Double(image.height) * scale))
        var px = [UInt8](repeating: 0, count: w * h * 4)
        let ok = px.withUnsafeMutableBytes { buffer -> Bool in
            guard let ctx = CGContext(data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.interpolationQuality = .medium
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard ok else { return nil }
        // Un-premultiply so colours of soft edges land in the right bins.
        for i in stride(from: 0, to: px.count, by: 4) where px[i + 3] > 0 && px[i + 3] < 255 {
            let a = Double(px[i + 3]) / 255
            for c in 0..<3 { px[i + c] = UInt8(min(Double(px[i + c]) / a, 255).rounded()) }
        }
        self.init(rgba: px)
    }

    public func bins(_ channel: CurveChannel) -> [UInt32] {
        switch channel {
        case .rgb: luminance
        case .red: red
        case .green: green
        case .blue: blue
        }
    }
}

extension DocumentState {
    /// The document as a layer receives it: the layer itself and everything
    /// stacked above it (later in `allLayers`) hidden.
    public func below(_ id: UUID) -> DocumentState {
        let order = allLayers.map(\.id)
        guard let index = order.firstIndex(of: id) else { return self }
        var copy = self
        for hidden in order[index...] { copy.updateLayer(hidden) { $0.isVisible = false } }
        copy.selection = nil
        return copy
    }
}
