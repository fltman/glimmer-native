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

extension PerformanceTests {
    func photoLayer(_ size: Int) -> TileGrid {
        let tiles = (0..<4).map { textureTile(SIMD4(Float($0) * 0.2, 0.3, 0.5, 1)) }
        var grid = TileGrid()
        for (n, c) in PixelRect(x: 0, y: 0, width: size, height: size).tileCoords.enumerated() { grid[c] = tiles[n % 4] }
        return grid
    }

    @Test func filtersOnAn8kLayer() throws {
        let engine = try FilterEngine(context: try context())
        let grid = photoLayer(8192)
        let frame = PixelRect(x: 0, y: 0, width: 8192, height: 8192)
        let clock = ContinuousClock()
        for f in [FilterSettings(.gaussianBlur, ["radius": 20]), FilterSettings(.vignette), FilterSettings(.unsharpMask)] {
            let t = try clock.measure { _ = try engine.apply(f, to: grid, frame: frame, selection: nil) }
            print("\(f.kind.title) on 8k × 8k: \(t)")
            #expect(t < .seconds(3))
        }
    }

    /// Phase 5 budget: a batch of brush dabs on an 8k layer stays under a frame.
    @Test func brushDabsOnAn8kLayer() throws {
        let ctx = try context()
        let engine = try StrokeEngine(context: ctx, tiles: photoLayer(8192), target: .pixels, erase: false,
                                      color: SIMD4(1, 0, 0, 1), opacity: 1, selection: nil)
        let dabs = (0..<12).map { i in DabInstance(center: SIMD2(4000 + Float(i) * 6, 4000), radius: 60, hardness: 0.8, flow: 1) }
        engine.add(dabs)
        engine.finish()
        let clock = ContinuousClock()
        let t = clock.measure {
            engine.add(dabs.map { var d = $0; d.center.y += 30; return d })
            engine.finish()
        }
        print("12 dabs (r 60) on 8k layer: \(t)")
        #expect(t < .milliseconds(16))
    }

    @Test func liquifyRenderOn4k() throws {
        let engine = try LiquifyEngine(context: try context(), tiles: photoLayer(4096), region: PixelRect(x: 0, y: 0, width: 4096, height: 4096))
        engine.dab(.forward, at: SIMD2(2000, 2000), delta: SIMD2(10, 0), radius: 200, strength: 0.5)
        _ = try engine.render()
        let t = try ContinuousClock().measure {
            engine.dab(.forward, at: SIMD2(2010, 2000), delta: SIMD2(10, 0), radius: 200, strength: 0.5)
            _ = try engine.render()
        }
        print("Liquify dab + render on 4k: \(t)")
        #expect(t < .milliseconds(150))
    }
}

@Suite struct SmartFilterTests {
    @Test func smartFiltersRenderAndToggle() throws {
        let source = TileGrid.solid(SIMD4(1, 1, 1, 1), covering: PixelRect(x: 0, y: 0, width: 512, height: 512))
        var smart = SmartObject(source: source, width: 512, height: 512, transform: .identity)
        smart.filters = [SmartFilter(FilterSettings(.vignette, ["amount": 1, "midpoint": 0, "feather": 0.2]))]
        var state = DocumentState(width: 512, height: 512, layers: [Layer(name: "s", content: .smart(smart))])
        let corner = try renderPixel(state, x: 2, y: 2)
        let centre = try renderPixel(state, x: 256, y: 256)
        #expect(corner.x < 0.1 && centre.x > 0.9, "corner \(corner) centre \(centre)")
        smart.filters[0].isEnabled = false
        state.layers[0].content = .smart(smart)
        #expect(try renderPixel(state, x: 2, y: 2).x > 0.99)
    }
}
