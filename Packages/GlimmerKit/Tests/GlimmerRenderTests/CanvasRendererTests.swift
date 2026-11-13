import Foundation
import GlimmerCore
import ImageIO
import Metal
import Testing
import simd
@testable import GlimmerRender

// MARK: Helpers

func context() throws -> MetalContext {
    try #require(MetalContext.shared, "Metal is unavailable")
}

func solidLayer(_ color: SIMD4<Float>, size: Int = 256, opacity: Double = 1, mode: BlendMode = .normal) -> Layer {
    Layer(name: "L", opacity: opacity, blendMode: mode,
          content: .raster(.solid(color, covering: PixelRect(x: 0, y: 0, width: size, height: size))))
}

/// A texture tile filled with one colour (forces the texture path, not `.solid`).
func textureTile(_ color: SIMD4<Float>) -> Tile {
    let s = TileGeometry.size
    var px = [Float16](repeating: 0, count: s * s * 4)
    for i in stride(from: 0, to: px.count, by: 4) {
        px[i] = Float16(color.x); px[i + 1] = Float16(color.y); px[i + 2] = Float16(color.z); px[i + 3] = Float16(color.w)
    }
    px[0] = Float16(color.x) + 0.001  // break uniformity at one corner pixel
    let texture = TileTexture.makeTexture()
    px.withUnsafeBytes {
        texture.replace(region: MTLRegionMake2D(0, 0, s, s), mipmapLevel: 0,
                        withBytes: $0.baseAddress!, bytesPerRow: TileGeometry.bytesPerRow)
    }
    return .texture(TileTexture(texture))
}

func renderPixel(_ state: DocumentState, x: Int, y: Int, overrides: LayerOverrides = .none) throws -> SIMD4<Float> {
    let compositor = try DocumentCompositor(context: try context())
    let (buffer, bytesPerRow, rect) = try compositor.renderPixels(
        state, overrides: overrides, region: PixelRect(x: x, y: y, width: 1, height: 1))
    #expect(rect.width == 1 && bytesPerRow == 8)
    let h = buffer.contents().load(as: SIMD4<Float16>.self)
    return SIMD4<Float>(h)
}

// MARK: CPU reference (W3C Compositing and Blending Level 1), independent of the shader

enum Reference {
    static func lum(_ c: SIMD3<Float>) -> Float { 0.3 * c.x + 0.59 * c.y + 0.11 * c.z }
    static func clip(_ c: SIMD3<Float>) -> SIMD3<Float> {
        let l = lum(c), n = c.min(), x = c.max()
        var c = c
        if n < 0 { c = l + (c - l) * l / (l - n) }
        if x > 1 { c = l + (c - l) * (1 - l) / (x - l) }
        return c
    }
    static func setLum(_ c: SIMD3<Float>, _ l: Float) -> SIMD3<Float> { clip(c + (l - lum(c))) }
    static func sat(_ c: SIMD3<Float>) -> Float { c.max() - c.min() }
    static func setSat(_ c: SIMD3<Float>, _ s: Float) -> SIMD3<Float> {
        let r = c.max() - c.min()
        return r <= 1e-6 ? .zero : (c - c.min()) * s / r
    }
    static func each(_ b: SIMD3<Float>, _ s: SIMD3<Float>, _ f: (Float, Float) -> Float) -> SIMD3<Float> {
        SIMD3(f(b.x, s.x), f(b.y, s.y), f(b.z, s.z))
    }
    static func hardLight(_ b: Float, _ s: Float) -> Float { s <= 0.5 ? b * 2 * s : b + (2 * s - 1) - b * (2 * s - 1) }

