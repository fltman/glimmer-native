#if GLIMMER_HEAL
import Foundation
import Testing
@testable import GlimmerHeal

/// Timings for docs and limits; run with GLIMMER_HEAL_TIMING=1 and -Xswiftc -O.
@Suite struct HealTimingTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["GLIMMER_HEAL_TIMING"] != nil))
    func textureFillBySize() throws {
        for across in [30, 60, 120, 200, 250] {
            let pad = Heal.padding(thickness: Double(across))
            let w = across + 2 * pad, h = w
            var p = [Float](repeating: 1, count: w * h * 4)
            for i in 0..<w * h {
                var v = UInt32(truncatingIfNeeded: (i % w / 3) &* 73_856_093 ^ (i / w / 3) &* 19_349_663)
                v ^= v >> 13; v = v &* 0x5bd1_e995; v ^= v >> 15
                for c in 0..<3 { p[i * 4 + c] = Float((v >> UInt32(c * 3)) % 256) / 255 }
            }
            let hole = (0..<w * h).map { let x = $0 % w - w / 2, y = $0 / w - h / 2; return x * x + y * y <= across * across / 4 }
            for method in [Heal.Method.smooth, .texture] {
                let t = Date()
                _ = try Heal.fill(pixels: p, width: w, height: h, hole: hole, thickness: Double(across), method: method)
                print("TIMING \(method) across \(across) window \(w): \(String(format: "%.2f", Date().timeIntervalSince(t))) s")
            }
        }
    }
}
#endif
