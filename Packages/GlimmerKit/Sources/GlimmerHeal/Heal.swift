// Heal Selection: fills a selected area from what surrounds it. No model, no network.
//
// HARD RULES for everything in this target (docs/PATENTS.md has the patent numbers and the
// reasons; HealSourceRulesTests checks what can be checked in source). Do not relax one
// without a decision recorded there.
//
//  1. Every patch is searched from scratch over the whole window. No match is ever derived
//     from a neighbour's match, and nothing is randomised.
//  2. Everything runs at full resolution. No reduced-size copy of the image, no pyramid.
//  3. Patches are axis-aligned, 1:1, copied as they are: never rotated, scaled, mirrored or
//     otherwise transformed; overlapping patches are never voted or blended.
//  3b. No gradient-domain (Poisson) seam.
//  4. The fill order is the priority of Criminisi, Pérez and Toyama (2004), unchanged:
//     confidence × data term at the front pixel. No map of structure strength.
//  5. The smooth fill is fast marching (Telea 2004). No differential-equation solve.
//  6. Where to sample is fixed by the hole. There is no "sample from here" input.
//  7. Written from the papers. No code copied or ported from anywhere.
#if GLIMMER_HEAL
import Foundation

public enum Heal {
    public enum Method: String, Sendable, CaseIterable { case auto, smooth, texture }

    public struct Refusal: Error, LocalizedError, Equatable {
        public let reason: String
        public let message: String
        /// True when `allowLarge` doesn't help.
        public var hard = false
        public var errorDescription: String? { message }
    }

    /// Side of the square patches of the texture fill.
    public static let patchSide = 9
    /// Up to this width (the area at its thickest, in pixels) the result is usually good.
    public static let comfortableWidth = 120.0
    /// Beyond this width, or this many pixels, the fill is refused whatever the caller says.
    public static let largestWidth = 250.0
    public static let largestPixels = 4_000_000
    /// A hole at most this wide is filled smoothly when the method is `auto`.
    public static let thinWidth = 6.0

    // MARK: What the selection means

    /// The area to fill, worked out from the selection's coverage over a rectangle.
    public struct Area: Sendable {
        public let width: Int, height: Int
        /// True where pixels are replaced (any coverage after expanding).
        public let hole: [Bool]
        /// How much of the fill shows: 1 in the solid part, falling off over a soft selection edge.
        public let weight: [Float]
        /// Pixels in the solid part.
        public let pixels: Int
        /// How wide the solid part is at its thickest.
        public let thickness: Double
        /// Bounds of `hole` in the rectangle: x, y, width, height.
        public let bounds: (x: Int, y: Int, width: Int, height: Int)
    }

