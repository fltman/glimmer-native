import Accelerate
import CoreGraphics
import Foundation
import GlimmerCore
import ImageIO
import UniformTypeIdentifiers

/// Straight (non-premultiplied) 8-bit-range RGBA image as floats 0...255.
/// Mirrors the Pillow/numpy representation the web app's pipelines use, so the
/// ported maths behaves the same.
public struct RGBAImage: Sendable, Equatable {
    public let width: Int
    public let height: Int
    /// Interleaved RGBA, row-major.
    public var pixels: [Float]

    public init(width: Int, height: Int, pixels: [Float]) {
        precondition(pixels.count == width * height * 4)
        self.width = width
        self.height = height
        self.pixels = pixels
    }

    public init(width: Int, height: Int, fill: SIMD4<Float>) {
        self.width = width
        self.height = height
        var p = [Float](repeating: 0, count: width * height * 4)
        for i in stride(from: 0, to: p.count, by: 4) {
            p[i] = fill.x; p[i + 1] = fill.y; p[i + 2] = fill.z; p[i + 3] = fill.w
        }
        self.pixels = p
    }

    static let space = CGColorSpace(name: CGColorSpace.sRGB)!

    /// Converts any CGImage to straight sRGB RGBA.
    public init(_ image: CGImage) {
        let w = image.width, h = image.height
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        bytes.withUnsafeMutableBytes { buffer in
            let ctx = CGContext(data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                space: Self.space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.setBlendMode(.copy)
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        var p = [Float](repeating: 0, count: bytes.count)
        for i in stride(from: 0, to: bytes.count, by: 4) {
            let a = Float(bytes[i + 3])
            let k: Float = a > 0 ? 255 / a : 0  // un-premultiply
            p[i] = min(255, Float(bytes[i]) * k)
            p[i + 1] = min(255, Float(bytes[i + 1]) * k)
            p[i + 2] = min(255, Float(bytes[i + 2]) * k)
            p[i + 3] = a
        }
        self.init(width: w, height: h, pixels: p)
    }

    public var cgImage: CGImage {
        var bytes = [UInt8](repeating: 0, count: pixels.count)
        for i in stride(from: 0, to: pixels.count, by: 4) {
            let a = min(max(pixels[i + 3], 0), 255) / 255
            bytes[i] = UInt8(min(max(pixels[i] * a, 0), 255).rounded())
            bytes[i + 1] = UInt8(min(max(pixels[i + 1] * a, 0), 255).rounded())
            bytes[i + 2] = UInt8(min(max(pixels[i + 2] * a, 0), 255).rounded())
            bytes[i + 3] = UInt8((a * 255).rounded())
        }
        let provider = CGDataProvider(data: Data(bytes) as CFData)!
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: Self.space, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)!
    }

    public func pngData() -> Data {
        let data = NSMutableData()
        let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, cgImage, nil)
        CGImageDestinationFinalize(dest)
        return data as Data
    }

    public func cropped(to r: PixelRect) -> RGBAImage {
        let rect = r.intersection(PixelRect(x: 0, y: 0, width: width, height: height))
        var out = [Float](repeating: 0, count: rect.width * rect.height * 4)
        for y in 0..<rect.height {
            let src = ((rect.y + y) * width + rect.x) * 4
            out.replaceSubrange((y * rect.width * 4)..<((y + 1) * rect.width * 4),
                                with: pixels[src..<(src + rect.width * 4)])
        }
        return RGBAImage(width: rect.width, height: rect.height, pixels: out)
    }

    /// Copies `other` with its top-left at (x, y), overwriting (like Pillow `paste`).
    public mutating func paste(_ other: RGBAImage, x: Int, y: Int) {
        for row in 0..<other.height {
            let ty = y + row
            guard ty >= 0, ty < height else { continue }
            for col in 0..<other.width {
                let tx = x + col
                guard tx >= 0, tx < width else { continue }
                let s = (row * other.width + col) * 4, d = (ty * width + tx) * 4
                pixels[d] = other.pixels[s]; pixels[d + 1] = other.pixels[s + 1]
                pixels[d + 2] = other.pixels[s + 2]; pixels[d + 3] = other.pixels[s + 3]
            }
        }
    }