    static func blend(_ b: SIMD3<Float>, _ s: SIMD3<Float>, _ mode: BlendMode) -> SIMD3<Float> {
        switch mode {
        case .normal, .passThrough: s
        case .multiply: b * s
        case .screen: b + s - b * s
        case .overlay: each(b, s) { hardLight($1, $0) }
        case .darken: simd_min(b, s)
        case .lighten: simd_max(b, s)
        case .colorDodge: each(b, s) { b, s in b == 0 ? 0 : (s >= 1 ? 1 : min(1, b / (1 - s))) }
        case .colorBurn: each(b, s) { b, s in b >= 1 ? 1 : (s <= 0 ? 0 : 1 - min(1, (1 - b) / s)) }
        case .hardLight: each(b, s, hardLight)
        case .softLight: each(b, s) { b, s in
            let d = b <= 0.25 ? ((16 * b - 12) * b + 4) * b : b.squareRoot()
            return s <= 0.5 ? b - (1 - 2 * s) * b * (1 - b) : b + (2 * s - 1) * (d - b)
        }
        case .difference: abs(b - s)
        case .exclusion: b + s - 2 * b * s
        case .linearDodge: simd_min(b + s, SIMD3(repeating: 1))
        case .linearBurn: simd_max(b + s - 1, .zero)
        case .hue: setLum(setSat(s, sat(b)), lum(b))
        case .saturation: setLum(setSat(b, sat(s)), lum(b))
        case .color: setLum(s, lum(b))
        case .luminosity: setLum(b, lum(s))
        }
    }

    /// Straight-colour backdrop/source in, premultiplied result out (linear blend space).
    static func composite(backdrop cb: SIMD3<Float>, ab: Float, source cs: SIMD3<Float>, as a: Float,
                          opacity: Float, mode: BlendMode) -> SIMD4<Float> {
        let asrc = a * opacity
        let mixed = (1 - ab) * cs + ab * blend(cb, cs, mode)
        let ao = asrc + ab * (1 - asrc)
        let premul = asrc * mixed + (1 - asrc) * ab * cb
        return SIMD4(premul, ao)
    }
}

// MARK: Tests

@Suite struct BlendModeTests {
    static let cases: [(cb: SIMD3<Float>, cs: SIMD3<Float>)] = [
        (SIMD3(0.2, 0.5, 0.8), SIMD3(0.7, 0.3, 0.1)),
        (SIMD3(0.9, 0.1, 0.4), SIMD3(0.25, 0.6, 0.95)),
    ]

    @Test(arguments: BlendMode.pixelModes)
    func matchesReference(mode: BlendMode) throws {
        for (cb, cs) in Self.cases {
            let ab: Float = 0.8, a: Float = 0.6, opacity: Float = 0.75
            var source = TileGrid()
            source[TileCoord(0, 0)] = textureTile(SIMD4(cs * a, a))
            let state = DocumentState(width: 256, height: 256, layers: [
                solidLayer(SIMD4(cb * ab, ab)),
                Layer(name: "src", opacity: Double(opacity), blendMode: mode, content: .raster(source)),
            ])
            let got = try renderPixel(state, x: 10, y: 10)
            let want = Reference.composite(backdrop: cb, ab: ab, source: cs, as: a, opacity: opacity, mode: mode)
            #expect(simd_length(got - want) < 0.004, "\(mode): got \(got), want \(want)")
        }
    }

    @Test func knownValues() throws {
        // Opaque 0.5 grey multiplied by itself is 0.25 in linear space.
        let state = DocumentState(width: 256, height: 256, layers: [
            solidLayer(SIMD4(0.5, 0.5, 0.5, 1)), solidLayer(SIMD4(0.5, 0.5, 0.5, 1), mode: .multiply),
        ])
        let got = try renderPixel(state, x: 0, y: 0)
        #expect(abs(got.x - 0.25) < 0.001 && abs(got.w - 1) < 0.001)

        // A fully transparent source leaves the backdrop untouched in every mode.
        for mode in BlendMode.pixelModes {
            let s = DocumentState(width: 256, height: 256, layers: [
                solidLayer(SIMD4(0.3, 0.2, 0.1, 1)), solidLayer(SIMD4(0.9, 0.9, 0.9, 1), opacity: 0, mode: mode),
            ])
            #expect(simd_length(try renderPixel(s, x: 5, y: 5) - SIMD4(0.3, 0.2, 0.1, 1)) < 0.001)
        }
    }

    @Test func gammaBlendSpaceDiffersFromLinear() throws {
        var state = DocumentState(width: 256, height: 256, layers: [
            solidLayer(SIMD4(0.5, 0.5, 0.5, 1)), solidLayer(SIMD4(0.5, 0.5, 0.5, 1), mode: .multiply),
        ])
        state.blendSpace = .gamma
        // In gamma space: encode(0.5) = 0.7354; squared = 0.5408; decode → 0.2541
        let got = try renderPixel(state, x: 0, y: 0)
        #expect(abs(got.x - 0.2541) < 0.002)
    }
}

