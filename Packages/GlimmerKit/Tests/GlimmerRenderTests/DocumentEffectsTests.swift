import GlimmerCore
import Metal
import Testing
@testable import GlimmerRender

@Suite struct DocumentEffectsTests {
    /// Left half white, right half black.
    func split(_ w: Int, _ h: Int) -> DocumentState {
        var grid = TileGrid.solid(SIMD4(0, 0, 0, 1), covering: PixelRect(x: 0, y: 0, width: w, height: h))
        let white = TileGrid.solid(SIMD4(1, 1, 1, 1), covering: PixelRect(x: 0, y: 0, width: w / 2, height: h))
        for (c, t) in white.tiles { grid[c] = t }
        return DocumentState(width: w, height: h, layers: [Layer(name: "s", content: .raster(grid))])
    }

    func pixel(_ grid: TileGrid, _ x: Int, _ y: Int) -> SIMD4<Float> {
        let c = TileCoord(x / 256, y / 256)
        let p = grid[c]!.pixels()
        let i = ((y % 256) * 256 + x % 256) * 4
        return SIMD4(Float(p[i]), Float(p[i + 1]), Float(p[i + 2]), Float(p[i + 3]))
    }

    @Test func inFocusStaysSharpOutOfFocusBlurs() throws {
        let ctx = try context()
        let state = split(512, 256)
        let sharp = try DocumentEffects.lensBlur(state, depth: [Float](repeating: 0.8, count: 512 * 256),
                                                 parameters: .init(focus: 0.8, amount: 0.03), context: ctx)
        #expect(pixel(sharp, 254, 100).x > 0.99 && pixel(sharp, 258, 100).x < 0.01)
        let blurred = try DocumentEffects.lensBlur(state, depth: [Float](repeating: 0, count: 512 * 256),
                                                   parameters: .init(focus: 1, amount: 0.03, bokeh: 0), context: ctx)
        let edge = pixel(blurred, 256, 100).x
        #expect(edge > 0.2 && edge < 0.8, "edge \(edge)")
        #expect(pixel(blurred, 50, 100).x > 0.99)
    }

    @Test func upscaleDoublesTheDocument() throws {
        let grid = try DocumentEffects.upscale(split(512, 100), scale: 2, context: try context())
        #expect(Set(grid.tiles.keys) == Set(PixelRect(x: 0, y: 0, width: 1024, height: 200).tileCoords))
        #expect(pixel(grid, 100, 50).x > 0.99)
        #expect(pixel(grid, 900, 50).x < 0.01)
        #expect(pixel(grid, 1023, 199).w > 0.99)
        #expect(pixel(grid, 100, 210).w == 0)  // below the new size: cleared
    }
}
