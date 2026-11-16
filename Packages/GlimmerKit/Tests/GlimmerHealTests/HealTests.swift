#if GLIMMER_HEAL
import Foundation
import Testing
@testable import GlimmerHeal

/// A `w` × `h` opaque image from a function of (x, y) giving grey 0…1.
private func image(_ w: Int, _ h: Int, _ f: (Int, Int) -> Float) -> [Float] {
    var p = [Float](repeating: 1, count: w * h * 4)
    for y in 0..<h { for x in 0..<w { let v = f(x, y); for c in 0..<3 { p[(y * w + x) * 4 + c] = v } } }
    return p
}

private func disc(_ w: Int, _ h: Int, cx: Int, cy: Int, r: Int) -> [Bool] {
    (0..<w * h).map { let x = $0 % w - cx, y = $0 / w - cy; return x * x + y * y <= r * r }
}

/// The largest difference from the original inside the hole.
private func worst(_ a: [Float], _ b: [Float], _ hole: [Bool]) -> Float {
    var m: Float = 0
    for i in hole.indices where hole[i] { for c in 0..<4 { m = max(m, abs(a[i * 4 + c] - b[i * 4 + c])) } }
    return m
}

private func outsideUntouched(_ a: [Float], _ b: [Float], _ hole: [Bool]) -> Bool {
    hole.indices.allSatisfy { i in hole[i] || (0..<4).allSatisfy { a[i * 4 + $0] == b[i * 4 + $0] } }
}

@Suite struct HealAreaTests {
    @Test func distanceIsEuclidean() {
        var mask = [Bool](repeating: false, count: 9 * 7)
        mask[3 * 9 + 4] = true
        let d = Heal.distance(to: mask, width: 9, height: 7)
        #expect(d[3 * 9 + 4] == 0)
        #expect(d[3 * 9 + 7] == 3)
        #expect(abs(d[0] - Float(25).squareRoot()) < 1e-4)
        #expect(Heal.distance(to: [false, false], width: 2, height: 1).allSatisfy { $0 == .infinity })
    }

    @Test func aThinLineIsThinHoweverLong() throws {
        // A 4-pixel-thick line 80 long.
        let w = 100, h = 40
        let coverage = (0..<w * h).map { i -> Float in (10..<90).contains(i % w) && (18..<22).contains(i / w) ? 1 : 0 }
        let area = try #require(Heal.area(coverage: coverage, width: w, height: h, expand: 0))
        #expect(area.pixels == 320)
        #expect(area.thickness >= 3 && area.thickness <= 4)
        #expect(area.bounds == (10, 18, 80, 4))
        let grown = try #require(Heal.area(coverage: coverage, width: w, height: h, expand: 3))
        #expect(grown.thickness >= 9 && grown.thickness <= 10)
        #expect(grown.bounds.x == 7 && grown.bounds.width == 86)
    }

    @Test func aSoftEdgeIsBlendedNotCut() throws {
        let w = 40, h = 1
        // 1 in the middle, falling off over five pixels on each side.
        let coverage = (0..<w).map { x -> Float in max(0, min(1, 1 - Float(abs(x - 20) - 5) / 5)) }
        let area = try #require(Heal.area(coverage: coverage, width: w, height: h, expand: 0))
        #expect(area.weight[20] == 1)
        #expect(area.weight[27] == 1)            // coverage 0.6: fully replaced
        #expect(area.weight[29] > 0 && area.weight[29] < 1)   // coverage 0.2: blended
        #expect(area.hole[29] && !area.hole[31])
        #expect(Heal.area(coverage: [Float](repeating: 0.3, count: 10), width: 10, height: 1, expand: 2) == nil)
    }

    @Test func sizeLimits() {
        #expect(Heal.refusal(pixels: 5000, thickness: 80, allowLarge: false) == nil)
        let soft = Heal.refusal(pixels: 50_000, thickness: 200, allowLarge: false)
        #expect(soft?.reason == "area_too_large" && soft?.hard == false)
        #expect(Heal.refusal(pixels: 50_000, thickness: 200, allowLarge: true) == nil)
        #expect(Heal.refusal(pixels: 500_000, thickness: 600, allowLarge: true)?.hard == true)
        #expect(Heal.refusal(pixels: 5_000_000, thickness: 50, allowLarge: true)?.hard == true)
        #expect(Heal.padding(thickness: 10) == 64 && Heal.padding(thickness: 100) == 200 && Heal.padding(thickness: 300) == 256)
    }
}

