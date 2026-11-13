import Foundation

/// A lossy WebP (VP8 key frame) encoder, following RFC 6386.
///
/// Each macroblock's luma is predicted either as one 16 × 16 block (DC,
/// vertical, horizontal, TrueMotion) or as sixteen 4 × 4 blocks (ten modes),
/// whichever costs less in error plus estimated bits. Coefficient
/// probabilities are fitted to the image in a second pass. One token partition,
/// no segmentation; the decoder's loop filter is switched on. Output is about
/// the size of libwebp's at the same quality.
enum VP8Encoder {
    /// Encodes straight RGBA8 pixels (alpha is ignored here) as a VP8 frame.
    /// `quality` is 0…1.
    static func encode(rgba: [UInt8], width: Int, height: Int, quality: Double) -> Data {
        var frame = Frame(rgba: rgba, width: width, height: height, quantizer: quantizerIndex(quality))
        return frame.encode()
    }

    /// For tests: the frame plus the encoder's own reconstruction of the luma
    /// plane (what a decoder produces before its loop filter), cropped to the image.
    static func encodeWithReconstruction(rgba: [UInt8], width: Int, height: Int, quality: Double) -> (Data, [UInt8]) {
        var frame = Frame(rgba: rgba, width: width, height: height, quantizer: quantizerIndex(quality))
        let data = frame.encode()
        var luma = [UInt8]()
        for y in 0..<height { luma.append(contentsOf: frame.y.recon[(y * frame.y.width)..<(y * frame.y.width + width)]) }
        return (data, luma)
    }

    /// libwebp's mapping from quality to the quantizer index (0 = finest, 127 = coarsest).
    static func quantizerIndex(_ quality: Double) -> Int {
        let c = min(max(quality, 0), 1)
        let linear = c < 0.75 ? c * (2.0 / 3.0) : 2 * c - 1
        return min(max(Int((127 * (1 - pow(linear, 1.0 / 3.0))).rounded()), 0), 127)
    }

    // MARK: Boolean entropy coder (RFC 6386 §7)

    struct BoolWriter {
        private(set) var bytes: [UInt8] = []
        private var range: Int32 = 254  // range − 1
        private var value: Int32 = 0
        private var run = 0
        private var pendingBits: Int32 = -8

        @inline(__always)
        mutating func put(_ bit: Bool, _ probability: UInt8) {
            let split = (range * Int32(probability)) >> 8
            if bit {
                value += split + 1
                range -= split + 1
            } else {
                range = split
            }
            normalize()
        }

        @inline(__always)
        mutating func putUniform(_ bit: Bool) {
            let split = range >> 1
            if bit {
                value += split + 1
                range -= split + 1
            } else {
                range = split
            }
            normalize()
        }

        mutating func putBits(_ v: Int, _ count: Int) {
            var mask = 1 << (count - 1)
            while mask != 0 {
                putUniform(v & mask != 0)
                mask >>= 1
            }
        }

        @inline(__always)
        private mutating func normalize() {
            guard range < 127 else { return }
            // Shift until range + 1 is at least 128.
            let shift = Int32((range + 1).leadingZeroBitCount) - 24
            range = ((range + 1) << shift) - 1
            value <<= shift
            pendingBits += shift
            if pendingBits > 0 { flush() }
        }

        private mutating func flush() {
            let s = 8 + pendingBits
            let bits = value >> s
            value -= bits << s
            pendingBits -= 8
            if bits & 0xff != 0xff {
                if bits & 0x100 != 0, !bytes.isEmpty { bytes[bytes.count - 1] &+= 1 }  // carry
                if run > 0 {
                    let fill: UInt8 = bits & 0x100 != 0 ? 0x00 : 0xff
                    bytes.append(contentsOf: repeatElement(fill, count: run))
                    run = 0
                }
                bytes.append(UInt8(bits & 0xff))
            } else {
                run += 1  // a 0xff byte waits to learn whether a carry reaches it
            }
        }

        mutating func finish() -> [UInt8] {
            putBits(0, Int(9 - pendingBits))
            pendingBits = 0
            flush()
            return bytes
        }
    }

    /// Records the coefficient tokens of a frame so they can be written once the
    /// probabilities that fit this image are known (two passes, like libwebp).
    struct TokenRecorder {
        /// Low bit: the bit. Rest: a coefficient-probability index (< 1056),
        /// `fixed + p` for a constant probability, or `uniform`.
        private(set) var events: [UInt32] = []
        private(set) var zeros = [Int](repeating: 0, count: 1056)
        private(set) var ones = [Int](repeating: 0, count: 1056)
        static let fixed: UInt32 = 2048, uniform: UInt32 = 4096

        @inline(__always)
        mutating func put(_ bit: Bool, at index: Int) {
            events.append(UInt32(index) << 1 | (bit ? 1 : 0))
            if bit { ones[index] += 1 } else { zeros[index] += 1 }
        }

        @inline(__always)
        mutating func put(_ bit: Bool, _ probability: UInt8) {
            events.append((Self.fixed + UInt32(probability)) << 1 | (bit ? 1 : 0))
        }

        @inline(__always)
        mutating func putUniform(_ bit: Bool) {
            events.append(Self.uniform << 1 | (bit ? 1 : 0))
        }

        /// Probabilities to use: the default, or one fitted to the counts where
        /// that saves more bits than announcing it costs.
        func fittedProbabilities() -> [UInt8] {
            var probs = VP8Tables.coefficientProbabilities
            @inline(__always) func cost(_ p: Double, zeros: Int, ones: Int) -> Double {
                -(Double(zeros) * log2(p / 256) + Double(ones) * log2(1 - p / 256))
            }
            for i in 0..<1056 {
                let total = zeros[i] + ones[i]
                guard total > 0 else { continue }
                let fitted = min(max((255 * zeros[i] + total / 2) / total, 1), 255)
                let old = Double(probs[i]), update = Double(VP8Tables.coefficientUpdateProbabilities[i])
                // Announcing costs the flag's 1-branch plus 8 bits, instead of its 0-branch.
                let announce = 8 - log2(1 - update / 256) + log2(update / 256)
                if cost(old, zeros: zeros[i], ones: ones[i]) - cost(Double(fitted), zeros: zeros[i], ones: ones[i]) > announce {
                    probs[i] = UInt8(fitted)
                }
            }
            return probs
        }