    /// `coverage` is the selection (0…1) over a `width` × `height` rectangle. The part covered
    /// at least half is grown by `expand` pixels and replaced fully; a soft edge outside that
    /// is blended by its coverage. Nil when nothing is covered at least half.
    public static func area(coverage: [Float], width: Int, height: Int, expand: Int) -> Area? {
        precondition(coverage.count == width * height)
        let core = coverage.map { $0 >= 0.5 }
        guard core.contains(true) else { return nil }
        let toCore = distance(to: core, width: width, height: height)
        let reach = Float(expand) + 0.001
        var solid = [Bool](repeating: false, count: core.count)
        var weight = [Float](repeating: 0, count: core.count)
        var hole = [Bool](repeating: false, count: core.count)
        var count = 0
        var minX = width, minY = height, maxX = -1, maxY = -1
        for i in core.indices {
            if toCore[i] <= reach {
                solid[i] = true
                weight[i] = 1
                count += 1
            } else if coverage[i] > 0.02 {
                weight[i] = min(1, 2 * coverage[i])
            }
            if weight[i] > 0 {
                hole[i] = true
                let x = i % width, y = i / width
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        let inside = distance(to: solid.map { !$0 }, width: width, height: height)
        var deepest: Float = 0
        for i in solid.indices where solid[i] { deepest = max(deepest, inside[i]) }
        // A row of n pixels has its middle pixel (n + 1) / 2 from the outside.
        let thickness = deepest.isFinite ? Double(2 * deepest - 1) : Double(max(width, height))
        return Area(width: width, height: height, hole: hole, weight: weight, pixels: count, thickness: max(1, thickness),
                    bounds: (minX, minY, maxX - minX + 1, maxY - minY + 1))
    }

    /// How far the window that is sampled reaches beyond the hole's bounds.
    public static func padding(thickness: Double) -> Int { min(256, max(64, Int((2 * thickness).rounded(.up)))) }

    /// The texture fill compares every candidate patch for every patch it fills, so its time
    /// goes with hole pixels × window pixels. Above this product it is refused (about 10 s
    /// on the Mac it was measured on, an M-series with 8 fast cores; docs/TESTING-NOTES.md).
    public static let largestTextureWork = 4.0e10

    /// Whether an area of this size is filled: nil, or why not. `allowLarge` lifts the first limit only.
    public static func refusal(pixels: Int, thickness: Double, allowLarge: Bool) -> Refusal? {
        let across = Int(thickness.rounded())
        if thickness > largestWidth || pixels > largestPixels {
            return Refusal(reason: "area_too_large",
                           message: "The area is \(across) px across at its thickest (\(pixels) pixels). Heal Selection fills areas up to \(Int(largestWidth)) px across and \(largestPixels / 1_000_000) megapixels.",
                           hard: true)
        }
        if thickness > comfortableWidth, !allowLarge {
            return Refusal(reason: "area_too_large",
                           message: "The area is \(across) px across at its thickest. Heal Selection gives good results up to about \(Int(comfortableWidth)) px; beyond that the fill may smear or repeat.")
        }
        return nil
    }

    // MARK: Filling

    public struct Result: Sendable {
        /// The window's pixels with every hole pixel replaced.
        public var pixels: [Float]
        public var method: Method
    }

    /// Fills `hole` in a `width` × `height` window of premultiplied RGBA `pixels` (4 floats a
    /// pixel, row-major). Pixels outside the hole are never changed. Same input, same output.
    public static func fill(pixels: [Float], width: Int, height: Int, hole: [Bool], thickness: Double,
                            method: Method = .auto, isCancelled: @Sendable () -> Bool = { false }) throws -> Result {
        precondition(pixels.count == width * height * 4 && hole.count == width * height)
        var usable = 0, missing = 0
        for i in hole.indices {
            if hole[i] { missing += 1 } else if pixels[i * 4 + 3] > 0 { usable += 1 }
        }
        guard missing > 0 else { return Result(pixels: pixels, method: method == .auto ? .smooth : method) }
        guard usable >= missing else {
            throw Refusal(reason: "nothing_to_sample",
                          message: "There isn't enough image around the selection to fill it from (\(usable) usable pixels for \(missing)).")
        }
        var chosen = method
        if method == .auto {
            chosen = thickness <= thinWidth || !hasTexture(pixels: pixels, width: width, height: height, hole: hole) ? .smooth : .texture
        }
        if chosen == .texture {
            guard Double(missing) * Double(width * height) <= largestTextureWork else {
                throw Refusal(reason: "area_too_large",
                              message: "The area (\(missing) pixels) is too large to fill from its surroundings in reasonable time.",
                              hard: true)
            }
            do {
                return Result(pixels: try ExemplarFill.run(pixels: pixels, width: width, height: height, hole: hole, isCancelled: isCancelled),
                              method: .texture)
            } catch let refusal as Refusal where method == .auto && refusal.reason == "nothing_to_sample" {
                // No whole patch to copy from (a thin strip of image, say): the smooth fill still works.
                chosen = .smooth
            }
        }
        return Result(pixels: try FastMarchingFill.run(pixels: pixels, width: width, height: height, hole: hole, isCancelled: isCancelled),
                      method: .smooth)
    }

    /// Whether the image just around the hole has texture a smooth fill would wipe out:
    /// the mean difference between neighbouring pixels there, in 8-bit levels.
    static func hasTexture(pixels: [Float], width: Int, height: Int, hole: [Bool]) -> Bool {
        let near = distance(to: hole, width: width, height: height)
        let tone = MatchImage(pixels: pixels, width: width, height: height)
        var sum = 0.0, n = 0
        for y in 0..<height - 1 {
            for x in 0..<width - 1 {
                let i = y * width + x
                guard near[i] > 0, near[i] <= 12, !hole[i + 1], !hole[i + width],
                      pixels[i * 4 + 3] > 0, pixels[(i + 1) * 4 + 3] > 0, pixels[(i + width) * 4 + 3] > 0 else { continue }
                sum += abs(tone.luma(i) - tone.luma(i + 1)) + abs(tone.luma(i) - tone.luma(i + width))
                n += 2
            }
        }
        return n > 0 && sum / Double(n) > textureLevel
    }

    /// Photo noise on an even surface is 1–2 levels between neighbours; grass, gravel, fabric are well above.
    static let textureLevel = 2.5

    // MARK: Distance

    /// The distance from every pixel to the nearest `true` pixel (0 on them; infinity if there is none).
    /// Exact Euclidean, by two passes of the one-dimensional lower-envelope transform.
    public static func distance(to mask: [Bool], width: Int, height: Int) -> [Float] {
        let far: Float = 1e20
        var d = mask.map { $0 ? Float(0) : far }
        let n = max(width, height)
        var f = [Float](repeating: 0, count: n), out = [Float](repeating: 0, count: n)
        var v = [Int](repeating: 0, count: n), z = [Float](repeating: 0, count: n + 1)
        // Lower envelope of the parabolas rooted at the points that have a distance at all.
        func pass(_ count: Int) {
            var k = -1
            for q in 0..<count where f[q] < far / 2 {
                var s: Float = -far
                while k >= 0 {
                    let p = v[k]
                    s = ((f[q] + Float(q * q)) - (f[p] + Float(p * p))) / Float(2 * q - 2 * p)
                    if s <= z[k] { k -= 1 } else { break }
                }
                if k < 0 { s = -far }
                k += 1
                v[k] = q; z[k] = s; z[k + 1] = far
            }
            guard k >= 0 else {
                for q in 0..<count { out[q] = far }
                return
            }
            k = 0
            for q in 0..<count {
                while z[k + 1] < Float(q) { k += 1 }
                let p = v[k]
                out[q] = Float((q - p) * (q - p)) + f[p]
            }
        }
        for x in 0..<width {
            for y in 0..<height { f[y] = d[y * width + x] }
            pass(height)
            for y in 0..<height { d[y * width + x] = out[y] }
        }
        for y in 0..<height {
            for x in 0..<width { f[x] = d[y * width + x] }
            pass(width)
            for x in 0..<width { d[y * width + x] = out[x] }
        }
        return d.map { $0 >= far / 2 ? .infinity : $0.squareRoot() }
    }
}

/// The image as it is compared: straight (not premultiplied) colour, roughly as the eye
/// weighs it (square root of linear light), in 8 bits, at the image's own size.
struct MatchImage {
    /// Four bytes a pixel: red, green, blue, unused.
    var bytes: [UInt8]

    init(pixels: [Float], width: Int, height: Int) {
        bytes = [UInt8](repeating: 0, count: width * height * 4)
        for i in 0..<width * height {
            let a = pixels[i * 4 + 3]
            guard a > 0 else { continue }
            for c in 0..<3 {
                let v = min(1, max(0, pixels[i * 4 + c] / a))
                bytes[i * 4 + c] = UInt8((v.squareRoot() * 255).rounded())
            }
        }
    }

    func luma(_ i: Int) -> Double {
        0.2126 * Double(bytes[i * 4]) + 0.7152 * Double(bytes[i * 4 + 1]) + 0.0722 * Double(bytes[i * 4 + 2])
    }
}
#endif