@Suite struct CompositorTests {
    @Test func cachesUntilInputsChange() throws {
        let ctx = try context()
        let compositor = try DocumentCompositor(context: ctx)
        var state = DocumentState(width: 512, height: 256, layers: [solidLayer(SIMD4(1, 0, 0, 1), size: 512)])
        let coords = state.bounds.tileCoords

        func run() throws -> Bool {
            let cb = try #require(ctx.commandQueue.makeCommandBuffer())
            let more = compositor.update(state, coords: coords, budget: 1, commandBuffer: cb)
            cb.commit(); cb.waitUntilCompleted()
            return more
        }
        #expect(try run() == true)   // budget 1 of 2 stale tiles
        #expect(try run() == false)  // second tile
        let first = try #require(compositor.texture(at: TileCoord(0, 0)))
        #expect(try run() == false)  // nothing stale
        #expect(compositor.texture(at: TileCoord(0, 0)) === first)

        state.layers[0].opacity = 0.5
        #expect(try run() == true)
        state.layers[0].isVisible = false
        _ = try run(); _ = try run()
        #expect(compositor.texture(at: TileCoord(0, 0)) == nil)  // nothing visible → no texture
    }

    /// Regression: tiles rendered in a budget-limited pass must still get mipmaps,
    /// or zoomed-out views show stale content.
    @Test func budgetedPassStillGeneratesMipmaps() throws {
        let ctx = try context()
        let compositor = try DocumentCompositor(context: ctx)
        let coords = PixelRect(x: 0, y: 0, width: 512, height: 256).tileCoords
        func pass(_ state: DocumentState) throws {
            let cb = try #require(ctx.commandQueue.makeCommandBuffer())
            compositor.update(state, coords: coords, budget: 1, commandBuffer: cb)
            cb.commit(); cb.waitUntilCompleted()
        }
        try pass(DocumentState(width: 512, height: 256, layers: [solidLayer(SIMD4(1, 1, 1, 1), size: 512)]))
        try pass(DocumentState(width: 512, height: 256, layers: [solidLayer(SIMD4(1, 1, 1, 1), size: 512)]))
        let red = DocumentState(width: 512, height: 256, layers: [solidLayer(SIMD4(1, 0, 0, 1), size: 512)])
        try pass(red)  // re-renders tile 0 only (budget 1)

        let texture = try #require(compositor.texture(at: coords[0]))
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: TileGeometry.pixelFormat, width: 1, height: 1, mipmapped: false)
        d.storageMode = .shared
        let probe = try #require(ctx.device.makeTexture(descriptor: d))
        let cb = try #require(ctx.commandQueue.makeCommandBuffer())
        let blit = try #require(cb.makeBlitCommandEncoder())
        blit.copy(from: texture, sourceSlice: 0, sourceLevel: 4, sourceOrigin: MTLOrigin(),
                  sourceSize: MTLSize(width: 1, height: 1, depth: 1),
                  to: probe, destinationSlice: 0, destinationLevel: 0, destinationOrigin: MTLOrigin())
        blit.endEncoding(); cb.commit(); cb.waitUntilCompleted()
        var px = SIMD4<Float16>()
        probe.getBytes(&px, bytesPerRow: 8, from: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0)
        #expect(Float(px.y) < 0.01, "mip level 4 is stale: \(px)")
    }

    @Test func overridesOffsetALayer() throws {
        var grid = TileGrid()
        grid[TileCoord(0, 0)] = textureTile(SIMD4(0, 1, 0, 1))
        let layer = Layer(name: "g", content: .raster(grid))
        let state = DocumentState(width: 512, height: 512, layers: [layer])
        let moved = LayerOverrides(offsets: [layer.id: SIMD2(300, 10)])
        #expect(try renderPixel(state, x: 310, y: 20, overrides: moved).y > 0.99)
        #expect(try renderPixel(state, x: 299, y: 20, overrides: moved).w == 0)
        #expect(try renderPixel(state, x: 310, y: 20).w == 0)
    }
}

