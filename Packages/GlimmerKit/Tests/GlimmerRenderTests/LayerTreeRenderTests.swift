import Foundation
import GlimmerCore
import Metal
import Testing
import simd
@testable import GlimmerRender

private func srgbEncode(_ c: Float) -> Float {
    c <= 0.0031308 ? c * 12.92 : 1.055 * pow(c, 1 / 2.4) - 0.055
}

private func srgbDecode(_ c: Float) -> Float {
    c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
}

private func gray(_ v: Float, size: Int = 512) -> Layer {
    solidLayer(SIMD4(v, v, v, 1), size: size)
}

private func doc(_ layers: [Layer], size: Int = 512) -> DocumentState {
    DocumentState(width: size, height: size, layers: layers)
}

private func close(_ a: SIMD4<Float>, _ b: SIMD4<Float>, _ tol: Float = 0.004) -> Bool {
    simd_length(a - b) < tol
}

@Suite struct AdjustmentRenderTests {
    @Test func invertMatchesWebFormula() throws {
        var adj = Adjustment(.invert)
        adj.numbers = [:]
        let state = doc([gray(0.5), Layer(name: "inv", content: .adjustment(adj))])
        let got = try renderPixel(state, x: 10, y: 10)
        let want = srgbDecode(1 - srgbEncode(0.5))
        #expect(abs(got.x - want) < 0.003 && abs(got.w - 1) < 0.001)
    }

    @Test func blendModeAndOpacityAreHonoured() throws {
        // Invert, blended with Multiply (the web app ignored adjustment blend modes).
        let inverted = srgbDecode(1 - srgbEncode(0.5))
        let multiply = doc([gray(0.5), Layer(name: "inv", blendMode: .multiply, content: .adjustment(Adjustment(.invert)))])
        #expect(abs(try renderPixel(multiply, x: 0, y: 0).x - 0.5 * inverted) < 0.003)

        let half = doc([gray(0.5), Layer(name: "inv", opacity: 0.5, content: .adjustment(Adjustment(.invert)))])
        #expect(abs(try renderPixel(half, x: 0, y: 0).x - (0.5 + inverted) / 2) < 0.003)
    }

    /// Found with a file written by Photoshop (2026-11-16): a mask at 90 % along the edge of an
    /// Invert layer. In a document that blends in gamma, opacity and masks mix encoded values.
    @Test func opacityMixesInTheDocumentsBlendSpace() throws {
        var state = doc([gray(0.02), Layer(name: "inv", opacity: 0.5, content: .adjustment(Adjustment(.invert)))])
        state.blendSpace = .gamma
        let b = srgbEncode(0.02)
        #expect(abs(try renderPixel(state, x: 0, y: 0).x - srgbDecode((b + (1 - b)) / 2)) < 0.003)
        // In linear light, as before: halfway between the two linear values (a much lighter grey).
        state.blendSpace = .linear
        #expect(abs(try renderPixel(state, x: 0, y: 0).x - (0.02 + srgbDecode(1 - b)) / 2) < 0.003)
    }

    @Test func maskLimitsTheAdjustment() throws {
        var mask = LayerMask.revealAll
        mask.tiles[TileCoord(0, 0)] = .solid(SIMD4(repeating: 0))  // hide in the first tile
        let state = doc([gray(0.5), Layer(name: "inv", mask: mask, content: .adjustment(Adjustment(.invert)))])
        #expect(abs(try renderPixel(state, x: 10, y: 10).x - 0.5) < 0.002)   // masked out
        #expect(try renderPixel(state, x: 300, y: 10).x < 0.1)               // inverted
    }

    @Test func identityCurvesAndLevelsChangeNothing() throws {
        for kind in [AdjustmentKind.curves, .levels, .brightnessContrast, .hueSaturation, .exposure] {
            let state = doc([solidLayer(SIMD4(0.3, 0.1, 0.6, 1), size: 512), Layer(name: "a", content: .adjustment(Adjustment(kind)))])
            #expect(close(try renderPixel(state, x: 5, y: 5), SIMD4(0.3, 0.1, 0.6, 1)), "\(kind)")
        }
    }

