import Foundation

/// A lossless WebP (VP8L) encoder. ImageIO reads WebP but can't write it.
///
/// The bitstream uses the subtract-green and predictor transforms (a per-block
/// choice between left, top, select and gradient prediction) and one group of
/// length-limited Huffman codes over literal pixels. No backward references or
/// colour cache, so files are roughly PNG-sized. See the WebP lossless
/// bitstream specification (RFC 9649).
public enum WebPEncoder {
    public enum Error: Swift.Error, LocalizedError {
        case tooLarge(width: Int, height: Int)

        public var errorDescription: String? {
            switch self {
            case .tooLarge(let w, let h): "WebP images can be at most 16 384 × 16 384 pixels (this one is \(w) × \(h))."
            }
        }
    }

    public static let maxDimension = 16_384

    /// Encodes straight-alpha RGBA8 pixels (row-major, top-down).
    /// `iccProfile` is embedded through the extended (VP8X) container.
    public static func encode(rgba: [UInt8], width: Int, height: Int, iccProfile: Data? = nil) throws -> Data {
        guard width <= maxDimension, height <= maxDimension, width > 0, height > 0 else {
            throw Error.tooLarge(width: width, height: height)
        }
        precondition(rgba.count >= width * height * 4)
        var argb = [UInt32](repeating: 0, count: width * height)
        var hasAlpha = false
        rgba.withUnsafeBufferPointer { src in
            argb.withUnsafeMutableBufferPointer { dst in
                for i in 0..<(width * height) {
                    let a = UInt32(src[i * 4 + 3])
                    if a != 255 { hasAlpha = true }
                    // Fully transparent pixels carry no colour; zero them so they compress.
                    dst[i] = a == 0 ? 0 : (a << 24) | (UInt32(src[i * 4]) << 16) | (UInt32(src[i * 4 + 1]) << 8) | UInt32(src[i * 4 + 2])
                }
            }
        }
        let bitstream = encodeVP8L(&argb, width: width, height: height, hasAlpha: hasAlpha)
        return container(vp8l: bitstream, width: width, height: height, hasAlpha: hasAlpha, iccProfile: iccProfile)
    }

    // MARK: Container

    static func container(vp8l: Data, width: Int, height: Int, hasAlpha: Bool, iccProfile: Data?) -> Data {
        var body = Data("WEBP".utf8)
        if let icc = iccProfile {
            var vp8x = Data()
            vp8x.append(UInt8(0x20 | (hasAlpha ? 0x10 : 0)))  // ICC, alpha
            vp8x.append(contentsOf: [0, 0, 0])
            vp8x.append(contentsOf: uint24(width - 1))
            vp8x.append(contentsOf: uint24(height - 1))
            body.append(chunk("VP8X", vp8x))
            body.append(chunk("ICCP", icc))
        }
        body.append(chunk("VP8L", vp8l))
        var file = Data("RIFF".utf8)
        file.append(contentsOf: uint32(body.count))
        file.append(body)
        return file
    }

    private static func chunk(_ tag: String, _ payload: Data) -> Data {
        var d = Data(tag.utf8)
        d.append(contentsOf: uint32(payload.count))
        d.append(payload)
        if payload.count % 2 == 1 { d.append(0) }
        return d
    }

    private static func uint32(_ v: Int) -> [UInt8] { (0..<4).map { UInt8((v >> ($0 * 8)) & 0xff) } }
    private static func uint24(_ v: Int) -> [UInt8] { (0..<3).map { UInt8((v >> ($0 * 8)) & 0xff) } }

    // MARK: VP8L bitstream

    static let predictorBits = 5

    static func encodeVP8L(_ argb: inout [UInt32], width: Int, height: Int, hasAlpha: Bool) -> Data {
        var w = BitWriter()
        w.write(0x2f, 8)
        w.write(UInt64(width - 1), 14)
        w.write(UInt64(height - 1), 14)
        w.write(hasAlpha ? 1 : 0, 1)
        w.write(0, 3)

        // Transforms, in the order the encoder applies them (the decoder undoes them in reverse).
        w.write(1, 1)
        w.write(2, 2)  // subtract green
        subtractGreen(&argb)

        w.write(1, 1)
        w.write(0, 2)  // predictor
        w.write(UInt64(predictorBits - 2), 3)
        let modes = predict(&argb, width: width, height: height)
        let bw = blocks(width), bh = blocks(height)
        var modeImage = modes.map { 0xff00_0000 | (UInt32($0) << 8) }
        writeImage(&w, &modeImage, count: bw * bh, isLevel0: false)

        w.write(0, 1)  // no more transforms
        writeImage(&w, &argb, count: width * height, isLevel0: true)
        return w.finish()
    }