@Suite struct TileOperationsTests {
    @Test(arguments: [SIMD2(300, -20), SIMD2(256, 512), SIMD2(-1, 1)])
    func translateMatchesOffsetRendering(offset: SIMD2<Int>) throws {
        let ctx = try context()
        var grid = TileGrid()
        grid[TileCoord(0, 0)] = textureTile(SIMD4(0.2, 0.4, 0.6, 1))
        grid[TileCoord(1, 0)] = .solid(SIMD4(0, 0, 0.5, 0.5))
        let moved = try TileOperations.translate(grid, by: offset, context: ctx)

        let layer = Layer(name: "a", content: .raster(grid))
        let bounds = PixelRect(x: -512, y: -512, width: 2048, height: 2048)
        for (x, y) in [(5, 5), (300, 100), (600, 0), (offset.x + 1, offset.y + 1), (offset.x + 400, offset.y + 30)] {
            let viaOverride = try renderPixel(
                DocumentState(width: 4096, height: 4096, layers: [layer]),
                x: x - bounds.x, y: y - bounds.y,
                overrides: LayerOverrides(offsets: [layer.id: SIMD2(offset.x - bounds.x, offset.y - bounds.y)]))
            let translated = try TileOperations.translate(moved, by: SIMD2(-bounds.x, -bounds.y), context: ctx)
            let viaTranslate = try renderPixel(
                DocumentState(width: 4096, height: 4096, layers: [Layer(name: "b", content: .raster(translated))]),
                x: x - bounds.x, y: y - bounds.y)
            #expect(viaOverride == viaTranslate, "at \(x),\(y)")
        }
    }

    @Test func wholeTileMoveKeepsSolids() throws {
        let grid = TileGrid.solid(SIMD4(1, 1, 1, 1), covering: PixelRect(x: 0, y: 0, width: 512, height: 256))
        let moved = try TileOperations.translate(grid, by: SIMD2(256, 0), context: try context())
        #expect(Set(moved.tiles.keys) == [TileCoord(1, 0), TileCoord(2, 0)])
        let partly = try TileOperations.translate(grid, by: SIMD2(10, 0), context: try context())
        if case .solid = partly[TileCoord(1, 0)]! {} else { Issue.record("fully covered tile should stay solid") }
        if case .texture = partly[TileCoord(0, 0)]! {} else { Issue.record("partial tile should be a texture") }
    }
}

@Suite struct ExportTests {
    @Test(arguments: ExportOptions.Format.allCases)
    func exportsReadableImage(format: ExportOptions.Format) throws {
        let state = DocumentState(width: 300, height: 200, layers: [solidLayer(SIMD4(1, 0, 0, 1), size: 300)])
        let flat = try ImageExporter.flatten(state, context: try context())
        #expect(flat.width == 300 && flat.height == 200)

        let data = try ImageExporter.encode(flat, options: ExportOptions(format: format, bitDepth: .sixteen))
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(image.width == 300 && image.height == 200)
        #expect(image.bitsPerComponent == (format.supports16Bit ? 16 : 8))

        // Read back one pixel as 8-bit sRGB.
        let ctx = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(image, in: CGRect(x: -10, y: -10, width: 300, height: 200))
        let px = ctx.data!.assumingMemoryBound(to: UInt8.self)
        #expect(px[0] > 245 && px[1] < 12 && px[2] < 12)
    }

    @Test func flattensOverMatteWithoutAlpha() throws {
        let state = DocumentState(width: 64, height: 64, layers: [])  // fully transparent
        let flat = try ImageExporter.flatten(state, context: try context())
        let jpeg = try ImageExporter.convert(flat, options: ExportOptions(format: .jpeg))
        let ctx = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(jpeg, in: CGRect(x: 0, y: 0, width: 64, height: 64))
        let px = ctx.data!.assumingMemoryBound(to: UInt8.self)
        #expect(px[0] == 255 && px[1] == 255 && px[2] == 255)
    }
}

@Suite struct CanvasRendererTests {
    @Test func drawsCheckerTilesAndPasteboard() throws {
        let ctx = try context()
        let renderer = try CanvasRenderer(context: ctx)
        let compositor = try DocumentCompositor(context: ctx)
        let width = 64

        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: CanvasRenderer.pixelFormat,
                                                         width: width, height: width, mipmapped: false)
        d.usage = [.renderTarget, .shaderRead]
        d.storageMode = .shared
        let target = try #require(ctx.device.makeTexture(descriptor: d))