    @Test func curvesBrighten() throws {
        var adj = Adjustment(.curves)
        adj.curves[.rgb] = [CurvePoint(0, 0), CurvePoint(0.5, 0.75), CurvePoint(1, 1)]
        let state = doc([gray(srgbDecode(0.5)), Layer(name: "c", content: .adjustment(adj))])
        let got = try renderPixel(state, x: 0, y: 0)
        #expect(abs(srgbEncode(got.x) - 0.75) < 0.01)
    }

    @Test func gradientMapUsesLuminance() throws {
        var adj = Adjustment(.gradientMap)
        adj.gradient = [GradientStop(0, SRGBColor(1, 0, 0)), GradientStop(1, SRGBColor(0, 0, 1))]
        let state = doc([gray(1), Layer(name: "g", content: .adjustment(adj))])
        let got = try renderPixel(state, x: 0, y: 0)
        #expect(got.z > 0.99 && got.x < 0.01)
    }
}

@Suite struct GroupRenderTests {
    private let red = SIMD4<Float>(0.8, 0.2, 0.2, 1)

    @Test func isolatedGroupHidesChildBlendModes() throws {
        let child = solidLayer(red, size: 512, mode: .multiply)
        let group = Layer(name: "g", blendMode: .normal, content: .group(LayerGroup(children: [child])))
        // Multiply over the group's transparent backdrop is the child itself.
        #expect(close(try renderPixel(doc([gray(0.5), group]), x: 1, y: 1), red))
    }

    @Test func passThroughGroupBlendsWithBackdrop() throws {
        let child = solidLayer(red, size: 512, mode: .multiply)
        let group = Layer(name: "g", blendMode: .passThrough, content: .group(LayerGroup(children: [child])))
        #expect(close(try renderPixel(doc([gray(0.5), group]), x: 1, y: 1), SIMD4(0.4, 0.1, 0.1, 1)))

        var half = group
        half.opacity = 0.5
        #expect(close(try renderPixel(doc([gray(0.5), half]), x: 1, y: 1), SIMD4(0.45, 0.3, 0.3, 1)))
    }

    @Test func groupOpacityAndVisibility() throws {
        let group = Layer(name: "g", opacity: 0.5, blendMode: .normal,
                          content: .group(LayerGroup(children: [solidLayer(SIMD4(1, 1, 1, 1), size: 512)])))
        #expect(close(try renderPixel(doc([gray(0), group]), x: 1, y: 1), SIMD4(0.5, 0.5, 0.5, 1)))
        var hidden = group
        hidden.isVisible = false
        #expect(close(try renderPixel(doc([gray(0), hidden]), x: 1, y: 1), SIMD4(0, 0, 0, 1)))
    }

    @Test func nestedGroups() throws {
        let inner = Layer(name: "in", blendMode: .normal, content: .group(LayerGroup(children: [solidLayer(red, size: 512)])))
        let outer = Layer(name: "out", opacity: 0.5, blendMode: .normal, content: .group(LayerGroup(children: [inner])))
        #expect(close(try renderPixel(doc([gray(0), outer]), x: 300, y: 300), SIMD4(0.4, 0.1, 0.1, 1)))
    }
}

@Suite struct ClippingRenderTests {
    /// Base covers only the first tile; two clipped layers cover everything.
    private func clippedDoc(secondOpacity: Double = 1) -> DocumentState {
        var baseGrid = TileGrid()
        baseGrid[TileCoord(0, 0)] = .solid(SIMD4(0, 0, 1, 1))
        var first = solidLayer(SIMD4(0, 1, 0, 1), size: 512)
        first.isClipped = true
        first.opacity = 0  // fully transparent: must not become the base of the next one
        var second = solidLayer(SIMD4(1, 0, 0, 1), size: 512, opacity: secondOpacity)
        second.isClipped = true
        return doc([gray(0), Layer(name: "base", content: .raster(baseGrid)), first, second])
    }

    @Test func clippedLayersClipToTheChainBase() throws {
        let state = clippedDoc()
        #expect(close(try renderPixel(state, x: 10, y: 10), SIMD4(1, 0, 0, 1)))   // inside base
        #expect(close(try renderPixel(state, x: 300, y: 10), SIMD4(0, 0, 0, 1)))  // outside base
    }

    @Test func hiddenBaseHidesTheChain() throws {
        var state = clippedDoc()
        state.layers[1].isVisible = false
        #expect(close(try renderPixel(state, x: 10, y: 10), SIMD4(0, 0, 0, 1)))
    }
}