        func write(with probs: [UInt8]) -> [UInt8] {
            var w = BoolWriter()
            probs.withUnsafeBufferPointer { p in
                for event in events {
                    let bit = event & 1 != 0, code = event >> 1
                    if code < 1056 {
                        w.put(bit, p[Int(code)])
                    } else if code >= Self.uniform {
                        w.putUniform(bit)
                    } else {
                        w.put(bit, UInt8(code - Self.fixed))
                    }
                }
            }
            return w.finish()
        }
    }

    // MARK: Transforms (the inverse ones are bit-exact with the decoder)

    /// Forward 4 × 4 DCT of `source − prediction` (raster order in, raster order out).
    @inline(__always)
    static func forwardDCT(_ d: UnsafePointer<Int32>, _ out: UnsafeMutablePointer<Int32>) {
        var tmp = (Int32(0), Int32(0), Int32(0), Int32(0), Int32(0), Int32(0), Int32(0), Int32(0),
                   Int32(0), Int32(0), Int32(0), Int32(0), Int32(0), Int32(0), Int32(0), Int32(0))
        withUnsafeMutablePointer(to: &tmp) { raw in
            let t = UnsafeMutableRawPointer(raw).assumingMemoryBound(to: Int32.self)
            for i in 0..<4 {
                let d0 = d[i * 4], d1 = d[i * 4 + 1], d2 = d[i * 4 + 2], d3 = d[i * 4 + 3]
                let a0 = d0 + d3, a1 = d1 + d2, a2 = d1 - d2, a3 = d0 - d3
                t[i * 4] = (a0 + a1) * 8
                t[i * 4 + 1] = (a2 * 2217 + a3 * 5352 + 1812) >> 9
                t[i * 4 + 2] = (a0 - a1) * 8
                t[i * 4 + 3] = (a3 * 2217 - a2 * 5352 + 937) >> 9
            }
            for i in 0..<4 {
                let a0 = t[i] + t[12 + i], a1 = t[4 + i] + t[8 + i], a2 = t[4 + i] - t[8 + i], a3 = t[i] - t[12 + i]
                out[i] = (a0 + a1 + 7) >> 4
                out[4 + i] = ((a2 * 2217 + a3 * 5352 + 12000) >> 16) + (a3 != 0 ? 1 : 0)
                out[8 + i] = (a0 - a1 + 7) >> 4
                out[12 + i] = (a3 * 2217 - a2 * 5352 + 51000) >> 16
            }
        }
    }

    /// Inverse DCT: returns the 16 residuals to add to the prediction.
    @inline(__always)
    static func inverseDCT(_ c: UnsafePointer<Int32>, _ out: UnsafeMutablePointer<Int32>) {
        @inline(__always) func mul1(_ a: Int32) -> Int32 { ((a * 20091) >> 16) + a }
        @inline(__always) func mul2(_ a: Int32) -> Int32 { (a * 35468) >> 16 }
        var tmp = (Int32(0), Int32(0), Int32(0), Int32(0), Int32(0), Int32(0), Int32(0), Int32(0),
                   Int32(0), Int32(0), Int32(0), Int32(0), Int32(0), Int32(0), Int32(0), Int32(0))
        withUnsafeMutablePointer(to: &tmp) { raw in
            let t = UnsafeMutableRawPointer(raw).assumingMemoryBound(to: Int32.self)
            for i in 0..<4 {  // vertical
                let a = c[i] + c[8 + i], b = c[i] - c[8 + i]
                let cc = mul2(c[4 + i]) - mul1(c[12 + i]), d = mul1(c[4 + i]) + mul2(c[12 + i])
                t[i * 4] = a + d
                t[i * 4 + 1] = b + cc
                t[i * 4 + 2] = b - cc
                t[i * 4 + 3] = a - d
            }
            for i in 0..<4 {  // horizontal: row i
                let dc = t[i] + 4
                let a = dc + t[8 + i], b = dc - t[8 + i]
                let cc = mul2(t[4 + i]) - mul1(t[12 + i]), d = mul1(t[4 + i]) + mul2(t[12 + i])
                out[i * 4] = (a + d) >> 3
                out[i * 4 + 1] = (b + cc) >> 3
                out[i * 4 + 2] = (b - cc) >> 3
                out[i * 4 + 3] = (a - d) >> 3
            }
        }
    }

    /// Forward Walsh–Hadamard transform of the 16 luma DC values.
    static func forwardWHT(_ dc: [Int32]) -> [Int32] {
        var t = [Int32](repeating: 0, count: 16), out = t
        for i in 0..<4 {
            let a0 = dc[i * 4] + dc[i * 4 + 2], a1 = dc[i * 4 + 1] + dc[i * 4 + 3]
            let a2 = dc[i * 4 + 1] - dc[i * 4 + 3], a3 = dc[i * 4] - dc[i * 4 + 2]
            t[i * 4] = a0 + a1
            t[i * 4 + 1] = a3 + a2
            t[i * 4 + 2] = a3 - a2
            t[i * 4 + 3] = a0 - a1
        }
        for i in 0..<4 {
            let a0 = t[i] + t[8 + i], a1 = t[4 + i] + t[12 + i], a2 = t[4 + i] - t[12 + i], a3 = t[i] - t[8 + i]
            out[i] = (a0 + a1) >> 1
            out[4 + i] = (a3 + a2) >> 1
            out[8 + i] = (a3 - a2) >> 1
            out[12 + i] = (a0 - a1) >> 1
        }
        return out
    }

