import CoreGraphics
import Foundation
import simd

/// Select Sky: the far, smooth region that reaches the top edge, grown from
/// the top with the depth map and colour continuity (no sky model needed).
public enum SkySelection {
    /// Working size of the region growing; the mask is scaled up afterwards.
    static let side = 512

    /// A soft mask (0…255) of the sky at the image's size, or nil when the top
    /// of the image isn't sky.
    /// - Parameter depth: relative depth at the image's size, near = 255 (see `DepthEstimator`).
    public static func mask(image: CGImage, depth: GrayImage) -> GrayImage? {
        guard let r = region(image: image, depth: depth) else { return nil }
        return upsampled(r.sky, w: r.width, h: r.height, width: image.width, height: image.height)
    }

    struct Region {
        var width: Int
        var height: Int
        /// The grown sky.
        var sky: [Bool]
        /// Pixels that don't look like sky (darker, rougher or a different colour), whatever the depth says.
        var unlike: [Bool]
    }

    /// The grown sky region on the working grid.
    static func region(image: CGImage, depth: GrayImage) -> Region? {
        let k = Double(side) / Double(max(image.width, image.height))
        let w = max(8, Int(Double(image.width) * k)), h = max(8, Int(Double(image.height) * k))
        var px = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .medium
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        func color(_ i: Int) -> SIMD3<Float> { SIMD3(Float(px[i * 4]), Float(px[i * 4 + 1]), Float(px[i * 4 + 2])) / 255 }
        // Depth sampled down to the working size, 0 (far) … 1 (near).
        var d = [Float](repeating: 0, count: w * h)
        for y in 0..<h {
            for x in 0..<w {
                let sx = min(depth.width - 1, x * depth.width / w), sy = min(depth.height - 1, y * depth.height / h)
                d[y * w + x] = depth.values[sy * depth.width + sx] / 255
            }
        }
        // Local roughness: mean colour difference to the 4 neighbours.
        var rough = [Float](repeating: 0, count: w * h)
        for y in 1..<(h - 1) {
            for x in 1..<(w - 1) {
                let i = y * w + x, c = color(i)
                var s: Float = 0
                for j in [i - 1, i + 1, i - w, i + w] { s += simd_length(color(j) - c) }
                rough[i] = s / 4
            }
        }
        func lum(_ i: Int) -> Float { let c = color(i); return 0.2126 * c.x + 0.7152 * c.y + 0.0722 * c.z }
        // Sky is bright next to what stands against it (hills, buildings, trees are silhouettes).
        let topLum = (0..<w).map { lum($0) }.sorted()[w / 2]
        let minLum = topLum * 0.6
        // Seeds: far, smooth pixels along the top edge.
        // Sky is always far: a near top edge (a wall, a ceiling, foliage) is never seeded.
        let farLimit = min(0.4, max(0.12, (d.prefix(w).sorted()[w / 2]) + 0.15))
        var inSky = [Bool](repeating: false, count: w * h)
        var queue: [Int] = []
        for x in 0..<w where d[x] < farLimit && rough[min(w + x, w * h - 1)] < 0.06 {
            inSky[x] = true
            queue.append(x)
        }
        guard queue.count > w / 4 else { return nil }
        var head = 0
        while head < queue.count {
            let i = queue[head]
            head += 1
            let x = i % w, y = i / w, c = color(i)
            for (nx, ny) in [(x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)] where nx >= 0 && ny >= 0 && nx < w && ny < h {
                let j = ny * w + nx
                guard !inSky[j], d[j] < farLimit + 0.05, rough[j] < 0.08, lum(j) > minLum,
                      simd_length(color(j) - c) < 0.045 else { continue }
                // A soft ridge still shows as a clear change over a few pixels: stop there.
                let bx = x - 3 * (nx - x), by = y - 3 * (ny - y)
                if bx >= 0, by >= 0, bx < w, by < h, simd_length(color(j) - color(by * w + bx)) > 0.1 { continue }
                inSky[j] = true
                queue.append(j)
            }
        }
        // Fill small holes (birds, specks): a pixel surrounded by sky is sky.
        var filled = inSky
        for y in 2..<(h - 2) {
            for x in 2..<(w - 2) where !inSky[y * w + x] {
                var n = 0
                for dy in -2...2 { for dx in -2...2 where inSky[(y + dy) * w + x + dx] { n += 1 } }
                if n >= 18 { filled[y * w + x] = true }
            }
        }
        let coverage = Double(filled.filter { $0 }.count) / Double(w * h)
        guard coverage > 0.03 else { return nil }
        var unlike = [Bool](repeating: false, count: w * h)
        let skyColor = filled.indices.filter { filled[$0] }.reduce(SIMD3<Float>.zero) { $0 + color($1) }
            / Float(max(1, filled.filter { $0 }.count))
        for i in 0..<(w * h) where !filled[i] {
            unlike[i] = lum(i) < minLum || rough[i] > 0.08 || simd_length(color(i) - skyColor) > 0.35
        }
        return Region(width: w, height: h, sky: filled, unlike: unlike)
    }