@Suite struct MaskRenderTests {
    @Test func hideAllAndDensity() throws {
        var layer = solidLayer(SIMD4(1, 1, 1, 1), size: 512)
        layer.mask = .hideAll
        #expect(close(try renderPixel(doc([gray(0), layer]), x: 1, y: 1), SIMD4(0, 0, 0, 1)))
        layer.mask?.density = 0.5
        #expect(close(try renderPixel(doc([gray(0), layer]), x: 1, y: 1), SIMD4(0.5, 0.5, 0.5, 1)))
        layer.mask?.isEnabled = false
        #expect(close(try renderPixel(doc([gray(0), layer]), x: 1, y: 1), SIMD4(1, 1, 1, 1)))
    }

    @Test func featherSoftensTileEdges() throws {
        var layer = solidLayer(SIMD4(1, 1, 1, 1), size: 512)
        var mask = LayerMask.revealAll
        mask.tiles[TileCoord(0, 0)] = .solid(SIMD4(repeating: 0))
        mask.feather = 8
        layer.mask = mask
        let state = doc([gray(0), layer])
        let edge = try renderPixel(state, x: 256, y: 100).x
        #expect(edge > 0.3 && edge < 0.7, "edge \(edge)")
        #expect(try renderPixel(state, x: 200, y: 100).x < 0.01)
        #expect(try renderPixel(state, x: 320, y: 100).x > 0.99)
    }

    @Test func movingALayerMovesItsMask() throws {
        var layer = solidLayer(SIMD4(1, 1, 1, 1), size: 512)
        var mask = LayerMask.hideAll
        mask.tiles[TileCoord(0, 0)] = .solid(SIMD4(repeating: 1))  // reveal only tile 0
        layer.mask = mask
        let moved = try TileOperations.translate(layer, by: SIMD2(256, 0), context: try context())
        let state = doc([gray(0), moved], size: 1024)
        #expect(try renderPixel(state, x: 300, y: 10).x > 0.99)
        #expect(try renderPixel(state, x: 10, y: 10).x < 0.01)
    }
}

@Suite struct FillAndSmartRenderTests {
    @Test func solidAndPatternFills() throws {
        let fill = Layer(name: "f", content: .fill(.solid(SRGBColor(1, 0, 0))))
        #expect(close(try renderPixel(doc([fill]), x: 400, y: 400), SIMD4(1, 0, 0, 1)))

        let pattern = Layer(name: "p", content: .fill(.pattern(PatternFill(kind: .checkerboard, scale: 10,
                                                                             foreground: .black, background: .white))))
        let a = try renderPixel(doc([pattern]), x: 5, y: 5)
        let b = try renderPixel(doc([pattern]), x: 15, y: 5)
        #expect(a.x != b.x)
    }

    @Test func linearGradientFill() throws {
        let g = GradientFill(start: SIMD2(0, 0), end: SIMD2(256, 0))
        let state = doc([Layer(name: "g", content: .fill(.gradient(g)))])
        // Interpolated in sRGB (like Photoshop): halfway is sRGB 0.5.
        let mid = try renderPixel(state, x: 128, y: 0)
        #expect(abs(srgbEncode(mid.x) - 0.5) < 0.01)
        #expect(try renderPixel(state, x: 400, y: 0).x > 0.99)
    }

    @Test func smartObjectTransform() throws {
        var source = TileGrid()
        source[TileCoord(0, 0)] = textureTile(SIMD4(0, 1, 0, 1))
        let smart = SmartObject(source: source, width: 256, height: 256,
                                transform: .make(x: 100, y: 100, scaleX: 0.5, scaleY: 0.5, rotation: 0,
                                                 sourceSize: SIMD2(256, 256)))
        let state = doc([Layer(name: "s", content: .smart(smart))])
        #expect(try renderPixel(state, x: 160, y: 160).y > 0.95)
        #expect(try renderPixel(state, x: 90, y: 90).w < 0.01)
        #expect(try renderPixel(state, x: 240, y: 240).w < 0.01)
    }