    /// Inverse WHT: the 16 luma DC coefficients (block order).
    static func inverseWHT(_ c: [Int32]) -> [Int32] {
        var t = [Int32](repeating: 0, count: 16), out = t
        for i in 0..<4 {
            let a0 = c[i] + c[12 + i], a1 = c[4 + i] + c[8 + i], a2 = c[4 + i] - c[8 + i], a3 = c[i] - c[12 + i]
            t[i] = a0 + a1
            t[8 + i] = a0 - a1
            t[4 + i] = a3 + a2
            t[12 + i] = a3 - a2
        }
        for i in 0..<4 {
            let dc = t[i * 4] + 3
            let a0 = dc + t[i * 4 + 3], a1 = t[i * 4 + 1] + t[i * 4 + 2]
            let a2 = t[i * 4 + 1] - t[i * 4 + 2], a3 = dc - t[i * 4 + 3]
            out[i * 4] = (a0 + a1) >> 3
            out[i * 4 + 1] = (a3 + a2) >> 3
            out[i * 4 + 2] = (a0 - a1) >> 3
            out[i * 4 + 3] = (a3 - a2) >> 3
        }
        return out
    }

    // MARK: Frame

    enum Mode: Int { case dc = 0, tm, vertical, horizontal }

    /// One plane with reconstruction (what the decoder will have) next to the source.
    struct Plane {
        let width: Int, height: Int
        var source: [UInt8]
        var recon: [UInt8]

        init(width: Int, height: Int) {
            self.width = width
            self.height = height
            source = [UInt8](repeating: 0, count: width * height)
            recon = source
        }
    }

    struct Frame {
        let width: Int, height: Int
        let mbWidth: Int, mbHeight: Int
        let quantizer: Int
        var y: Plane, u: Plane, v: Plane

        // Quantizer steps: [dc, ac].
        let y1: (Int32, Int32), y2: (Int32, Int32), uv: (Int32, Int32)

        init(rgba: [UInt8], width: Int, height: Int, quantizer q: Int) {
            self.width = width
            self.height = height
            mbWidth = (width + 15) / 16
            mbHeight = (height + 15) / 16
            quantizer = q
            y = Plane(width: mbWidth * 16, height: mbHeight * 16)
            u = Plane(width: mbWidth * 8, height: mbHeight * 8)
            v = Plane(width: mbWidth * 8, height: mbHeight * 8)
            let dc = VP8Tables.dcSteps, ac = VP8Tables.acSteps
            y1 = (dc[q], ac[q])
            y2 = (dc[q] * 2, max((ac[q] * 101_581) >> 16, 8))
            uv = (dc[min(q, 117)], ac[q])
            convert(rgba)
        }

        /// RGB → BT.601 Y′CbCr (studio range), 4:2:0, padded to whole macroblocks by repeating edges.
        private mutating func convert(_ rgba: [UInt8]) {
            let w = width, h = height, pw = y.width, ph = y.height
            rgba.withUnsafeBufferPointer { src in
                for py in 0..<ph {
                    let sy = min(py, h - 1)
                    for px in 0..<pw {
                        let i = (sy * w + min(px, w - 1)) * 4
                        let r = Int32(src[i]), g = Int32(src[i + 1]), b = Int32(src[i + 2])
                        y.source[py * pw + px] = UInt8((16839 * r + 33059 * g + 6420 * b + (16 << 16) + (1 << 15)) >> 16)
                    }
                }
                let cw = u.width, ch = u.height
                for cy in 0..<ch {
                    for cx in 0..<cw {
                        var r: Int32 = 0, g: Int32 = 0, b: Int32 = 0
                        for dy in 0..<2 {
                            for dx in 0..<2 {
                                let i = (min(cy * 2 + dy, h - 1) * w + min(cx * 2 + dx, w - 1)) * 4
                                r += Int32(src[i]); g += Int32(src[i + 1]); b += Int32(src[i + 2])
                            }
                        }
                        // Sums of four samples: two extra bits of precision.
                        let cu = (-9719 * r - 19081 * g + 28800 * b + (128 << 18) + (1 << 17)) >> 18
                        let cv = (28800 * r - 24116 * g - 4684 * b + (128 << 18) + (1 << 17)) >> 18
                        u.source[cy * cw + cx] = UInt8(min(max(cu, 0), 255))
                        v.source[cy * cw + cx] = UInt8(min(max(cv, 0), 255))
                    }
                }
            }
        }

        // MARK: Prediction

        /// Fills `pred` (size × size) for a block at (x0, y0) of `plane`, from the reconstruction.
        private func predict(_ plane: Plane, x0: Int, y0: Int, size: Int, mode: Mode, into pred: inout [Int32]) {
            let w = plane.width
            let hasTop = y0 > 0, hasLeft = x0 > 0
            plane.recon.withUnsafeBufferPointer { r in
                switch mode {
                case .dc:
                    var sum: Int32 = 0
                    let shift = size == 16 ? 4 : 3
                    var value: Int32 = 128
                    if hasTop { for i in 0..<size { sum += Int32(r[(y0 - 1) * w + x0 + i]) } }
                    if hasLeft { for i in 0..<size { sum += Int32(r[(y0 + i) * w + x0 - 1]) } }
                    if hasTop && hasLeft {
                        value = (sum + Int32(size)) >> Int32(shift + 1)
                    } else if hasTop || hasLeft {
                        value = (sum + Int32(size / 2)) >> Int32(shift)
                    }
                    for i in 0..<(size * size) { pred[i] = value }
                case .vertical:
                    for yy in 0..<size { for xx in 0..<size { pred[yy * size + xx] = Int32(r[(y0 - 1) * w + x0 + xx]) } }
                case .horizontal:
                    for yy in 0..<size {
                        let l = Int32(r[(y0 + yy) * w + x0 - 1])
                        for xx in 0..<size { pred[yy * size + xx] = l }
                    }
                case .tm:
                    let corner = Int32(r[(y0 - 1) * w + x0 - 1])
                    for yy in 0..<size {
                        let l = Int32(r[(y0 + yy) * w + x0 - 1]) - corner
                        for xx in 0..<size {
                            pred[yy * size + xx] = min(max(Int32(r[(y0 - 1) * w + x0 + xx]) + l, 0), 255)
                        }
                    }
                }
            }
        }