        // 32×32 document; left half covered by an opaque blue layer.
        var grid = TileGrid()
        grid[TileCoord(0, 0)] = .solid(SIMD4(0, 0, 1, 1))
        let state = DocumentState(width: 32, height: 32, layers: [Layer(name: "b", content: .raster(grid))])
        let frame = CanvasFrame(transform: ViewTransform(), viewSize: SIMD2(64, 64), backingScale: 1,
                                documentSize: state.size, pasteboardColor: SIMD4(0.1, 0.2, 0.3, 1), checkerSize: 4)
        let cb = try #require(ctx.commandQueue.makeCommandBuffer())
        compositor.update(state, coords: [TileCoord(0, 0)], commandBuffer: cb)
        renderer.encode(frame, tiles: [TileCoord(0, 0)], tile: compositor.texture(at:), into: cb, target: target)
        cb.commit(); cb.waitUntilCompleted()

        var px = [Float16](repeating: 0, count: width * width * 4)
        px.withUnsafeMutableBytes {
            target.getBytes($0.baseAddress!, bytesPerRow: width * 8, from: MTLRegionMake2D(0, 0, width, width), mipmapLevel: 0)
        }
        func at(_ x: Int, _ y: Int) -> SIMD4<Float> {
            let i = (y * width + x) * 4
            return SIMD4(Float(px[i]), Float(px[i + 1]), Float(px[i + 2]), Float(px[i + 3]))
        }
        #expect(abs(at(10, 10).z - 1) < 0.002 && at(10, 10).x < 0.002)  // layer
        #expect(abs(at(50, 50).x - 0.1) < 0.002)                         // pasteboard (outside doc)
    }

    @Test func linearization() {
        #expect(LinearColor.linearize(0) == 0)
        #expect(abs(LinearColor.linearize(1) - 1) < 1e-12)
        #expect(abs(LinearColor.linearize(0.5) - 0.214) < 0.001)
    }
}

@Suite(.serialized) struct PerformanceTests {
    /// 8k × 8k, 20 layers: full composite must stay well under budget.
    @Test func compositesLargeDocument() throws {
        let ctx = try context()
        let size = 8192
        let bounds = PixelRect(x: 0, y: 0, width: size, height: size)
        let tiles = (0..<4).map { textureTile(SIMD4(Float($0) * 0.1, 0.2, 0.3, 0.5)) }
        var layers: [Layer] = []
        for i in 0..<20 {
            var grid = TileGrid()
            for (n, c) in bounds.tileCoords.enumerated() { grid[c] = tiles[(n + i) % 4] }
            layers.append(Layer(name: "L\(i)", blendMode: BlendMode.pixelModes[i % 18], content: .raster(grid)))
        }
        let state = DocumentState(width: size, height: size, layers: layers)
        let compositor = try DocumentCompositor(context: ctx)
        let coords = bounds.tileCoords

        let clock = ContinuousClock()
        let elapsed = try clock.measure {
            let cb = try #require(ctx.commandQueue.makeCommandBuffer())
            compositor.update(state, coords: coords, commandBuffer: cb)
            cb.commit(); cb.waitUntilCompleted()
        }
        print("Composited 8k × 8k × 20 layers (\(coords.count) tiles) in \(elapsed)")
        #expect(elapsed < .seconds(3))

        // A second pass with no changes only computes signatures.
        let idle = try clock.measure {
            let cb = try #require(ctx.commandQueue.makeCommandBuffer())
            compositor.update(state, coords: coords, commandBuffer: cb)
            cb.commit(); cb.waitUntilCompleted()
        }
        print("Unchanged re-check took \(idle)")
        #expect(idle < .milliseconds(100))
    }
}

