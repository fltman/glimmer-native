import Foundation

/// Magic-wand / paint-bucket region growing on straight 8-bit-range RGBA pixels.
public enum FloodFill {
    /// A 0/1 mask of pixels within `tolerance` (0...255, max channel difference)
    /// of the colour at `seed`. `contiguous` grows from the seed (4-connected);
    /// otherwise every matching pixel is included.
    public static func mask(pixels: [Float], width: Int, height: Int, seed: SIMD2<Int>,
                            tolerance: Float, contiguous: Bool) -> [Float] {
        var mask = [Float](repeating: 0, count: width * height)
        guard seed.x >= 0, seed.y >= 0, seed.x < width, seed.y < height else { return mask }
        let s = (seed.y * width + seed.x) * 4
        let target = SIMD4(pixels[s], pixels[s + 1], pixels[s + 2], pixels[s + 3])
        @inline(__always) func matches(_ i: Int) -> Bool {
            let o = i * 4
            let d = SIMD4(pixels[o], pixels[o + 1], pixels[o + 2], pixels[o + 3]) - target
            return max(max(abs(d.x), abs(d.y)), max(abs(d.z), abs(d.w))) <= tolerance
        }
        if !contiguous {
            for i in 0..<(width * height) where matches(i) { mask[i] = 1 }
            return mask
        }
        // Scanline fill.
        var stack = [seed]
        while let p = stack.popLast() {
            var x = p.x
            let y = p.y
            let row = y * width
            guard mask[row + x] == 0, matches(row + x) else { continue }
            while x > 0, mask[row + x - 1] == 0, matches(row + x - 1) { x -= 1 }
            var spanAbove = false, spanBelow = false
            while x < width, mask[row + x] == 0, matches(row + x) {
                mask[row + x] = 1
                if y > 0 {
                    let a = row - width + x
                    let ok = mask[a] == 0 && matches(a)
                    if ok && !spanAbove { stack.append(SIMD2(x, y - 1)) }
                    spanAbove = ok
                }
                if y < height - 1 {
                    let b = row + width + x
                    let ok = mask[b] == 0 && matches(b)
                    if ok && !spanBelow { stack.append(SIMD2(x, y + 1)) }
                    spanBelow = ok
                }
                x += 1
            }
        }
        return mask
    }
}