        /// Modes whose neighbours exist (edge macroblocks only use what needs no special casing).
        private func candidates(x0: Int, y0: Int) -> [Mode] {
            var modes: [Mode] = [.dc]
            if y0 > 0 { modes.append(.vertical) }
            if x0 > 0 { modes.append(.horizontal) }
            if x0 > 0 && y0 > 0 { modes.append(.tm) }
            return modes
        }

        private func bestMode(_ planes: [Plane], x0: Int, y0: Int, size: Int, pred: inout [Int32]) -> Mode {
            var best = Mode.dc, bestCost = Int32.max
            for mode in candidates(x0: x0, y0: y0) {
                var cost: Int32 = 0
                for plane in planes {
                    predict(plane, x0: x0, y0: y0, size: size, mode: mode, into: &pred)
                    plane.source.withUnsafeBufferPointer { s in
                        for yy in 0..<size {
                            let row = (y0 + yy) * plane.width + x0
                            for xx in 0..<size { cost += abs(Int32(s[row + xx]) - pred[yy * size + xx]) }
                        }
                    }
                }
                if cost < bestCost { bestCost = cost; best = mode }
            }
            return best
        }

        // MARK: Residual coding

        @inline(__always)
        private static func quantize(_ c: Int32, _ step: Int32) -> Int32 {
            // A small dead zone: values just above half a step round down.
            let a = abs(c)
            let level = (a + (step * 3) / 8) / step
            return c < 0 ? -level : level
        }

        /// Writes one block's coefficients (already in scan order). Returns whether any was non-zero.
        private static func putCoefficients(_ w: inout TokenRecorder, type: Int, context: Int, first: Int,
                                            _ coeffs: UnsafePointer<Int32>) -> Bool {
            @inline(__always) func base(_ n: Int, _ ctx: Int) -> Int { ((type * 8 + VP8Tables.bands[n]) * 3 + ctx) * 11 }
            var last = -1
            for n in stride(from: 15, through: first, by: -1) where coeffs[n] != 0 { last = n; break }
            var n = first
            var p = base(n, context)
            guard last >= 0 else {
                w.put(false, at: p)
                return false
            }
            w.put(true, at: p)
            while n < 16 {
                let c = coeffs[n]
                n += 1
                var v = Int(abs(c))
                if v == 0 {
                    w.put(false, at: p + 1)
                    p = base(n, 0)
                    continue
                }
                w.put(true, at: p + 1)
                if v == 1 {
                    w.put(false, at: p + 2)
                    p = base(n, 1)
                } else {
                    w.put(true, at: p + 2)
                    if v <= 4 {
                        w.put(false, at: p + 3)
                        if v == 2 {
                            w.put(false, at: p + 4)
                        } else {
                            w.put(true, at: p + 4)
                            w.put(v == 4, at: p + 5)
                        }
                    } else if v <= 10 {
                        w.put(true, at: p + 3)
                        w.put(false, at: p + 6)
                        if v <= 6 {
                            w.put(false, at: p + 7)
                            w.put(v == 6, 159)
                        } else {
                            w.put(true, at: p + 7)
                            w.put(v >= 9, 165)
                            w.put(v & 1 == 0, 145)
                        }
                    } else {
                        w.put(true, at: p + 3)
                        w.put(true, at: p + 6)
                        var mask: Int
                        let extra: [UInt8]
                        if v < 3 + (8 << 1) {
                            w.put(false, at: p + 8); w.put(false, at: p + 9)
                            v -= 3 + (8 << 0); mask = 1 << 2; extra = [173, 148, 140]
                        } else if v < 3 + (8 << 2) {
                            w.put(false, at: p + 8); w.put(true, at: p + 9)
                            v -= 3 + (8 << 1); mask = 1 << 3; extra = [176, 155, 140, 135]
                        } else if v < 3 + (8 << 3) {
                            w.put(true, at: p + 8); w.put(false, at: p + 10)
                            v -= 3 + (8 << 2); mask = 1 << 4; extra = [180, 157, 141, 134, 130]
                        } else {
                            w.put(true, at: p + 8); w.put(true, at: p + 10)
                            v -= 3 + (8 << 3); mask = 1 << 10
                            extra = [254, 254, 243, 230, 196, 177, 153, 140, 133, 130, 129]
                        }
                        var i = 0
                        while mask != 0 {
                            w.put(v & mask != 0, extra[i])
                            i += 1
                            mask >>= 1
                        }
                    }
                    p = base(n, 2)
                }
                w.putUniform(c < 0)
                if n == 16 { return true }
                if n > last {
                    w.put(false, at: p)  // end of block
                    return true
                }
                w.put(true, at: p)
            }
            return true
        }


        // MARK: 4 × 4 prediction (RFC 6386 §12.3)