    static func blocks(_ size: Int) -> Int { (size + (1 << predictorBits) - 1) >> predictorBits }

    static func subtractGreen(_ argb: inout [UInt32]) {
        argb.withUnsafeMutableBufferPointer { p in
            for i in p.indices {
                let v = p[i]
                let g = (v >> 8) & 0xff
                let r = (((v >> 16) & 0xff) &- g) & 0xff
                let b = ((v & 0xff) &- g) & 0xff
                p[i] = (v & 0xff00_ff00) | (r << 16) | b
            }
        }
    }

    // MARK: Predictor

    /// Modes tried per block: 1 = left, 2 = top, 11 = select, 12 = clamped gradient.
    static let candidateModes: [UInt8] = [1, 2, 11, 12]

    /// Replaces `argb` with prediction residuals and returns the mode per block.
    static func predict(_ argb: inout [UInt32], width: Int, height: Int) -> [UInt8] {
        let bw = blocks(width), bh = blocks(height), size = 1 << predictorBits
        var modes = [UInt8](repeating: 1, count: bw * bh)
        let original = argb
        original.withUnsafeBufferPointer { src in
            // Choose the mode with the smallest residuals per block.
            for by in 0..<bh {
                for bx in 0..<bw {
                    var best: UInt8 = 1, bestCost = Int.max
                    for mode in candidateModes {
                        var cost = 0
                        for y in (by * size)..<min((by + 1) * size, height) where y > 0 {
                            for x in max(bx * size, 1)..<min((bx + 1) * size, width) {
                                let r = residual(src[y * width + x], prediction(src, x, y, width, mode))
                                cost += residualCost(r)
                            }
                        }
                        if cost < bestCost { bestCost = cost; best = mode }
                    }
                    modes[by * bw + bx] = best
                }
            }
            argb.withUnsafeMutableBufferPointer { dst in
                for y in 0..<height {
                    for x in 0..<width {
                        let mode: UInt8 = y == 0 ? (x == 0 ? 0 : 1) : (x == 0 ? 2 : modes[(y >> predictorBits) * bw + (x >> predictorBits)])
                        dst[y * width + x] = residual(src[y * width + x], prediction(src, x, y, width, mode))
                    }
                }
            }
        }
        return modes
    }

    @inline(__always)
    static func residual(_ pixel: UInt32, _ pred: UInt32) -> UInt32 {
        // Per-channel subtraction mod 256.
        let ag = ((pixel | 0x00ff_00ff) &- (pred & 0xff00_ff00)) & 0xff00_ff00
        let rb = ((pixel | 0xff00_ff00) &- (pred & 0x00ff_00ff)) & 0x00ff_00ff
        return ag | rb
    }

    @inline(__always)
    static func residualCost(_ r: UInt32) -> Int {
        @inline(__always) func c(_ v: UInt32) -> Int { let v = Int(v & 0xff); return v < 128 ? v : 256 - v }
        return c(r) + c(r >> 8) + c(r >> 16) + c(r >> 24)
    }

    @inline(__always)
    static func prediction(_ p: UnsafeBufferPointer<UInt32>, _ x: Int, _ y: Int, _ width: Int, _ mode: UInt8) -> UInt32 {
        let i = y * width + x
        switch mode {
        case 0: return 0xff00_0000
        case 1: return p[i - 1]
        case 2: return p[i - width]
        case 11: return select(l: p[i - 1], t: p[i - width], tl: p[i - width - 1])
        case 12: return clampAddSubtract(p[i - 1], p[i - width], p[i - width - 1])
        default: return p[i - 1]
        }
    }

    @inline(__always)
    static func channel(_ v: UInt32, _ shift: UInt32) -> Int { Int((v >> shift) & 0xff) }

    /// The spec's Select: whichever of left and top is closer to the gradient estimate L + T − TL.
    @inline(__always)
    static func select(l: UInt32, t: UInt32, tl: UInt32) -> UInt32 {
        // |estimate − L| = |T − TL| and |estimate − T| = |L − TL|, per channel.
        @inline(__always) func d(_ a: UInt32, _ b: UInt32, _ s: UInt32) -> Int { abs(channel(a, s) - channel(b, s)) }
        let pl = d(t, tl, 24) + d(t, tl, 16) + d(t, tl, 8) + d(t, tl, 0)
        let pt = d(l, tl, 24) + d(l, tl, 16) + d(l, tl, 8) + d(l, tl, 0)
        return pl < pt ? l : t
    }