    /// High-quality resample (never trust a model's output size).
    public func resized(width w: Int, height h: Int) -> RGBAImage {
        guard w != width || h != height else { return self }
        let src = cgImage
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        bytes.withUnsafeMutableBytes { buffer in
            let ctx = CGContext(data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                space: Self.space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.interpolationQuality = .high
            ctx.setBlendMode(.copy)
            ctx.draw(src, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        let image = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4, space: Self.space,
                            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                            provider: CGDataProvider(data: Data(bytes) as CFData)!, decode: nil,
                            shouldInterpolate: true, intent: .defaultIntent)!
        return RGBAImage(image)
    }

    /// Scales so the longer side is at most `maxSide` (keeps aspect).
    public func limited(toMaxSide maxSide: Int) -> RGBAImage {
        let longest = max(width, height)
        guard longest > maxSide else { return self }
        let k = Double(maxSide) / Double(longest)
        return resized(width: max(1, Int((Double(width) * k).rounded())), height: max(1, Int((Double(height) * k).rounded())))
    }

    /// Replaces the alpha channel with `mask` (0...255).
    public func withAlpha(_ mask: GrayImage) -> RGBAImage {
        var out = self
        for i in 0..<(width * height) { out.pixels[i * 4 + 3] = mask.values[i] }
        return out
    }
}

/// Single-channel image as floats 0...255 (Pillow mode "L").
public struct GrayImage: Sendable, Equatable {
    public let width: Int
    public let height: Int
    public var values: [Float]

    public init(width: Int, height: Int, values: [Float]) {
        precondition(values.count == width * height)
        self.width = width
        self.height = height
        self.values = values
    }

    public init(width: Int, height: Int, fill: Float) {
        self.init(width: width, height: height, values: [Float](repeating: fill, count: width * height))
    }

    /// Grey RGBA rendering (for sending masks to models).
    public var rgba: RGBAImage {
        var p = [Float](repeating: 255, count: values.count * 4)
        for (i, v) in values.enumerated() { p[i * 4] = v; p[i * 4 + 1] = v; p[i * 4 + 2] = v }
        return RGBAImage(width: width, height: height, pixels: p)
    }

    public var inverted: GrayImage { GrayImage(width: width, height: height, values: values.map { 255 - $0 }) }

    public func resized(width w: Int, height h: Int) -> GrayImage {
        guard w != width || h != height else { return self }
        let r = rgba.resized(width: w, height: h)
        return GrayImage(width: w, height: h, values: stride(from: 0, to: r.pixels.count, by: 4).map { r.pixels[$0] })
    }

    public mutating func paste(_ other: GrayImage, x: Int, y: Int) {
        for row in 0..<other.height where (0..<height).contains(y + row) {
            for col in 0..<other.width where (0..<width).contains(x + col) {
                values[(y + row) * width + x + col] = other.values[row * other.width + col]
            }
        }
    }
}

/// The web app's image primitives (`workers/aips/pipelines/imaging.py`).
public enum Imaging {
    /// Erode (min filter) then Gaussian-blur a mask into a soft alpha.
    public static func featherMask(_ mask: GrayImage, erode: Int = 2, blur: Double = 3) -> GrayImage {
        var values = mask.values
        let w = mask.width, h = mask.height
        if erode > 0 {
            let k = max(3, erode * 2 + 1)
            values = minFilter(values, width: w, height: h, kernel: k)
        }
        if blur > 0 {
            values = gaussian(values, width: w, height: h, sigma: blur)
        }
        return GrayImage(width: w, height: h, values: values)
    }

    static func minFilter(_ v: [Float], width w: Int, height h: Int, kernel k: Int) -> [Float] {
        var src = v, dst = [Float](repeating: 0, count: v.count)
        src.withUnsafeMutableBufferPointer { s in
            dst.withUnsafeMutableBufferPointer { d in
                var sb = vImage_Buffer(data: s.baseAddress, height: vImagePixelCount(h), width: vImagePixelCount(w), rowBytes: w * 4)
                var db = vImage_Buffer(data: d.baseAddress, height: vImagePixelCount(h), width: vImagePixelCount(w), rowBytes: w * 4)
                _ = vImageMin_PlanarF(&sb, &db, nil, 0, 0, vImagePixelCount(k), vImagePixelCount(k), vImage_Flags(kvImageEdgeExtend))
            }
        }
        return dst
    }

    static func gaussian(_ v: [Float], width w: Int, height h: Int, sigma: Double) -> [Float] {
        let radius = max(1, Int((sigma * 3).rounded(.up)))
        var kernel = (-radius...radius).map { i in Float(exp(-Double(i * i) / (2 * sigma * sigma))) }
        let sum = kernel.reduce(0, +)
        kernel = kernel.map { $0 / sum }
        var src = v, tmp = [Float](repeating: 0, count: v.count), dst = [Float](repeating: 0, count: v.count)
        let n = UInt32(kernel.count)
        src.withUnsafeMutableBufferPointer { s in
            tmp.withUnsafeMutableBufferPointer { t in
                dst.withUnsafeMutableBufferPointer { d in
                    var sb = vImage_Buffer(data: s.baseAddress, height: vImagePixelCount(h), width: vImagePixelCount(w), rowBytes: w * 4)
                    var tb = vImage_Buffer(data: t.baseAddress, height: vImagePixelCount(h), width: vImagePixelCount(w), rowBytes: w * 4)
                    var db = vImage_Buffer(data: d.baseAddress, height: vImagePixelCount(h), width: vImagePixelCount(w), rowBytes: w * 4)
                    let flags = vImage_Flags(kvImageEdgeExtend)
                    _ = vImageConvolve_PlanarF(&sb, &tb, nil, 0, 0, kernel, 1, n, 0, flags)
                    _ = vImageConvolve_PlanarF(&tb, &db, nil, 0, 0, kernel, n, 1, 0, flags)
                }
            }
        }
        return dst
    }

    /// Weighted least squares `ref ≈ gain·src + offset` (one channel, 0...255 scale).
    static func fitGainOffset(src: [Float], ref: [Float], weights: [Float]) -> (gain: Double, offset: Double) {
        var sw = 0.0, sx = 0.0, sy = 0.0, sxx = 0.0, sxy = 0.0
        for i in src.indices {
            let w = Double(weights[i]), x = Double(src[i]), y = Double(ref[i])
            sw += w; sx += w * x; sy += w * y; sxx += w * x * x; sxy += w * x * y
        }
        guard sw >= 1 else { return (1, 0) }
        let denom = sw * sxx - sx * sx
        if abs(denom) < 1e-6 {
            return (1, min(max((sy - sx) / sw, -64), 64))
        }
        let gain = (sw * sxy - sx * sy) / denom
        let offset = (sy - gain * sx) / sw
        return (min(max(gain, 0.5), 2), min(max(offset, -64), 64))
    }

    /// Per-channel gain/offset match of `result` to `original`, fitted only where
    /// `trusted` is high (255 = untouched pixel). Keeps `result`'s alpha.
    public static func colorMatch(_ result: RGBAImage, to original: RGBAImage, trusted: GrayImage) -> RGBAImage {
        let n = result.width * result.height
        let weights = trusted.values.map { $0 / 255 }
        var out = result
        for c in 0..<3 {
            let src = (0..<n).map { result.pixels[$0 * 4 + c] }
            let ref = (0..<n).map { original.pixels[$0 * 4 + c] }
            let (gain, offset) = fitGainOffset(src: src, ref: ref, weights: weights)
            for i in 0..<n {
                out.pixels[i * 4 + c] = Float(min(max(Double(src[i]) * gain + offset, 0), 255)).rounded(.towardZero)
            }
        }
        return out
    }

    /// `original·(1−a) + result·a` in RGBA, `alpha` 0...255.
    public static func blendMasked(_ original: RGBAImage, _ result: RGBAImage, alpha: GrayImage) -> RGBAImage {
        var out = original
        for i in 0..<(original.width * original.height) {
            let a = alpha.values[i] / 255
            for c in 0..<4 {
                let v = original.pixels[i * 4 + c] * (1 - a) + result.pixels[i * 4 + c] * a
                out.pixels[i * 4 + c] = min(max(v, 0), 255).rounded(.towardZero)
            }
        }
        return out
    }

    /// Pads an ROI by `padding` (fraction of its size) on each side and clamps it to the image.
    public static func clampROI(_ roi: PixelRect, width: Int, height: Int, padding: Double = 0.3) -> PixelRect {
        let px = Int((Double(roi.width) * padding).rounded()), py = Int((Double(roi.height) * padding).rounded())
        let r = PixelRect(x: roi.x - px, y: roi.y - py, width: roi.width + 2 * px, height: roi.height + 2 * py)
        return r.intersection(PixelRect(x: 0, y: 0, width: width, height: height))
    }

    // MARK: Lab colour transfer (Reinhard)

    static func toLab(_ r: Float, _ g: Float, _ b: Float) -> SIMD3<Double> {
        func lin(_ c: Float) -> Double { let c = Double(c) / 255; return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        let R = lin(r), G = lin(g), B = lin(b)
        let x = (0.4124564 * R + 0.3575761 * G + 0.1804375 * B) / 0.95047
        let y = 0.2126729 * R + 0.7151522 * G + 0.0721750 * B
        let z = (0.0193339 * R + 0.1191920 * G + 0.9503041 * B) / 1.08883
        func f(_ t: Double) -> Double { t > 0.008856 ? cbrt(t) : 7.787 * t + 16.0 / 116 }
        return SIMD3(116 * f(y) - 16, 500 * (f(x) - f(y)), 200 * (f(y) - f(z)))
    }

    static func fromLab(_ lab: SIMD3<Double>) -> SIMD3<Float> {
        let fy = (lab.x + 16) / 116, fx = fy + lab.y / 500, fz = fy - lab.z / 200
        func inv(_ t: Double) -> Double { t * t * t > 0.008856 ? t * t * t : (t - 16.0 / 116) / 7.787 }
        let x = inv(fx) * 0.95047, y = inv(fy), z = inv(fz) * 1.08883
        let R = 3.2404542 * x - 1.5371385 * y - 0.4985314 * z
        let G = -0.9692660 * x + 1.8760108 * y + 0.0415560 * z
        let B = 0.0556434 * x - 0.2040259 * y + 1.0572252 * z
        func enc(_ c: Double) -> Float {
            let c = min(max(c, 0), 1)
            return Float((c <= 0.0031308 ? c * 12.92 : 1.055 * pow(c, 1 / 2.4) - 0.055) * 255)
        }
        return SIMD3(enc(R), enc(G), enc(B))
    }

    /// Moves `source`'s colours toward `reference` by matching Lab mean and
    /// standard deviation, blended by `strength`. Keeps `source`'s alpha.
    public static func labColorTransfer(_ source: RGBAImage, reference: RGBAImage, strength: Double = 1) -> RGBAImage {
        func stats(_ img: RGBAImage) -> (labs: [SIMD3<Double>], mean: SIMD3<Double>, std: SIMD3<Double>) {
            let n = img.width * img.height
            var labs = [SIMD3<Double>](repeating: .zero, count: n)
            var sum = SIMD3<Double>.zero
            for i in 0..<n {
                let l = toLab(img.pixels[i * 4], img.pixels[i * 4 + 1], img.pixels[i * 4 + 2])
                labs[i] = l
                sum += l
            }
            let mean = sum / Double(max(n, 1))
            var sq = SIMD3<Double>.zero
            for l in labs { sq += (l - mean) * (l - mean) }
            var std = (sq / Double(max(n, 1))).squareRoot()
            for c in 0..<3 where std[c] < 1e-6 { std[c] = 1 }
            return (labs, mean, std)
        }
        let s = stats(source), r = stats(reference)
        var out = source
        let k = Float(min(max(strength, 0), 1))
        for (i, l) in s.labs.enumerated() {
            let t = (l - s.mean) / s.std * r.std + r.mean
            let rgb = fromLab(t)
            for c in 0..<3 {
                let orig = source.pixels[i * 4 + c]
                out.pixels[i * 4 + c] = orig + (rgb[c] - orig) * k
            }
        }
        return out
    }
}