@Suite struct HealFillTests {
    @Test func aFlatAreaComesBackFlat() throws {
        let w = 96, h = 96
        let original = image(w, h) { _, _ in 0.4 }
        let hole = disc(w, h, cx: 48, cy: 48, r: 14)
        for method in Heal.Method.allCases {
            let r = try Heal.fill(pixels: original, width: w, height: h, hole: hole, thickness: 28, method: method)
            #expect(worst(r.pixels, original, hole) < 0.002, "\(method)")
            #expect(outsideUntouched(r.pixels, original, hole))
        }
    }

    @Test func aGradientIsContinuedByTheSmoothFill() throws {
        let w = 96, h = 64
        let original = image(w, h) { x, _ in 0.2 + 0.6 * Float(x) / 95 }
        let hole = disc(w, h, cx: 48, cy: 32, r: 6)
        let r = try Heal.fill(pixels: original, width: w, height: h, hole: hole, thickness: 12, method: .smooth)
        #expect(worst(r.pixels, original, hole) < 0.02)
        // Thin holes take the smooth fill by themselves.
        let wire = (0..<w * h).map { (30..<34).contains($0 / w) && (10..<86).contains($0 % w) }
        #expect(try Heal.fill(pixels: original, width: w, height: h, hole: wire, thickness: 4).method == .smooth)
    }

    @Test func stripesAndChecksComeBackExactlyFromTheTextureFill() throws {
        let w = 128, h = 128
        for (name, original) in [("stripes", image(w, h) { x, _ in (x / 4) % 2 == 0 ? 0.15 : 0.8 }),
                                 ("checks", image(w, h) { x, y in ((x / 6) + (y / 6)) % 2 == 0 ? 0.1 : 0.9 })] {
            let hole = disc(w, h, cx: 64, cy: 64, r: 16)
            let auto = try Heal.fill(pixels: original, width: w, height: h, hole: hole, thickness: 32)
            #expect(auto.method == .texture, "\(name)")
            #expect(worst(auto.pixels, original, hole) == 0, "\(name)")
            #expect(outsideUntouched(auto.pixels, original, hole))
        }
    }

    @Test func theSameInputGivesTheSameBytes() throws {
        let w = 120, h = 100
        // Texture without a period, from a fixed integer hash.
        let original = image(w, h) { x, y in
            var v = UInt32(truncatingIfNeeded: x &* 73_856_093 ^ y &* 19_349_663)
            v ^= v >> 13; v = v &* 0x5bd1_e995; v ^= v >> 15
            return Float(v % 1000) / 1000
        }
        let hole = disc(w, h, cx: 60, cy: 50, r: 12)
        for method in [Heal.Method.smooth, .texture] {
            let a = try Heal.fill(pixels: original, width: w, height: h, hole: hole, thickness: 24, method: method)
            let b = try Heal.fill(pixels: original, width: w, height: h, hole: hole, thickness: 24, method: method)
            #expect(a.pixels == b.pixels, "\(method)")
            #expect(outsideUntouched(a.pixels, original, hole))
        }
        #expect(try Heal.fill(pixels: original, width: w, height: h, hole: hole, thickness: 24).method == .texture)
    }

    @Test func everyFilledPixelOfTheTextureFillIsACopyOfAnExistingOne() throws {
        let w = 90, h = 90
        let original = image(w, h) { x, y in Float((x * 7 + y * 13) % 31) / 31 }
        let hole = disc(w, h, cx: 45, cy: 45, r: 10)
        let r = try Heal.fill(pixels: original, width: w, height: h, hole: hole, thickness: 20, method: .texture)
        let present = Set(hole.indices.filter { !hole[$0] }.map { original[$0 * 4] })
        #expect(hole.indices.filter { hole[$0] }.allSatisfy { present.contains(r.pixels[$0 * 4]) })
    }