    @inline(__always)
    static func clampAddSubtract(_ a: UInt32, _ b: UInt32, _ c: UInt32) -> UInt32 {
        @inline(__always) func ch(_ s: UInt32) -> UInt32 {
            UInt32(min(max(channel(a, s) + channel(b, s) - channel(c, s), 0), 255)) << s
        }
        return ch(24) | ch(16) | ch(8) | ch(0)
    }

    // MARK: Entropy coding

    /// Writes an entropy-coded image of literal pixels with one prefix-code group.
    static func writeImage(_ w: inout BitWriter, _ argb: inout [UInt32], count: Int, isLevel0: Bool) {
        w.write(0, 1)  // no colour cache
        if isLevel0 { w.write(0, 1) }  // no meta prefix codes
        var green = [Int](repeating: 0, count: 256 + 24), red = [Int](repeating: 0, count: 256)
        var blue = red, alpha = red
        argb.withUnsafeBufferPointer { p in
            for i in 0..<count {
                let v = p[i]
                green[Int((v >> 8) & 0xff)] += 1
                red[Int((v >> 16) & 0xff)] += 1
                blue[Int(v & 0xff)] += 1
                alpha[Int(v >> 24)] += 1
            }
        }
        let codes = [green, red, blue, alpha].map { PrefixCode(histogram: $0) }
        for code in codes { code.write(&w) }
        PrefixCode(histogram: [Int](repeating: 0, count: 40)).write(&w)  // distances (unused)
        let g = codes[0], r = codes[1], b = codes[2], a = codes[3]
        argb.withUnsafeBufferPointer { p in
            for i in 0..<count {
                let v = p[i]
                g.emit(Int((v >> 8) & 0xff), &w)
                r.emit(Int((v >> 16) & 0xff), &w)
                b.emit(Int(v & 0xff), &w)
                a.emit(Int(v >> 24), &w)
            }
        }
    }

    /// One canonical prefix code, written either as a "simple" code (one or two
    /// symbols below 256) or as code lengths coded with the code-length code.
    struct PrefixCode {
        let alphabetSize: Int
        var lengths: [Int]
        /// Bit-reversed canonical codes (VP8L reads codes MSB first from an LSB-first stream).
        var codes: [UInt64]
        let simpleSymbols: [Int]?

        init(histogram: [Int]) {
            alphabetSize = histogram.count
            let used = histogram.indices.filter { histogram[$0] > 0 }
            if used.count <= 2, used.allSatisfy({ $0 < 256 }) {
                simpleSymbols = used.isEmpty ? [0] : used
                lengths = [Int](repeating: 0, count: histogram.count)
                codes = [UInt64](repeating: 0, count: histogram.count)
                if used.count == 2 {
                    lengths[used[0]] = 1
                    lengths[used[1]] = 1
                    codes[used[1]] = 1
                }
                return
            }
            simpleSymbols = nil
            lengths = huffmanLengths(histogram, limit: 15)
            codes = canonicalCodes(lengths)
        }

        @inline(__always)
        func emit(_ symbol: Int, _ w: inout BitWriter) {
            let n = lengths[symbol]
            if n > 0 { w.write(codes[symbol], n) }
        }

        func write(_ w: inout BitWriter) {
            if let symbols = simpleSymbols {
                w.write(1, 1)
                w.write(UInt64(symbols.count - 1), 1)
                if symbols[0] < 2 {
                    w.write(0, 1)
                    w.write(UInt64(symbols[0]), 1)
                } else {
                    w.write(1, 1)
                    w.write(UInt64(symbols[0]), 8)
                }
                if symbols.count == 2 { w.write(UInt64(symbols[1]), 8) }
                return
            }
            w.write(0, 1)
            // The code-length code: lengths 0…15 written as literal symbols.
            var counts = [Int](repeating: 0, count: 19)
            for l in lengths { counts[l] += 1 }
            var clLengths = huffmanLengths(counts, limit: 7)
            if clLengths.filter({ $0 > 0 }).count == 1 {
                // A one-symbol code isn't a complete tree; pair it with an unused symbol.
                let only = clLengths.firstIndex { $0 > 0 }!
                clLengths[only] = 1
                clLengths[only == 0 ? 1 : 0] = 1
            }
            let clCodes = canonicalCodes(clLengths)
            let order = [17, 18, 0, 1, 2, 3, 4, 5, 16, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15]
            var n = 19
            while n > 4, clLengths[order[n - 1]] == 0 { n -= 1 }
            w.write(UInt64(n - 4), 4)
            for i in 0..<n { w.write(UInt64(clLengths[order[i]]), 3) }
            w.write(0, 1)  // max_symbol = alphabet size
            for l in lengths { w.write(clCodes[l], clLengths[l]) }
        }
    }

