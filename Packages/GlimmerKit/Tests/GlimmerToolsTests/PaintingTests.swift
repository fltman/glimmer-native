import GlimmerCore
import GlimmerRender
import Metal
import Testing
@testable import GlimmerTools

func ctx() throws -> MetalContext { try #require(MetalContext.shared) }

func value(_ grid: TileGrid, _ x: Int, _ y: Int, default d: Float = 0) -> SIMD4<Float> {
    guard let tile = grid[TileCoord(PixelRect.floorDiv(x, 256), PixelRect.floorDiv(y, 256))] else { return SIMD4(repeating: d) }
    let p = tile.pixels()
    let i = (((y % 256) + 256) % 256 * 256 + ((x % 256) + 256) % 256) * 4
    return SIMD4(Float(p[i]), Float(p[i + 1]), Float(p[i + 2]), Float(p[i + 3]))
}

@Suite struct StrokeSamplerTests {
    @Test func evenSpacingAcrossEvents() {
        var settings = BrushSettings()
        settings.size = 10
        settings.spacing = 0.5  // 5 px
        var sampler = StrokeSampler(settings: settings)
        var dabs = sampler.begin(.init(SIMD2(0, 0)))
        dabs += sampler.move(to: .init(SIMD2(7, 0)))
        dabs += sampler.move(to: .init(SIMD2(21, 0)))
        #expect(dabs.map(\.center.x) == [0, 5, 10, 15, 20])
    }

    @Test func pressureScalesSize() {
        var settings = BrushSettings()
        settings.size = 100
        var sampler = StrokeSampler(settings: settings)
        let light = sampler.begin(.init(.zero, pressure: 0))[0]
        let heavy = sampler.begin(.init(.zero, pressure: 1))[0]
        #expect(abs(light.radius - 7.5) < 0.01 && abs(heavy.radius - 50) < 0.01)
    }
}

@Suite struct StrokeEngineTests {
    func dabs(from: SIMD2<Double>, to: SIMD2<Double>, size: Double = 20, hardness: Double = 1, flow: Double = 1) -> [DabInstance] {
        var s = BrushSettings()
        s.size = size; s.hardness = hardness; s.flow = flow; s.pressureSize = false
        var sampler = StrokeSampler(settings: s)
        return sampler.begin(.init(from)) + sampler.move(to: .init(to))
    }

    @Test func paintsWithOpacityCap() throws {
        let engine = try StrokeEngine(context: try ctx(), tiles: TileGrid(), target: .pixels, erase: false,
                                      color: SIMD4(1, 0, 0, 1), opacity: 0.5, selection: nil)
        // Overlapping dabs build up coverage, but opacity caps the result at 50 %.
        engine.add(dabs(from: SIMD2(100, 100), to: SIMD2(400, 100)))
        engine.add(dabs(from: SIMD2(100, 100), to: SIMD2(400, 100)))
        engine.finish()
        let p = value(engine.result, 300, 100)
        #expect(abs(p.x - 0.5) < 0.01 && abs(p.w - 0.5) < 0.01)
        #expect(value(engine.result, 300, 130).w == 0)
        #expect(engine.result[TileCoord(1, 0)] != nil)  // crossed into the next tile
    }

    @Test func flowBuildsUp() throws {
        let engine = try StrokeEngine(context: try ctx(), tiles: TileGrid(), target: .pixels, erase: false,
                                      color: SIMD4(0, 0, 1, 1), opacity: 1, selection: nil)
        engine.add(dabs(from: SIMD2(50, 50), to: SIMD2(50, 50), flow: 0.2))
        engine.finish()
        let once = value(engine.result, 50, 50).w
        engine.add(dabs(from: SIMD2(50, 50), to: SIMD2(50, 50), flow: 0.2))
        engine.finish()
        let twice = value(engine.result, 50, 50).w
        #expect(abs(once - 0.2) < 0.01 && abs(twice - 0.36) < 0.01)
    }

    @Test func eraseAndSelectionLimit() throws {
        let white = TileGrid.solid(SIMD4(1, 1, 1, 1), covering: PixelRect(x: 0, y: 0, width: 512, height: 256))
        let selection = Selection.rectangle(CGRectLike(x0: 0, y0: 0, x1: 200, y1: 256))
        let engine = try StrokeEngine(context: try ctx(), tiles: white, target: .pixels, erase: true,
                                      color: .zero, opacity: 1, selection: selection)
        engine.add(dabs(from: SIMD2(100, 50), to: SIMD2(300, 50)))
        engine.finish()
        #expect(value(engine.result, 150, 50).w < 0.01)  // erased inside the selection
        #expect(value(engine.result, 250, 50).w > 0.99)  // protected outside
    }

    @Test func paintsMasks() throws {
        let engine = try StrokeEngine(context: try ctx(), tiles: TileGrid(), target: .mask(defaultValue: 1), erase: false,
                                      color: .zero, opacity: 1, maskTarget: 0, selection: nil)
        engine.add(dabs(from: SIMD2(20, 20), to: SIMD2(80, 20)))
        engine.finish()
        #expect(value(engine.result, 50, 20).w < 0.01)  // painted black (hidden)
        #expect(value(engine.result, 50, 60).w > 0.99)  // untouched mask stays white
    }
}

@Suite struct SelectionToolTests {
    @Test func polygonLasso() {
        let tri = Selection.polygon([SIMD2(0, 0), SIMD2(100, 0), SIMD2(0, 100)])
        let v = tri.values(in: PixelRect(x: 0, y: 0, width: 100, height: 100))
        #expect(v[10 * 100 + 10] == 1)
        #expect(v[90 * 100 + 90] == 0)
    }

    @Test func floodFillContiguousAndGlobal() {
        // 4×3: two separate red regions split by a blue column.
        let r: [Float] = [255, 0, 0, 255], b: [Float] = [0, 0, 255, 255]
        let row = r + r + b + r
        let px = row + row + row
        let contiguous = FloodFill.mask(pixels: px, width: 4, height: 3, seed: SIMD2(0, 0), tolerance: 10, contiguous: true)
        #expect(contiguous == [1, 1, 0, 0, 1, 1, 0, 0, 1, 1, 0, 0])
        let global = FloodFill.mask(pixels: px, width: 4, height: 3, seed: SIMD2(0, 0), tolerance: 10, contiguous: false)
        #expect(global == [1, 1, 0, 1, 1, 1, 0, 1, 1, 1, 0, 1])
    }

    @Test func growShrinkFeather() throws {
        let sel = Selection.rectangle(CGRectLike(x0: 100, y0: 100, x1: 200, y1: 200))
        let limit = PixelRect(x: 0, y: 0, width: 512, height: 512)
        let grown = try SelectionOps.apply(.grow(20), to: sel, limit: limit, context: try ctx())
        #expect(grown.values(in: PixelRect(x: 85, y: 150, width: 1, height: 1))[0] > 0.99)
        #expect(grown.values(in: PixelRect(x: 75, y: 150, width: 1, height: 1))[0] < 0.01)
        let shrunk = try SelectionOps.apply(.shrink(20), to: sel, limit: limit, context: try ctx())
        #expect(shrunk.values(in: PixelRect(x: 110, y: 150, width: 1, height: 1))[0] < 0.01)
        #expect(shrunk.values(in: PixelRect(x: 130, y: 150, width: 1, height: 1))[0] > 0.99)
        let feathered = try SelectionOps.apply(.feather(20), to: sel, limit: limit, context: try ctx())
        let edge = feathered.values(in: PixelRect(x: 100, y: 150, width: 1, height: 1))[0]
        #expect(edge > 0.3 && edge < 0.7)
    }

    @Test func keepSelectedAndClear() throws {
        let ops = try PixelOps(context: try ctx())
        let white = TileGrid.solid(SIMD4(1, 1, 1, 1), covering: PixelRect(x: 0, y: 0, width: 256, height: 256))
        let sel = Selection.rectangle(CGRectLike(x0: 0, y0: 0, x1: 128, y1: 256))
        let kept = try ops.run(.keepSelected, on: white, selection: sel, coords: [TileCoord(0, 0)])
        #expect(value(kept, 50, 50).w > 0.99 && value(kept, 200, 50).w < 0.01)
        let cleared = try ops.run(.erase, on: white, selection: sel, coords: [TileCoord(0, 0)])
        #expect(value(cleared, 50, 50).w < 0.01 && value(cleared, 200, 50).w > 0.99)
    }
}

@Suite struct PenDynamicsTests {
    @Test func tiltAndRotationShapeTheDab() {
        var settings = BrushSettings()
        settings.angle = 10
        settings.roundness = 1
        let flat = StrokeSampler.Sample(.zero, tilt: SIMD2(0, 0.8), rotation: 30)
        // Off by default: the brush's own angle and roundness.
        #expect(StrokeSampler.shape(settings, flat) == (10, 1))
        settings.tiltAngle = true
        settings.tiltRoundness = true
        let (angle, roundness) = StrokeSampler.shape(settings, flat)
        #expect(abs(angle - 90) < 1e-9)
        #expect(abs(roundness - 0.36) < 1e-9)
        settings.rotationAngle = true
        #expect(abs(StrokeSampler.shape(settings, flat).angle - 120) < 1e-9)
        // An upright pen keeps the brush angle.
        #expect(StrokeSampler.shape(settings, .init(.zero, rotation: 0)).angle == 10)
    }

    @Test func tiltIsInterpolatedAlongTheStroke() {
        var settings = BrushSettings()
        settings.size = 10
        settings.spacing = 0.5
        settings.tiltRoundness = true
        var sampler = StrokeSampler(settings: settings)
        _ = sampler.begin(.init(.zero, tilt: .zero))
        let dabs = sampler.move(to: .init(SIMD2(100, 0), tilt: SIMD2(1, 0)))
        #expect(dabs.count > 10)
        #expect(dabs.first!.roundness > dabs.last!.roundness)
    }
}