@Suite struct SelectionOutlineTests {
    @Test(arguments: [1.0, 0.29])
    func antsAppearOnTheSelectionEdge(zoom: Double) throws {
        let ctx = try context()
        let renderer = try CanvasRenderer(context: ctx)
        let width = 128
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: CanvasRenderer.pixelFormat,
                                                         width: width, height: width, mipmapped: false)
        d.usage = [.renderTarget, .shaderRead]
        d.storageMode = .shared
        let target = try #require(ctx.device.makeTexture(descriptor: d))
        let k = 1 / zoom
        let selection = Selection.rectangle(CGRectLike(x0: 20 * k, y0: 20 * k, x1: 80 * k, y1: 80 * k))
        let frame = CanvasFrame(transform: ViewTransform(scale: zoom), viewSize: SIMD2(128, 128), backingScale: 1,
                                documentSize: SIMD2(128 * k, 128 * k), pasteboardColor: SIMD4(0.1, 0.2, 0.3, 1), checkerSize: 4)
        let cb = try #require(ctx.commandQueue.makeCommandBuffer())
        renderer.encode(frame, tiles: PixelRect(x: 0, y: 0, width: Int(128 * k), height: Int(128 * k)).tileCoords,
                        tile: { _ in nil }, selection: selection, time: 312_345.678,
                        into: cb, target: target)
        cb.commit(); cb.waitUntilCompleted()
        var px = [Float16](repeating: 0, count: width * width * 4)
        px.withUnsafeMutableBytes {
            target.getBytes($0.baseAddress!, bytesPerRow: width * 8, from: MTLRegionMake2D(0, 0, width, width), mipmapLevel: 0)
        }
        // Along the left edge (x = 20) some pixels are pure black or white ants.
        var antPixels = 0
        for y in 22..<78 {
            for x in 18...21 {
                let i = (y * width + x) * 4
                let r = Float(px[i]), g = Float(px[i + 1])
                if (r < 0.05 && g < 0.05) || (r > 0.95 && g > 0.95 && Float(px[i + 2]) > 0.95 && (x + y) % 2 == 0) { antPixels += 1 }
            }
        }
        #expect(antPixels > 20, "found \(antPixels) ant pixels")
    }
}

@Suite struct SelectionOutlineAppFrameTests {
    @Test func antsVisibleInAZoomedOutRetinaFrame() throws {
        let ctx = try context()
        let renderer = try CanvasRenderer(context: ctx)
        let compositor = try DocumentCompositor(context: ctx)
        let state = DocumentState(width: 3840, height: 2160, layers: [solidLayer(SIMD4(0.5, 0.4, 0.3, 1), size: 3840)])
        let viewSize = SIMD2(500.0, 300.0), bs = 2.0
        let transform = ViewTransform.fitting(documentSize: state.size, in: viewSize)
        let w = Int(viewSize.x * bs), h = Int(viewSize.y * bs)
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: CanvasRenderer.pixelFormat, width: w, height: h, mipmapped: false)
        d.usage = [.renderTarget, .shaderRead]
        d.storageMode = .shared
        let target = try #require(ctx.device.makeTexture(descriptor: d))
        let rect = CGRectLike(x0: 1500.3, y0: 1000.7, x1: 2200.2, y1: 1400.9)
        let selection = Selection.rectangle(rect)
        let coords = state.bounds.tileCoords
        let frame = CanvasFrame(transform: transform, viewSize: viewSize, backingScale: bs, documentSize: state.size,
                                pasteboardColor: SIMD4(0.1, 0.2, 0.3, 1))
        let cb = try #require(ctx.commandQueue.makeCommandBuffer())
        compositor.update(state, coords: coords, commandBuffer: cb)
        renderer.encode(frame, tiles: coords, tile: compositor.texture(at:), selection: selection, time: 1234.5,
                        into: cb, target: target)
        cb.commit(); cb.waitUntilCompleted()
        var px = [Float16](repeating: 0, count: w * h * 4)
        px.withUnsafeMutableBytes {
            target.getBytes($0.baseAddress!, bytesPerRow: w * 8, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
        }
        // Left edge of the selection in device pixels.
        let edge = transform.viewPoint(fromDocument: SIMD2(rect.minX, (rect.minY + rect.maxY) / 2)) * bs
        var extremes = 0
        for y in Int(edge.y) - 40..<Int(edge.y) + 40 {
            for x in Int(edge.x) - 3...Int(edge.x) + 3 {
                let r = Float(px[(y * w + x) * 4])
                if r < 0.1 || r > 0.9 { extremes += 1 }
            }
        }
        #expect(extremes > 20, "found \(extremes) ant pixels near x=\(edge.x)")
    }
}