    /// Huffman code lengths with a maximum length; a single used symbol gets length 1.
    static func huffmanLengths(_ histogram: [Int], limit: Int) -> [Int] {
        var counts = histogram
        while true {
            let lengths = plainHuffmanLengths(counts)
            if (lengths.max() ?? 0) <= limit { return lengths }
            // Flatten the distribution and try again.
            counts = counts.map { $0 == 0 ? 0 : max(1, $0 >> 1) }
        }
    }

    private static func plainHuffmanLengths(_ counts: [Int]) -> [Int] {
        var lengths = [Int](repeating: 0, count: counts.count)
        let used = counts.indices.filter { counts[$0] > 0 }
        if used.count == 1 { lengths[used[0]] = 1; return lengths }
        if used.isEmpty { return lengths }
        // Nodes: leaves first, then internal nodes; parent links give the depths.
        var weight = used.map { counts[$0] }
        var parent = [Int](repeating: -1, count: used.count * 2)
        var queue = Array(weight.indices).sorted { (weight[$0], $0) < (weight[$1], $1) }
        var merged: [Int] = []
        var qi = 0, ii = 0
        func popMin() -> Int {
            if qi < queue.count, ii >= merged.count || weight[queue[qi]] <= weight[merged[ii]] {
                qi += 1
                return queue[qi - 1]
            }
            ii += 1
            return merged[ii - 1]
        }
        while (queue.count - qi) + (merged.count - ii) > 1 {
            let a = popMin(), b = popMin()
            let node = weight.count
            weight.append(weight[a] + weight[b])
            parent[a] = node
            parent[b] = node
            merged.append(node)
        }
        queue.removeAll()
        for (k, symbol) in used.enumerated() {
            var depth = 0, n = k
            while parent[n] >= 0 { depth += 1; n = parent[n] }
            lengths[symbol] = depth
        }
        return lengths
    }

    /// Canonical codes (shorter first, then by symbol), bit-reversed for the LSB-first writer.
    static func canonicalCodes(_ lengths: [Int]) -> [UInt64] {
        let maxLen = lengths.max() ?? 0
        var blCount = [Int](repeating: 0, count: maxLen + 1)
        for l in lengths where l > 0 { blCount[l] += 1 }
        var next = [Int](repeating: 0, count: maxLen + 2)
        var code = 0
        if maxLen > 0 {
            for bits in 1...maxLen {
                code = (code + blCount[bits - 1]) << 1
                next[bits] = code
            }
        }
        var codes = [UInt64](repeating: 0, count: lengths.count)
        for (symbol, l) in lengths.enumerated() where l > 0 {
            let c = next[l]
            next[l] += 1
            var reversed: UInt64 = 0
            for bit in 0..<l where c & (1 << (l - 1 - bit)) != 0 { reversed |= 1 << UInt64(bit) }
            codes[symbol] = reversed
        }
        return codes
    }

    // MARK: Bits

    struct BitWriter {
        private var bytes: [UInt8] = []
        private var accumulator: UInt64 = 0
        private var used = 0

        init() { bytes.reserveCapacity(1 << 16) }

        @inline(__always)
        mutating func write(_ value: UInt64, _ count: Int) {
            guard count > 0 else { return }
            accumulator |= (value & ((1 << UInt64(count)) - 1)) << UInt64(used)
            used += count
            while used >= 8 {
                bytes.append(UInt8(truncatingIfNeeded: accumulator))
                accumulator >>= 8
                used -= 8
            }
        }

        mutating func finish() -> Data {
            if used > 0 { bytes.append(UInt8(truncatingIfNeeded: accumulator)) }
            accumulator = 0
            used = 0
            return Data(bytes)
        }
    }
}
