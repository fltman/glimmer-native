import GlimmerCore
import Metal
import Testing
@testable import GlimmerRender

@Suite struct FilterEngineTests {
    let frame = PixelRect(x: 0, y: 0, width: 512, height: 256)

    /// Left half white, right half black.
    func split() -> TileGrid {
        var grid = TileGrid.solid(SIMD4(0, 0, 0, 1), covering: frame)
        for (c, t) in TileGrid.solid(SIMD4(1, 1, 1, 1), covering: PixelRect(x: 0, y: 0, width: 256, height: 256)).tiles {
            grid[c] = t
        }
        return grid
    }

    func pixel(_ grid: TileGrid, _ x: Int, _ y: Int) -> SIMD4<Float> {
        let p = grid[TileCoord(x / 256, y / 256)]!.pixels()
        let i = ((y % 256) * 256 + x % 256) * 4
        return SIMD4(Float(p[i]), Float(p[i + 1]), Float(p[i + 2]), Float(p[i + 3]))
    }

    @Test func gaussianBlursEdgesAndClampsAtTheFrame() throws {
        let out = try FilterEngine(context: try context()).apply(FilterSettings(.gaussianBlur, ["radius": 8]), to: split(),
                                                                 frame: frame, selection: nil)
        let edge = pixel(out, 256, 100).x
        #expect(edge > 0.1 && edge < 0.6, "edge \(edge)")
        #expect(pixel(out, 0, 0).x > 0.995 && pixel(out, 0, 0).w > 0.995, "\(pixel(out, 0, 0))")  // clamped, not faded
        #expect(pixel(out, 511, 255).w > 0.999)
        #expect(pixel(out, 100, 100).x > 0.999)
    }

    @Test func selectionLimitsTheFilter() throws {
        let selection = Selection.rectangle(CGRectLike(x0: 0, y0: 0, x1: 128, y1: 256))
        let out = try FilterEngine(context: try context()).apply(FilterSettings(.vignette, ["amount": 1, "midpoint": 0, "feather": 0.1]),
                                                                 to: split(), frame: frame, selection: selection)
        #expect(pixel(out, 2, 2).x < 0.2)          // selected corner darkened
        #expect(pixel(out, 200, 2).x > 0.999)      // outside the selection unchanged
    }

    @Test func everyFilterRunsAndKeepsOpaquePixelsOpaque() throws {
        let engine = try FilterEngine(context: try context())
        for kind in FilterKind.allCases {
            let out = try engine.apply(FilterSettings(kind), to: split(), frame: frame, selection: nil)
            for (x, y) in [(10, 10), (255, 128), (300, 200)] {
                let p = pixel(out, x, y)
                #expect(abs(p.w - 1) < 0.002, "\(kind) alpha at \(x),\(y): \(p)")
                #expect(!p.x.isNaN && !p.y.isNaN && !p.z.isNaN, "\(kind) NaN")
            }
        }
    }

    @Test func noiseIsDeterministic() throws {
        let engine = try FilterEngine(context: try context())
        let a = try engine.apply(FilterSettings(.addNoise, ["amount": 0.3]), to: split(), frame: frame, selection: nil)
        let b = try engine.apply(FilterSettings(.addNoise, ["amount": 0.3]), to: split(), frame: frame, selection: nil)
        #expect(pixel(a, 300, 30) == pixel(b, 300, 30))
        #expect(pixel(a, 300, 30) != pixel(a, 301, 30))
    }

    @Test func cloneSourceIsShifted() throws {
        let out = try FilterEngine(context: try context()).shifted(split(), by: SIMD2(256, 0), region: frame)
        #expect(pixel(out, 300, 10).x > 0.999)   // white copied from x = 44
        #expect(pixel(out, 10, 10).w == 0)       // nothing to the left of the image
    }

    @Test func healingMatchesTheDestinationTone() throws {
        // Clone the white half onto the black half: the heal keeps the destination's (black) tone.
        let out = try FilterEngine(context: try context()).healed(split(), by: SIMD2(256, 0), region: frame, sigma: 8)
        #expect(pixel(out, 400, 128).x < 0.02)
    }

    @Test func smudgeDragsColour() throws {
        let smudge = try SmudgeEngine(context: try context(), tiles: split(), region: frame, selection: nil)
        var dabs: [SmudgeDab] = []
        for x in stride(from: 230, through: 300, by: 4) {
            dabs.append(SmudgeDab(centre: SIMD2(Float(x), 128), delta: SIMD2(4, 0), radius: 12, hardness: 0.5, strength: 0.9))
        }
        smudge.add(dabs)
        smudge.finish()
        #expect(pixel(smudge.result, 262, 128).x > 0.3)
        #expect(pixel(smudge.result, 400, 128).x < 0.001)
    }

    @Test func dodgeLightensAndBurnDarkens() throws {
        let ops = try PixelOps(context: try context())
        let grey = TileGrid.solid(SIMD4(0.2, 0.2, 0.2, 1), covering: PixelRect(x: 0, y: 0, width: 256, height: 256))
        let coords = [TileCoord(0, 0)]
        let dodged = try ops.run(.dodge, on: grey, selection: nil, coords: coords, color: SIMD4(1, 1, 0, 0))
        let burned = try ops.run(.burn, on: grey, selection: nil, coords: coords, color: SIMD4(1, 1, 0, 0))
        #expect(pixel(dodged, 5, 5).x > 0.25)
        #expect(pixel(burned, 5, 5).x < 0.15)
    }
}

@Suite struct LiquifyTests {
    @Test func forwardWarpPushesAndReconstructRestores() throws {
        let frame = PixelRect(x: 0, y: 0, width: 512, height: 256)
        let suite = FilterEngineTests()
        let engine = try LiquifyEngine(context: try context(), tiles: suite.split(), region: frame)
        #expect(try engine.render().contentSignature == engine.original.contentSignature)
        // Push the white half into the black half.
        for x in stride(from: 230.0, through: 290.0, by: 4) {
            engine.dab(.forward, at: SIMD2(x, 128), delta: SIMD2(4, 0), radius: 40, strength: 1)
        }
        let warped = try engine.render()
        #expect(suite.pixel(warped, 270, 128).x > 0.9)
        #expect(suite.pixel(warped, 450, 128).x < 0.001)
        for _ in 0..<40 { engine.dab(.restore, at: SIMD2(270, 128), delta: .zero, radius: 80, strength: 1) }
        #expect(suite.pixel(try engine.render(), 270, 128).x < 0.05)
    }
}