    @Test func affineMakeMatchesWebSmartTransform() {
        let t = AffineTransform.make(x: 10, y: 20, scaleX: 2, scaleY: 1, rotation: .pi / 2, sourceSize: SIMD2(100, 50))
        // Box 200×50 at (10,20); centre (110, 45). Rotating 90° CW maps the source origin to the top-right.
        let o = t.apply(SIMD2(0, 0))
        #expect(abs(o.x - 135) < 1e-9 && abs(o.y - (-55)) < 1e-9)
        let back = t.inverse.apply(o)
        #expect(abs(back.x) < 1e-9 && abs(back.y) < 1e-9)
    }
}

@Suite struct LayerStyleRenderTests {
    /// A 100×100 opaque square at (100, 100) on a white background.
    private func squareLayer(_ effects: LayerEffects) throws -> DocumentState {
        let square = Layer(name: "sq", effects: effects, content: .raster(try squareGrid()))
        return doc([gray(1), square])
    }

    private func squareGrid() throws -> TileGrid {
        let s = TileGeometry.size
        var px = [Float16](repeating: 0, count: s * s * 4)
        for y in 100..<200 {
            for x in 100..<200 {
                let i = (y * s + x) * 4
                px[i] = 0; px[i + 1] = 0; px[i + 2] = 1; px[i + 3] = 1
            }
        }
        var grid = TileGrid()
        grid[TileCoord(0, 0)] = px.withUnsafeBytes { Tile.make(pixels: $0.baseAddress!, bytesPerRow: TileGeometry.bytesPerRow)! }
        return grid
    }

    @Test func dropShadowFallsBelowAndOffset() throws {
        var effects = LayerEffects()
        var shadow = ShadowEffect()
        shadow.angle = 135  // light from the top-left → shadow to the bottom-right
        shadow.distance = 20
        shadow.size = 0
        shadow.opacity = 1
        effects.dropShadow = shadow
        let state = try squareLayer(effects)
        // Bottom-right, outside the square but inside the shadow: dark.
        #expect(try renderPixel(state, x: 210, y: 210).x < 0.05)
        // Top-left outside the square: white.
        #expect(try renderPixel(state, x: 95, y: 95).x > 0.99)
        // The square itself stays blue on top.
        #expect(try renderPixel(state, x: 150, y: 150).z > 0.99)
    }

    @Test func outsideStroke() throws {
        var effects = LayerEffects()
        var stroke = StrokeEffect()
        stroke.width = 6
        stroke.color = SRGBColor(1, 0, 0)
        effects.stroke = stroke
        let state = try squareLayer(effects)
        let ring = try renderPixel(state, x: 203, y: 150)
        #expect(ring.x > 0.95 && ring.z < 0.05)
        #expect(try renderPixel(state, x: 215, y: 150).y > 0.99)  // beyond the stroke: white
        #expect(try renderPixel(state, x: 150, y: 150).z > 0.99)  // inside: blue
    }

    @Test func colorOverlayReplacesColour() throws {
        var effects = LayerEffects()
        var overlay = ColorOverlayEffect()
        overlay.color = SRGBColor(0, 1, 0)
        effects.colorOverlay = overlay
        let state = try squareLayer(effects)
        let px = try renderPixel(state, x: 150, y: 150)
        #expect(px.y > 0.99 && px.z < 0.01)
    }

    @Test func colorOverlayRecoloursFillAndShapeLayers() throws {
        var effects = LayerEffects()
        var overlay = ColorOverlayEffect()
        overlay.color = SRGBColor(0, 1, 0)
        effects.colorOverlay = overlay
        // A shape: a blue fill masked to a square.
        let r = CGRectLike(x0: 100, y0: 100, x1: 200, y1: 200)
        let shape = Layer(name: "shape", mask: Selection.rectangle(r).asMask, effects: effects, content: .fill(.solid(SRGBColor(0, 0, 1))))
        let state = doc([gray(1), shape])
        let inside = try renderPixel(state, x: 150, y: 150)
        #expect(inside.y > 0.99 && inside.z < 0.01, "the shape takes the overlay colour")
        #expect(try renderPixel(state, x: 50, y: 50).z > 0.99, "outside the shape nothing changes")
        // Half opacity mixes the two.
        var half = effects
        half.colorOverlay?.opacity = 0.5
        var soft = shape
        soft.effects = half
        let mixed = try renderPixel(doc([gray(1), soft]), x: 150, y: 150)
        #expect(mixed.y > 0.2 && mixed.z > 0.2 && mixed.x < 0.05)
    }
}