    /// Prompts for Segment Anything: points deep inside the grown sky
    /// (positive) and in the foreground (negative), in image pixels. SAM then
    /// draws the boundary much more precisely than region growing can (a hazy
    /// ridge, cables, leaves).
    public static func prompts(image: CGImage, depth: GrayImage) -> [MagicSelector.Point]? {
        guard let r = region(image: image, depth: depth) else { return nil }
        let w = r.width, h = r.height, sky = r.sky, unlike = r.unlike
        let sx = Double(image.width) / Double(w), sy = Double(image.height) / Double(h)
        func deepInside(_ x: Int, _ y: Int) -> Bool {
            for dy in -6...6 { for dx in -6...6 {
                let xx = x + dx, yy = y + dy
                guard xx >= 0, yy >= 0, xx < w, yy < h, sky[yy * w + xx] else { return false }
            } }
            return true
        }
        var points: [MagicSelector.Point] = []
        // Positives: across the width, in the upper part of the sky.
        for col in 0..<5 {
            let x = (col * 2 + 1) * w / 10
            if let y = stride(from: 6, to: h / 2, by: 4).first(where: { deepInside(x, $0) }) {
                points.append(MagicSelector.Point(SIMD2((Double(x) + 0.5) * sx, (Double(y) + 0.5) * sy), positive: true))
            }
        }
        guard points.count >= 2 else { return nil }
        // Negatives: just below the sky in each column (the skyline), and the bottom row.
        for col in 0..<5 {
            let x = (col * 2 + 1) * w / 10
            if let top = (0..<h).first(where: { sky[$0 * w + x] }),
               let edge = (top..<h).first(where: { unlike[$0 * w + x] }) {
                let y = min(h - 1, edge + max(6, h / 25))
                if !sky[y * w + x], unlike[y * w + x] {
                    points.append(MagicSelector.Point(SIMD2((Double(x) + 0.5) * sx, (Double(y) + 0.5) * sy), positive: false))
                }
            }
            if col % 2 == 0 {
                points.append(MagicSelector.Point(SIMD2((Double(x) + 0.5) * sx, Double(image.height) * 0.95), positive: false))
            }
        }
        return Array(points.prefix(MagicSelector.maxPoints))
    }

    static func upsampled(_ filled: [Bool], w: Int, h: Int, width W: Int, height H: Int) -> GrayImage {
        // Scale up with a soft edge.
        var out = [Float](repeating: 0, count: W * H)
        for y in 0..<H {
            let fy = (Double(y) + 0.5) * Double(h) / Double(H) - 0.5
            let y0 = max(0, min(h - 1, Int(fy.rounded(.down)))), y1 = min(h - 1, y0 + 1)
            let ty = Float(min(max(fy - Double(y0), 0), 1))
            for x in 0..<W {
                let fx = (Double(x) + 0.5) * Double(w) / Double(W) - 0.5
                let x0 = max(0, min(w - 1, Int(fx.rounded(.down)))), x1 = min(w - 1, x0 + 1)
                let tx = Float(min(max(fx - Double(x0), 0), 1))
                func v(_ xx: Int, _ yy: Int) -> Float { filled[yy * w + xx] ? 1 : 0 }
                let top = v(x0, y0) * (1 - tx) + v(x1, y0) * tx, bottom = v(x0, y1) * (1 - tx) + v(x1, y1) * tx
                out[y * W + x] = (top * (1 - ty) + bottom * ty) * 255
            }
        }
        return GrayImage(width: W, height: H, values: out)
    }
}