        /// Fills `pred` (16 values) for sub-mode `mode`. `top` is the top-left pixel
        /// followed by the eight pixels above and above-right; `left` the four to the left.
        @inline(__always)
        private static func predict4(_ mode: Int, top e: UnsafePointer<Int32>, left l: UnsafePointer<Int32>,
                                     into p: UnsafeMutablePointer<Int32>) {
            @inline(__always) func avg3(_ a: Int32, _ b: Int32, _ c: Int32) -> Int32 { (a + 2 * b + c + 2) >> 2 }
            @inline(__always) func avg2(_ a: Int32, _ b: Int32) -> Int32 { (a + b + 1) >> 1 }
            @inline(__always) func set(_ x: Int, _ y: Int, _ v: Int32) { p[y * 4 + x] = v }
            let X = e[0], A = e[1], B = e[2], C = e[3], D = e[4], E = e[5], F = e[6], G = e[7], H = e[8]
            let I = l[0], J = l[1], K = l[2], L = l[3]
            switch mode {
            case 0:  // DC
                let dc = (4 + A + B + C + D + I + J + K + L) >> 3
                for i in 0..<16 { p[i] = dc }
            case 1:  // TrueMotion
                for y in 0..<4 { for x in 0..<4 { p[y * 4 + x] = min(max(e[1 + x] + l[y] - X, 0), 255) } }
            case 2:  // vertical
                let v = (avg3(X, A, B), avg3(A, B, C), avg3(B, C, D), avg3(C, D, E))
                for y in 0..<4 { p[y * 4] = v.0; p[y * 4 + 1] = v.1; p[y * 4 + 2] = v.2; p[y * 4 + 3] = v.3 }
            case 3:  // horizontal
                let rows = (avg3(X, I, J), avg3(I, J, K), avg3(J, K, L), avg3(K, L, L))
                for x in 0..<4 { p[x] = rows.0; p[4 + x] = rows.1; p[8 + x] = rows.2; p[12 + x] = rows.3 }
            case 4:  // down-right
                set(0, 3, avg3(J, K, L))
                let a = avg3(I, J, K); set(1, 3, a); set(0, 2, a)
                let b = avg3(X, I, J); set(2, 3, b); set(1, 2, b); set(0, 1, b)
                let c = avg3(A, X, I); set(3, 3, c); set(2, 2, c); set(1, 1, c); set(0, 0, c)
                let d = avg3(B, A, X); set(3, 2, d); set(2, 1, d); set(1, 0, d)
                let f = avg3(C, B, A); set(3, 1, f); set(2, 0, f)
                set(3, 0, avg3(D, C, B))
            case 5:  // vertical-right
                let a = avg2(X, A); set(0, 0, a); set(1, 2, a)
                let b = avg2(A, B); set(1, 0, b); set(2, 2, b)
                let c = avg2(B, C); set(2, 0, c); set(3, 2, c)
                set(3, 0, avg2(C, D))
                set(0, 3, avg3(K, J, I))
                set(0, 2, avg3(J, I, X))
                let d = avg3(I, X, A); set(0, 1, d); set(1, 3, d)
                let f = avg3(X, A, B); set(1, 1, f); set(2, 3, f)
                let g = avg3(A, B, C); set(2, 1, g); set(3, 3, g)
                set(3, 1, avg3(B, C, D))
            case 6:  // down-left
                set(0, 0, avg3(A, B, C))
                let a = avg3(B, C, D); set(1, 0, a); set(0, 1, a)
                let b = avg3(C, D, E); set(2, 0, b); set(1, 1, b); set(0, 2, b)
                let c = avg3(D, E, F); set(3, 0, c); set(2, 1, c); set(1, 2, c); set(0, 3, c)
                let d = avg3(E, F, G); set(3, 1, d); set(2, 2, d); set(1, 3, d)
                let f = avg3(F, G, H); set(3, 2, f); set(2, 3, f)
                set(3, 3, avg3(G, H, H))
            case 7:  // vertical-left
                set(0, 0, avg2(A, B))
                let a = avg2(B, C); set(1, 0, a); set(0, 2, a)
                let b = avg2(C, D); set(2, 0, b); set(1, 2, b)
                let c = avg2(D, E); set(3, 0, c); set(2, 2, c)
                set(0, 1, avg3(A, B, C))
                let d = avg3(B, C, D); set(1, 1, d); set(0, 3, d)
                let f = avg3(C, D, E); set(2, 1, f); set(1, 3, f)
                let g = avg3(D, E, F); set(3, 1, g); set(2, 3, g)
                set(3, 2, avg3(E, F, G))
                set(3, 3, avg3(F, G, H))
            case 8:  // horizontal-down
                let a = avg2(I, X); set(0, 0, a); set(2, 1, a)
                let b = avg2(J, I); set(0, 1, b); set(2, 2, b)
                let c = avg2(K, J); set(0, 2, c); set(2, 3, c)
                set(0, 3, avg2(L, K))
                set(3, 0, avg3(A, B, C))
                set(2, 0, avg3(X, A, B))
                let d = avg3(I, X, A); set(1, 0, d); set(3, 1, d)
                let f = avg3(J, I, X); set(1, 1, f); set(3, 2, f)
                let g = avg3(K, J, I); set(1, 2, g); set(3, 3, g)
                set(1, 3, avg3(L, K, J))
            default:  // 9: horizontal-up
                set(0, 0, avg2(I, J))
                let a = avg2(J, K); set(2, 0, a); set(0, 1, a)
                let b = avg2(K, L); set(2, 1, b); set(0, 2, b)
                set(1, 0, avg3(I, J, K))
                let c = avg3(J, K, L); set(3, 0, c); set(1, 1, c)
                let d = avg3(K, L, L); set(3, 1, d); set(1, 2, d)
                set(3, 2, L); set(2, 2, L); set(0, 3, L); set(1, 3, L); set(2, 3, L); set(3, 3, L)
            }
        }

        /// The bits (as (bit, probability index 0…8) pairs) that code a 4 × 4 mode.
        @inline(__always)
        private static func subModeBits(_ mode: Int, _ body: (Bool, Int) -> Void) {
            body(mode != 0, 0)
            guard mode != 0 else { return }
            body(mode != 1, 1)
            guard mode != 1 else { return }
            body(mode != 2, 2)
            guard mode != 2 else { return }
            if mode < 6 {
                body(false, 3)
                body(mode != 3, 4)
                if mode != 3 { body(mode != 4, 5) }
            } else {
                body(true, 3)
                body(mode != 6, 6)
                if mode != 6 {
                    body(mode != 7, 7)
                    if mode != 7 { body(mode != 8, 8) }
                }
            }
        }

        /// log2-cost table for an 8-bit probability, in bits.
        private static let bitCost: [Float] = (0...256).map { $0 == 0 ? 8 : -log2(Float($0) / 256) }

        /// Bits needed to announce `mode` given the modes above and to the left.
        @inline(__always)
        private static func subModeCost(_ mode: Int, above: Int, left: Int) -> Float {
            var bits: Float = 0
            let base = (above * 10 + left) * 9
            subModeBits(mode) { bit, i in
                let p = Int(VP8Tables.subModeProbabilities[base + i])
                bits += bitCost[bit ? 256 - p : p]
            }
            return bits
        }

