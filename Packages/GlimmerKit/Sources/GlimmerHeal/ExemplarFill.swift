#if GLIMMER_HEAL
import Foundation

/// The texture fill: exemplar-based, after A. Criminisi, P. Pérez and K. Toyama, "Region
/// Filling and Object Removal by Exemplar-Based Image Inpainting" (IEEE Transactions on
/// Image Processing, 2004). The patch on the fill front with the highest priority is filled
/// from the best-matching whole patch of the surrounding image; then the next.
///
/// The priority is the paper's, unchanged: P(p) = C(p) · D(p), with the confidence C(p) the
/// mean confidence over the patch and the data term D(p) = |∇I⊥ · n| / α at the front pixel
/// (α = 255). The paper leaves two things to whoever writes it, and they are done the plain
/// way here: the image gradient "at" a front pixel, which has no value yet, is the strongest
/// gradient among the patch's known pixels; and equal priorities go to the higher
/// confidence, then to the first pixel in reading order.
///
/// The search is the paper's too: every candidate patch in the window is compared, by the
/// sum of squared differences over the pixels already known. See the rules in Heal.swift.
enum ExemplarFill {
    static let half = Heal.patchSide / 2

    static func run(pixels: [Float], width w: Int, height h: Int, hole: [Bool], isCancelled: @Sendable () -> Bool) throws -> [Float] {
        var out = pixels
        var match = MatchImage(pixels: pixels, width: w, height: h)
        var filled = hole.map { !$0 }
        var confidence = hole.map { $0 ? Float(0) : 1 }
        let side = Heal.patchSide, area = Float(side * side)

        // Patches that may be copied from: wholly inside the window, no hole pixel, nothing transparent.
        var candidates: [Int32] = []
        do {
            var blocked = [Int32](repeating: 0, count: (w + 1) * (h + 1))  // summed-area table
            for y in 0..<h {
                var row: Int32 = 0
                for x in 0..<w {
                    let i = y * w + x
                    if hole[i] || pixels[i * 4 + 3] <= 0 { row += 1 }
                    blocked[(y + 1) * (w + 1) + x + 1] = blocked[y * (w + 1) + x + 1] + row
                }
            }
            if w >= side, h >= side {
                for y in half..<h - half {
                    for x in half..<w - half {
                        let x0 = x - half, y0 = y - half, x1 = x + half + 1, y1 = y + half + 1
                        let n = blocked[y1 * (w + 1) + x1] - blocked[y0 * (w + 1) + x1] - blocked[y1 * (w + 1) + x0] + blocked[y0 * (w + 1) + x0]
                        if n == 0 { candidates.append(Int32(y * w + x)) }
                    }
                }
            }
        }
        guard !candidates.isEmpty else {
            throw Heal.Refusal(reason: "nothing_to_sample",
                               message: "There is no untouched \(side) × \(side) patch of image around the selection to fill it from.")
        }

        func isFront(_ x: Int, _ y: Int) -> Bool {
            let i = y * w + x
            guard !filled[i] else { return false }
            return (x > 0 && filled[i - 1]) || (x < w - 1 && filled[i + 1]) || (y > 0 && filled[i - w]) || (y < h - 1 && filled[i + w])
        }

        /// C(p) and P(p) for the front pixel at (x, y).
        func priority(_ x: Int, _ y: Int) -> (confidence: Float, priority: Float) {
            var c: Float = 0
            var strongest: Float = -1, ix: Float = 0, iy: Float = 0
            for py in max(0, y - half)...min(h - 1, y + half) {
                for px in max(0, x - half)...min(w - 1, x + half) {
                    let q = py * w + px
                    guard filled[q] else { continue }
                    c += confidence[q]
                    guard px > 0, px < w - 1, py > 0, py < h - 1,
                          filled[q - 1], filled[q + 1], filled[q - w], filled[q + w] else { continue }
                    let gx = Float(match.luma(q + 1) - match.luma(q - 1)) / 2, gy = Float(match.luma(q + w) - match.luma(q - w)) / 2
                    let strength = gx * gx + gy * gy
                    if strength > strongest { strongest = strength; ix = gx; iy = gy }
                }
            }
            c /= area
            // The front's normal: the gradient of "is filled" around p.
            func known(_ dx: Int, _ dy: Int) -> Float {
                let nx = x + dx, ny = y + dy
                return nx >= 0 && nx < w && ny >= 0 && ny < h && filled[ny * w + nx] ? 1 : 0
            }
            var nx = known(1, 0) - known(-1, 0), ny = known(0, 1) - known(0, -1)
            let length = (nx * nx + ny * ny).squareRoot()
            if length > 0 { nx /= length; ny /= length }
            // The isophote is the gradient turned a quarter: (-iy, ix).
            let data = abs(-iy * nx + ix * ny) / 255
            return (c, c * data)
        }

        var onFront = [Bool](repeating: false, count: w * h)
        var frontPriority = [Float](repeating: 0, count: w * h), frontConfidence = [Float](repeating: 0, count: w * h)
        var front: [Int] = []
        var remaining = 0
        for y in 0..<h {
            for x in 0..<w where hole[y * w + x] {
                remaining += 1
                if isFront(x, y) {
                    let i = y * w + x
                    onFront[i] = true
                    (frontConfidence[i], frontPriority[i]) = priority(x, y)
                    front.append(i)
                }
            }
        }

        var offsets = [Int](repeating: 0, count: side * side)  // of the target's known pixels, from its centre
        var values = [UInt8](repeating: 0, count: side * side * 3)
        let chunks = max(1, min(ProcessInfo.processInfo.activeProcessorCount, candidates.count / 2048))
        var steps = 0
        while remaining > 0 {
            steps += 1
            if steps % 16 == 0, isCancelled() { throw CancellationError() }
            // The front pixel with the highest priority.
            var best = -1
            var live = 0
            for i in front where onFront[i] {
                live += 1
                if best < 0 || frontPriority[i] > frontPriority[best]
                    || (frontPriority[i] == frontPriority[best] && (frontConfidence[i] > frontConfidence[best]
                        || (frontConfidence[i] == frontConfidence[best] && i < best))) {
                    best = i
                }
            }
            guard best >= 0 else { break }  // a hole pixel with no known pixel anywhere near can't happen once the front exists
            if front.count > 4 * live + 64 { front.removeAll { !onFront[$0] } }
            let x = best % w, y = best / w

            // What is known of the target patch.
            var known = 0
            for dy in -half...half {
                for dx in -half...half {
                    let px = x + dx, py = y + dy
                    guard px >= 0, px < w, py >= 0, py < h, filled[py * w + px] else { continue }
                    let q = py * w + px
                    offsets[known] = dy * w + dx
                    values[known * 3] = match.bytes[q * 4]; values[known * 3 + 1] = match.bytes[q * 4 + 1]; values[known * 3 + 2] = match.bytes[q * 4 + 2]
                    known += 1
                }
            }

            // Every candidate, compared in full. Each core takes a stretch of the list; the
            // smallest difference wins, the earliest candidate among equals.
            let source = Self.search(candidates: candidates, chunks: chunks, bytes: match.bytes, offsets: offsets, values: values, known: known)

            // Copy the pixels the target lacks, as they are.
            let c = frontConfidence[best]
            for dy in -half...half {
                for dx in -half...half {
                    let px = x + dx, py = y + dy
                    guard px >= 0, px < w, py >= 0, py < h else { continue }
                    let q = py * w + px
                    guard !filled[q] else { continue }
                    let s = source + dy * w + dx
                    for k in 0..<4 {
                        out[q * 4 + k] = out[s * 4 + k]
                        match.bytes[q * 4 + k] = match.bytes[s * 4 + k]
                    }
                    filled[q] = true
                    confidence[q] = c
                    onFront[q] = false
                    remaining -= 1
                }
            }
            // The front and its priorities change only near what was just filled.
            let reach = 2 * half + 1
            for py in max(0, y - reach)...min(h - 1, y + reach) {
                for px in max(0, x - reach)...min(w - 1, x + reach) {
                    let q = py * w + px
                    guard !filled[q] else { continue }
                    if isFront(px, py) {
                        if !onFront[q] { onFront[q] = true; front.append(q) }
                        (frontConfidence[q], frontPriority[q]) = priority(px, py)
                    }
                }
            }
        }
        return out
    }