    @Test func transparentPixelsAreNeverCopied() throws {
        let w = 80, h = 80
        var original = image(w, h) { x, _ in (x / 3) % 2 == 0 ? 0.2 : 0.7 }
        for y in 0..<h { for x in 50..<w { for c in 0..<4 { original[(y * w + x) * 4 + c] = 0 } } }   // right part empty
        let hole = disc(w, h, cx: 25, cy: 40, r: 8)
        let r = try Heal.fill(pixels: original, width: w, height: h, hole: hole, thickness: 16, method: .texture)
        #expect(hole.indices.filter { hole[$0] }.allSatisfy { r.pixels[$0 * 4 + 3] == 1 })
    }

    /// What is in the hole is being thrown away, so it must not colour the fill: a black
    /// wire and a white one over the same picture give the same bytes. (The smooth fill
    /// once let a hole pixel into its neighbours' gradients.)
    @Test func whatIsInTheHoleNeverReachesTheFill() throws {
        let w = 200, h = 80
        let base = image(w, h) { x, y in 0.3 + 0.4 * Float((x * 7 + y * 13) % 31) / 31 }
        let wire = (0..<w * h).map { (36..<47).contains($0 / w) }
        let blob = disc(w, h, cx: 100, cy: 40, r: 15)
        for hole in [wire, blob] {
            var black = base, white = base
            for i in hole.indices where hole[i] { for c in 0..<3 { black[i * 4 + c] = 0; white[i * 4 + c] = 1 } }
            for method in [Heal.Method.smooth, .texture, .auto] {
                let a = try Heal.fill(pixels: black, width: w, height: h, hole: hole, thickness: 11, method: method)
                let b = try Heal.fill(pixels: white, width: w, height: h, hole: hole, thickness: 11, method: method)
                #expect(a.pixels == b.pixels, "\(method)")
                #expect(a.method == b.method)
            }
        }
    }

    /// The smooth fill stays within the range of the picture around it, however large the
    /// hole and however noisy the picture. (Extending gradients of already-filled pixels
    /// once made it run away into stripes of pure black, white and colour.)
    @Test func theSmoothFillNeverOvershoots() throws {
        let w = 260, h = 220
        let noisy = image(w, h) { x, y in
            var v = UInt32(truncatingIfNeeded: x &* 73_856_093 ^ y &* 19_349_663)
            v ^= v >> 13; v = v &* 0x5bd1_e995; v ^= v >> 15
            return 0.4 + 0.2 * Float(v % 1000) / 1000
        }
        let hole = disc(w, h, cx: 130, cy: 110, r: 80)
        let r = try Heal.fill(pixels: noisy, width: w, height: h, hole: hole, thickness: 160, method: .smooth)
        for i in hole.indices where hole[i] {
            #expect(r.pixels[i * 4] >= 0.4 && r.pixels[i * 4] <= 0.6 && r.pixels[i * 4 + 3] == 1)
        }
    }

    @Test func refusals() {
        let w = 40, h = 40
        let original = image(w, h) { _, _ in 0.5 }
        let most = (0..<w * h).map { $0 % w > 5 }
        #expect { try Heal.fill(pixels: original, width: w, height: h, hole: most, thickness: 30) } throws: { ($0 as? Heal.Refusal)?.reason == "nothing_to_sample" }
        // Bands of image narrower than a patch: the texture fill has nothing whole to copy; auto fills smoothly.
        let bands = (0..<w * h).map { ($0 % w) % 16 >= 8 }
        #expect { try Heal.fill(pixels: original, width: w, height: h, hole: bands, thickness: 8, method: .texture) } throws: { ($0 as? Heal.Refusal)?.reason == "nothing_to_sample" }
        let textured = image(w, h) { x, y in Float((x * 7 + y * 13) % 31) / 31 }
        #expect((try? Heal.fill(pixels: textured, width: w, height: h, hole: bands, thickness: 8))?.method == .smooth)
        // Nothing to do.
        #expect((try? Heal.fill(pixels: original, width: w, height: h, hole: [Bool](repeating: false, count: w * h), thickness: 1))?.pixels == original)
    }

    @Test func cancelStops() {
        let w = 128, h = 128
        let original = image(w, h) { x, y in Float((x * 5 + y * 3) % 17) / 17 }
        let hole = disc(w, h, cx: 64, cy: 64, r: 30)
        #expect(throws: CancellationError.self) {
            try Heal.fill(pixels: original, width: w, height: h, hole: hole, thickness: 60, method: .texture, isCancelled: { true })
        }
    }
}
#endif
