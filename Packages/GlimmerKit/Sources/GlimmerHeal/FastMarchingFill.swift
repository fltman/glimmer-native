#if GLIMMER_HEAL
import Foundation

/// The smooth fill: fast marching, after A. Telea, "An Image Inpainting Technique Based on
/// the Fast Marching Method" (Journal of Graphics Tools, 2004). The hole is filled from its
/// edge inwards in the order of distance to the edge; each pixel is a weighted average of
/// the already-known pixels around it, each extended along its own gradient.
enum FastMarchingFill {
    /// How far around a pixel known pixels are averaged.
    static let radius = 5

    private static let known: UInt8 = 0, band: UInt8 = 1, inside: UInt8 = 2

    static func run(pixels: [Float], width w: Int, height h: Int, hole: [Bool], isCancelled: () -> Bool) throws -> [Float] {
        var out = pixels
        var flag = hole.map { $0 ? inside : known }
        // Distance to the hole's edge: 0 on it, counted negative outside as the paper does.
        var t = [Float](repeating: 0, count: w * h)
        let outside = Heal.distance(to: hole, width: w, height: h)
        for i in t.indices { t[i] = hole[i] ? 1e6 : -max(0, outside[i] - 1) }

        var heap = MinHeap()
        for y in 0..<h {
            for x in 0..<w where !hole[y * w + x] {
                let i = y * w + x
                if (x > 0 && hole[i - 1]) || (x < w - 1 && hole[i + 1]) || (y > 0 && hole[i - w]) || (y < h - 1 && hole[i + w]) {
                    flag[i] = band
                    t[i] = 0
                    heap.push(0, i)
                }
            }
        }

        /// One quadrant of the upwind solution of |∇T| = 1.
        func solve(_ x1: Int, _ y1: Int, _ x2: Int, _ y2: Int) -> Float {
            var s: Float = 1e6
            let in1 = x1 >= 0 && x1 < w && y1 >= 0 && y1 < h, in2 = x2 >= 0 && x2 < w && y2 >= 0 && y2 < h
            let i1 = y1 * w + x1, i2 = y2 * w + x2
            if in1, flag[i1] == known {
                if in2, flag[i2] == known {
                    let a = t[i1], b = t[i2]
                    let r = (2 - (a - b) * (a - b)).squareRoot()
                    var v = (a + b - r) / 2
                    if v >= a, v >= b {
                        s = v
                    } else {
                        v += r
                        if v >= a, v >= b { s = v }
                    }
                } else {
                    s = 1 + t[i1]
                }
            } else if in2, flag[i2] == known {
                s = 1 + t[i2]
            }
            return s
        }

        /// A central difference of `value` over the two neighbours that aren't inside the hole.
        func slope(_ i: Int, _ lower: Int?, _ upper: Int?, _ value: (Int) -> Float) -> Float {
            let lo = lower.flatMap { flag[$0] != inside ? $0 : nil }, hi = upper.flatMap { flag[$0] != inside ? $0 : nil }
            switch (lo, hi) {
            case (let a?, let b?): return (value(b) - value(a)) / 2
            case (let a?, nil): return value(i) - value(a)
            case (nil, let b?): return value(b) - value(i)
            default: return 0
            }
        }

        func inpaint(_ x: Int, _ y: Int) {
            let i = y * w + x
            let gtx = slope(i, x > 0 ? i - 1 : nil, x < w - 1 ? i + 1 : nil) { t[$0] }
            let gty = slope(i, y > 0 ? i - w : nil, y < h - 1 ? i + w : nil) { t[$0] }
            var sum = SIMD4<Float>(repeating: 0), weights: Float = 0
            var plain = SIMD4<Float>(repeating: 0), plainCount: Float = 0
            var lowest = SIMD4<Float>(repeating: .infinity), highest = SIMD4<Float>(repeating: -.infinity)
            for ky in max(0, y - radius)...min(h - 1, y + radius) {
                for kx in max(0, x - radius)...min(w - 1, x + radius) {
                    let k = ky * w + kx
                    guard flag[k] != inside else { continue }
                    let rx = Float(x - kx), ry = Float(y - ky)
                    let length2 = rx * rx + ry * ry
                    guard length2 > 0, length2 <= Float(radius * radius) else { continue }
                    let value = SIMD4(out[k * 4], out[k * 4 + 1], out[k * 4 + 2], out[k * 4 + 3])
                    plain += value
                    plainCount += 1
                    lowest = pointwiseMin(lowest, value)
                    highest = pointwiseMax(highest, value)
                    var direction = abs(rx * gtx + ry * gty) / length2.squareRoot()
                    if direction < 1e-6 { direction = 1e-6 }
                    let weight = direction * (1 / length2) * (1 / (1 + abs(t[k] - t[i])))
                    // A pixel of the picture carries its value over along its own gradient. A
                    // pixel that was itself filled in is taken as it is: its gradient is only
                    // an echo of the others', and feeding it back makes the fill run away.
                    var extended = value
                    if !hole[k] {
                        for c in 0..<4 {
                            let gx = slope(k, kx > 0 ? k - 1 : nil, kx < w - 1 ? k + 1 : nil) { out[$0 * 4 + c] }
                            let gy = slope(k, ky > 0 ? k - w : nil, ky < h - 1 ? k + w : nil) { out[$0 * 4 + c] }
                            extended[c] += gx * rx + gy * ry
                        }
                    }
                    sum += extended * weight
                    weights += weight
                }
            }
            var value = weights > 0 ? sum / weights : (plainCount > 0 ? plain / plainCount : SIMD4(repeating: 0))
            // Never brighter or darker than the pixels it was made from.
            if plainCount > 0 { value = pointwiseMax(lowest, pointwiseMin(highest, value)) }
            for c in 0..<4 { out[i * 4 + c] = value[c] }
        }

        var steps = 0
        while let (_, i) = heap.pop() {
            steps += 1
            if steps % 4096 == 0, isCancelled() { throw CancellationError() }
            flag[i] = known
            let x = i % w, y = i / w
            for (nx, ny) in [(x - 1, y), (x, y - 1), (x + 1, y), (x, y + 1)] where nx >= 0 && nx < w && ny >= 0 && ny < h {
                let n = ny * w + nx
                guard flag[n] != known else { continue }
                let distance = min(solve(nx - 1, ny, nx, ny - 1), solve(nx + 1, ny, nx, ny - 1),
                                   solve(nx - 1, ny, nx, ny + 1), solve(nx + 1, ny, nx, ny + 1))
                if flag[n] == inside {
                    t[n] = distance
                    // Still "inside" while it is worked out, so that no neighbour's gradient
                    // reads the value this pixel is about to lose.
                    inpaint(nx, ny)
                    flag[n] = band
                    heap.push(distance, n)
                } else if distance < t[n], hole[n] {
                    t[n] = distance
                    heap.push(distance, n)
                }
            }
        }
        return out
    }
}

/// A binary heap of (distance, pixel), smallest distance first; equal distances come out
/// in pixel order, so the fill is the same every time.
struct MinHeap {
    private var items: [(Float, Int)] = []

    private func less(_ a: (Float, Int), _ b: (Float, Int)) -> Bool { a.0 < b.0 || (a.0 == b.0 && a.1 < b.1) }

    mutating func push(_ key: Float, _ value: Int) {
        items.append((key, value))
        var i = items.count - 1
        while i > 0 {
            let parent = (i - 1) / 2
            guard less(items[i], items[parent]) else { break }
            items.swapAt(i, parent)
            i = parent
        }
    }

    mutating func pop() -> (Float, Int)? {
        guard let top = items.first else { return nil }
        let last = items.removeLast()
        if !items.isEmpty {
            items[0] = last
            var i = 0
            while true {
                let l = 2 * i + 1, r = l + 1
                var m = i
                if l < items.count, less(items[l], items[m]) { m = l }
                if r < items.count, less(items[r], items[m]) { m = r }
                if m == i { break }
                items.swapAt(i, m)
                i = m
            }
        }
        return top
    }
}
#endif