    /// The centre of the candidate patch that differs least from the target's known pixels.
    private static func search(candidates: [Int32], chunks: Int, bytes: [UInt8], offsets: [Int], values: [UInt8], known: Int) -> Int {
        let results = UnsafeMutablePointer<(Int32, Int32)>.allocate(capacity: chunks)
        defer { results.deallocate() }
        let per = (candidates.count + chunks - 1) / chunks
        candidates.withUnsafeBufferPointer { cand in
            bytes.withUnsafeBufferPointer { img in
                offsets.withUnsafeBufferPointer { offs in
                    values.withUnsafeBufferPointer { vals in
                        let cand = SendablePointer(cand.baseAddress!), img = SendablePointer(img.baseAddress!)
                        let offs = SendablePointer(offs.baseAddress!), vals = SendablePointer(vals.baseAddress!)
                        let results = SendableMutablePointer(results)
                        let total = candidates.count
                        DispatchQueue.concurrentPerform(iterations: chunks) { chunk in
                            var least = Int32.max, at: Int32 = -1
                            let end = min(total, (chunk + 1) * per)
                            var n = chunk * per
                            while n < end {
                                let centre = Int(cand.p[n])
                                var sum: Int32 = 0
                                var k = 0
                                while k < known {
                                    let q = (centre + offs.p[k]) * 4
                                    let dr = Int32(img.p[q]) - Int32(vals.p[k * 3])
                                    let dg = Int32(img.p[q + 1]) - Int32(vals.p[k * 3 + 1])
                                    let db = Int32(img.p[q + 2]) - Int32(vals.p[k * 3 + 2])
                                    sum += dr * dr + dg * dg + db * db
                                    if sum >= least { break }
                                    k += 1
                                }
                                if sum < least { least = sum; at = cand.p[n] }
                                n += 1
                            }
                            results.p[chunk] = (least, at)
                        }
                    }
                }
            }
        }
        var least = Int32.max, at: Int32 = -1
        for chunk in 0..<chunks where results[chunk].1 >= 0 && results[chunk].0 < least {
            (least, at) = results[chunk]
        }
        return Int(at)
    }
}

private struct SendablePointer<T>: @unchecked Sendable {
    let p: UnsafePointer<T>
    init(_ p: UnsafePointer<T>) { self.p = p }
}

private struct SendableMutablePointer<T>: @unchecked Sendable {
    let p: UnsafeMutablePointer<T>
    init(_ p: UnsafeMutablePointer<T>) { self.p = p }
}
#endif