        /// A rough bit count for a block's quantized levels (raster order), good
        /// enough to compare 16 × 16 against 4 × 4 coding.
        @inline(__always)
        private static func estimatedBits(_ levels: UnsafePointer<Int32>, first: Int) -> Float {
            var last = -1
            let zigzag = VP8Tables.zigzag
            for n in stride(from: 15, through: first, by: -1) where levels[zigzag[n]] != 0 { last = n; break }
            guard last >= 0 else { return 0.6 }
            var bits: Float = 1.2
            for n in first...last {
                let v = abs(levels[zigzag[n]])
                switch v {
                case 0: bits += 1.1
                case 1: bits += 3.2
                case 2: bits += 5
                case 3, 4: bits += 6.3
                default: bits += 6.5 + 2 * log2(Float(v))
                }
            }
            return bits
        }

        // MARK: Encoding

        mutating func encode() -> Data {
            var tokens = TokenRecorder()
            let count = mbWidth * mbHeight
            var lumaModes = [Mode](repeating: .dc, count: count)
            var chromaModes = lumaModes
            var skipped = [Bool](repeating: false, count: count)
            // Luma is coded either as one 16 × 16 prediction or as sixteen 4 × 4 ones.
            var usesSubModes = [Bool](repeating: false, count: count)
            let gridWidth = mbWidth * 4
            var subModes = [UInt8](repeating: 0, count: gridWidth * mbHeight * 4)
            var recon16 = [UInt8](repeating: 0, count: 256)
            var levels4 = [Int32](repeating: 0, count: 16 * 16)
            var modes4 = [UInt8](repeating: 0, count: 16)
            var pred4 = [Int32](repeating: 0, count: 16), edgeTop = [Int32](repeating: 0, count: 9), edgeLeft = [Int32](repeating: 0, count: 4)
            // Rate–distortion weight: squared error against estimated bits.
            let lambda = Float(y1.1 * y1.1) * 3 / 128

            // Non-zero flags of the neighbouring blocks: 4 Y, 2 U, 2 V and the Y2 block.
            var topNZ = [[Bool]](repeating: [Bool](repeating: false, count: 9), count: mbWidth)
            var pred16 = [Int32](repeating: 0, count: 256), pred8 = [Int32](repeating: 0, count: 64)
            var diff = [Int32](repeating: 0, count: 16), coeff = diff, residual = diff
            var scan = [Int32](repeating: 0, count: 16)
            let zigzag = VP8Tables.zigzag
            // Quantized levels of the macroblock being coded, raster order per block (reused).
            var levels = [Int32](repeating: 0, count: 16 * 16)
            var chromaLevels = [Int32](repeating: 0, count: 8 * 16)
            var dcs = [Int32](repeating: 0, count: 16)
            var y2Levels = dcs, dequantY2 = dcs

            for my in 0..<mbHeight {
                var leftNZ = [Bool](repeating: false, count: 9)
                for mx in 0..<mbWidth {
                    let index = my * mbWidth + mx
                    let x0 = mx * 16, y0 = my * 16

                    // Luma: predict, transform the 16 blocks, move their DCs into the Y2 block.
                    let lumaMode = bestMode([y], x0: x0, y0: y0, size: 16, pred: &pred16)
                    lumaModes[index] = lumaMode
                    predict(y, x0: x0, y0: y0, size: 16, mode: lumaMode, into: &pred16)
                    for b in 0..<16 {
                        let bx = (b & 3) * 4, by = (b >> 2) * 4
                        for j in 0..<4 {
                            let row = (y0 + by + j) * y.width + x0 + bx
                            for i in 0..<4 { diff[j * 4 + i] = Int32(y.source[row + i]) - pred16[(by + j) * 16 + bx + i] }
                        }
                        Self.forwardTransform(&diff, &coeff)
                        dcs[b] = coeff[0]
                        levels[b * 16] = 0
                        for k in 1..<16 { levels[b * 16 + k] = Self.quantize(coeff[k], y1.1) }
                    }
                    let whtIn = VP8Encoder.forwardWHT(dcs)
                    for k in 0..<16 { y2Levels[k] = Self.quantize(whtIn[k], k == 0 ? y2.0 : y2.1) }
                    // Reconstruct exactly as the decoder will.
                    for k in 0..<16 { dequantY2[k] = y2Levels[k] * (k == 0 ? y2.0 : y2.1) }
                    let reconDC = VP8Encoder.inverseWHT(dequantY2)
                    var cost16 = lambda * 2  // the mode itself
                    y2Levels.withUnsafeBufferPointer { cost16 += lambda * Self.estimatedBits($0.baseAddress!, first: 0) }
                    for b in 0..<16 {
                        let bx = (b & 3) * 4, by = (b >> 2) * 4
                        coeff[0] = reconDC[b]
                        for k in 1..<16 { coeff[k] = levels[b * 16 + k] * y1.1 }
                        Self.inverseTransform(&coeff, &residual)
                        levels.withUnsafeBufferPointer { cost16 += lambda * Self.estimatedBits($0.baseAddress! + b * 16, first: 1) }
                        for j in 0..<4 {
                            let row = (y0 + by + j) * y.width + x0 + bx
                            for i in 0..<4 {
                                let value = min(max(pred16[(by + j) * 16 + bx + i] + residual[j * 4 + i], 0), 255)
                                recon16[(by + j) * 16 + bx + i] = UInt8(value)
                                let error = Float(Int32(y.source[row + i]) - value)
                                cost16 += error * error
                            }
                        }
                    }

                    // The 4 × 4 alternative, reconstructed in place block by block (each
                    // block predicts from the ones before it). Edge macroblocks keep 16 × 16.
                    var cost4 = Float.infinity
                    if mx > 0 && my > 0 {
                        cost4 = lambda * 1
                        let w = y.width
                        for b in 0..<16 {
                            let bx = b & 3, by = b >> 2
                            let px = x0 + bx * 4, py = y0 + by * 4
                            // Neighbouring pixels: top-left, eight above (the last four from above-right), four left.
                            edgeTop[0] = Int32(y.recon[(py - 1) * w + px - 1])
                            for i in 0..<4 { edgeTop[1 + i] = Int32(y.recon[(py - 1) * w + px + i]) }
                            if bx < 3 {
                                // Above-right inside the macroblock (or its top neighbour): already reconstructed.
                                for i in 0..<4 { edgeTop[5 + i] = Int32(y.recon[(py - 1) * w + px + 4 + i]) }
                            } else if mx < mbWidth - 1 {
                                // Right column: always the pixels above the next macroblock.
                                for i in 0..<4 { edgeTop[5 + i] = Int32(y.recon[(y0 - 1) * w + x0 + 16 + i]) }
                            } else {
                                let last = Int32(y.recon[(y0 - 1) * w + x0 + 15])
                                for i in 0..<4 { edgeTop[5 + i] = last }
                            }
                            for j in 0..<4 { edgeLeft[j] = Int32(y.recon[(py + j) * w + px - 1]) }
                            let gx = mx * 4 + bx, gy = my * 4 + by
                            let above = Int(subModes[(gy - 1) * gridWidth + gx]), left = Int(subModes[gy * gridWidth + gx - 1])

                            // Pick the mode by prediction error plus what announcing it costs.
                            var bestMode = 0, bestScore = Float.infinity
                            for mode in 0..<10 {
                                edgeTop.withUnsafeBufferPointer { t in
                                    edgeLeft.withUnsafeBufferPointer { l in
                                        pred4.withUnsafeMutableBufferPointer { Self.predict4(mode, top: t.baseAddress!, left: l.baseAddress!, into: $0.baseAddress!) }
                                    }
                                }
                                var sad: Int32 = 0
                                for j in 0..<4 { for i in 0..<4 { sad += abs(Int32(y.source[(py + j) * w + px + i]) - pred4[j * 4 + i]) } }
                                let score = Float(sad) + Float(y1.1) * 0.35 * Self.subModeCost(mode, above: above, left: left)
                                if score < bestScore { bestScore = score; bestMode = mode }
                            }
                            modes4[b] = UInt8(bestMode)
                            subModes[gy * gridWidth + gx] = UInt8(bestMode)
                            cost4 += lambda * Self.subModeCost(bestMode, above: above, left: left)
                            edgeTop.withUnsafeBufferPointer { t in
                                edgeLeft.withUnsafeBufferPointer { l in
                                    pred4.withUnsafeMutableBufferPointer { Self.predict4(bestMode, top: t.baseAddress!, left: l.baseAddress!, into: $0.baseAddress!) }
                                }
                            }
                            for j in 0..<4 { for i in 0..<4 { diff[j * 4 + i] = Int32(y.source[(py + j) * w + px + i]) - pred4[j * 4 + i] } }
                            Self.forwardTransform(&diff, &coeff)
                            for k in 0..<16 {
                                let step = k == 0 ? y1.0 : y1.1
                                let level = Self.quantize(coeff[k], step)
                                levels4[b * 16 + k] = level
                                coeff[k] = level * step
                            }
                            levels4.withUnsafeBufferPointer { cost4 += lambda * Self.estimatedBits($0.baseAddress! + b * 16, first: 0) }
                            Self.inverseTransform(&coeff, &residual)
                            for j in 0..<4 {
                                for i in 0..<4 {
                                    let value = min(max(pred4[j * 4 + i] + residual[j * 4 + i], 0), 255)
                                    y.recon[(py + j) * w + px + i] = UInt8(value)
                                    let error = Float(Int32(y.source[(py + j) * w + px + i]) - value)
                                    cost4 += error * error
                                }
                            }
                        }
                    }
                    let subdivided = cost4 < cost16
                    usesSubModes[index] = subdivided
                    if !subdivided {
                        for j in 0..<16 {
                            for i in 0..<16 { y.recon[(y0 + j) * y.width + x0 + i] = recon16[j * 16 + i] }
                        }
                        // Neighbours see a 16 × 16 macroblock as sixteen blocks of the matching 4 × 4 mode.
                        for b in 0..<16 { subModes[(my * 4 + (b >> 2)) * gridWidth + mx * 4 + (b & 3)] = UInt8(lumaMode.rawValue) }
                    }

                    // Chroma: one mode for both planes.
                    let cx0 = mx * 8, cy0 = my * 8
                    let chromaMode = bestMode([u, v], x0: cx0, y0: cy0, size: 8, pred: &pred8)
                    chromaModes[index] = chromaMode
                    for planeIndex in 0..<2 {
                        predict(planeIndex == 0 ? u : v, x0: cx0, y0: cy0, size: 8, mode: chromaMode, into: &pred8)
                        for b in 0..<4 {
                            let bx = (b & 1) * 4, by = (b >> 1) * 4
                            for j in 0..<4 {
                                let row = (cy0 + by + j) * u.width + cx0 + bx
                                for i in 0..<4 {
                                    let s = planeIndex == 0 ? u.source[row + i] : v.source[row + i]
                                    diff[j * 4 + i] = Int32(s) - pred8[(by + j) * 8 + bx + i]
                                }
                            }
                            Self.forwardTransform(&diff, &coeff)
                            for k in 0..<16 {
                                let level = Self.quantize(coeff[k], k == 0 ? uv.0 : uv.1)
                                chromaLevels[(planeIndex * 4 + b) * 16 + k] = level
                                coeff[k] = level * (k == 0 ? uv.0 : uv.1)
                            }
                            Self.inverseTransform(&coeff, &residual)
                            for j in 0..<4 {
                                let row = (cy0 + by + j) * u.width + cx0 + bx
                                for i in 0..<4 {
                                    let value = UInt8(min(max(pred8[(by + j) * 8 + bx + i] + residual[j * 4 + i], 0), 255))
                                    if planeIndex == 0 { u.recon[row + i] = value } else { v.recon[row + i] = value }
                                }
                            }
                        }
                    }

                    // Tokens.
                    let lumaEmpty = subdivided ? !levels4.contains { $0 != 0 }
                        : (!y2Levels.contains { $0 != 0 } && !levels.contains { $0 != 0 })
                    let empty = lumaEmpty && !chromaLevels.contains { $0 != 0 }
                    skipped[index] = empty
                    if empty {
                        // A skipped 4 × 4 macroblock has no Y2 block, so that context stays as it was.
                        for k in 0..<(subdivided ? 8 : 9) { topNZ[mx][k] = false; leftNZ[k] = false }
                        continue
                    }
                    func emit(_ block: [Int32], _ offset: Int, type: Int, first: Int, top: Int, left: Int) {
                        for n in 0..<16 { scan[n] = block[offset + zigzag[n]] }
                        let context = (topNZ[mx][top] ? 1 : 0) + (leftNZ[left] ? 1 : 0)
                        let nz = Self.putCoefficients(&tokens, type: type, context: context, first: first, scan)
                        topNZ[mx][top] = nz
                        leftNZ[left] = nz
                    }
                    if subdivided {
                        for b in 0..<16 { emit(levels4, b * 16, type: 3, first: 0, top: b & 3, left: b >> 2) }
                    } else {
                        emit(y2Levels, 0, type: 1, first: 0, top: 8, left: 8)
                        for b in 0..<16 { emit(levels, b * 16, type: 0, first: 1, top: b & 3, left: b >> 2) }
                    }
                    for planeIndex in 0..<2 {
                        for b in 0..<4 {
                            emit(chromaLevels, (planeIndex * 4 + b) * 16, type: 2, first: 0,
                                 top: 4 + planeIndex * 2 + (b & 1), left: 4 + planeIndex * 2 + (b >> 1))
                        }
                    }
                }
            }
            let probabilities = tokens.fittedProbabilities()
            let tokenBytes = tokens.write(with: probabilities)

            // First partition: frame header, then the modes of every macroblock.
            var header = BoolWriter()
            header.putUniform(false)  // colour space: BT.601
            header.putUniform(false)  // clamping needed
            header.putUniform(false)  // no segmentation
            header.putUniform(false)  // normal loop filter
            header.putBits(min(63, quantizer / 2 + (quantizer > 0 ? 2 : 0)), 6)  // filter level follows the quantizer
            header.putBits(0, 3)      // sharpness
            header.putUniform(false)  // no filter deltas
            header.putBits(0, 2)      // one token partition
            header.putBits(quantizer, 7)
            for _ in 0..<5 { header.putUniform(false) }  // no quantizer deltas
            header.putUniform(false)  // don't keep probabilities (only one frame)
            // Coefficient probabilities: announce the ones fitted to this image.
            for i in 0..<1056 {
                let changed = probabilities[i] != VP8Tables.coefficientProbabilities[i]
                header.put(changed, VP8Tables.coefficientUpdateProbabilities[i])
                if changed { header.putBits(Int(probabilities[i]), 8) }
            }
            let skipCount = skipped.count { $0 }
            let skipProbability = UInt8(min(max(255 * (count - skipCount) / max(count, 1), 1), 255))
            header.putUniform(true)   // macroblocks can be skipped
            header.putBits(Int(skipProbability), 8)
            for i in 0..<count {
                header.put(skipped[i], skipProbability)
                if usesSubModes[i] {
                    header.put(false, 145)  // sixteen 4 × 4 predictions
                    let mx = i % mbWidth, my = i / mbWidth
                    for b in 0..<16 {
                        let gx = mx * 4 + (b & 3), gy = my * 4 + (b >> 2)
                        // Outside the frame counts as DC.
                        let above = gy > 0 ? Int(subModes[(gy - 1) * gridWidth + gx]) : 0
                        let left = gx > 0 ? Int(subModes[gy * gridWidth + gx - 1]) : 0
                        let base = (above * 10 + left) * 9
                        Self.subModeBits(Int(subModes[gy * gridWidth + gx])) { bit, k in
                            header.put(bit, VP8Tables.subModeProbabilities[base + k])
                        }
                    }
                } else {
                    header.put(true, 145)  // 16 × 16 prediction
                    let mode = lumaModes[i]
                    if mode == .tm || mode == .horizontal {
                        header.put(true, 156)
                        header.put(mode == .tm, 128)
                    } else {
                        header.put(false, 156)
                        header.put(mode == .vertical, 163)
                    }
                }
                let chroma = chromaModes[i]
                if chroma == .dc {
                    header.put(false, 142)
                } else {
                    header.put(true, 142)
                    if chroma == .vertical {
                        header.put(false, 114)
                    } else {
                        header.put(true, 114)
                        header.put(chroma == .tm, 183)
                    }
                }
            }
            let headerBytes = header.finish()

            var data = Data()
            // Frame tag: key frame, profile 0, shown, size of the first partition.
            let tag = UInt32(0) | (0 << 1) | (1 << 4) | (UInt32(headerBytes.count) << 5)
            data.append(contentsOf: [UInt8(tag & 0xff), UInt8((tag >> 8) & 0xff), UInt8((tag >> 16) & 0xff)])
            data.append(contentsOf: [0x9d, 0x01, 0x2a])
            data.append(contentsOf: [UInt8(width & 0xff), UInt8((width >> 8) & 0x3f), UInt8(height & 0xff), UInt8((height >> 8) & 0x3f)])
            data.append(contentsOf: headerBytes)
            data.append(contentsOf: tokenBytes)
            return data
        }

        private static func forwardTransform(_ input: inout [Int32], _ output: inout [Int32]) {
            input.withUnsafeBufferPointer { i in
                output.withUnsafeMutableBufferPointer { o in VP8Encoder.forwardDCT(i.baseAddress!, o.baseAddress!) }
            }
        }

        private static func inverseTransform(_ input: inout [Int32], _ output: inout [Int32]) {
            input.withUnsafeBufferPointer { i in
                output.withUnsafeMutableBufferPointer { o in VP8Encoder.inverseDCT(i.baseAddress!, o.baseAddress!) }
            }
        }
    }
}
