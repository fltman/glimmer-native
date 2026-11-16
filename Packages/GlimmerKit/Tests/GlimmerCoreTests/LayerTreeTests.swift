import CoreGraphics
import Foundation
import Testing
import simd
@testable import GlimmerCore

private func raster(_ name: String) -> Layer {
    Layer(name: name, content: .raster(TileGrid()))
}

@Suite struct LayerTreeTests {
    /// root: [A, G[B, C], D]
    private func sample() -> (DocumentState, a: UUID, g: UUID, b: UUID, c: UUID, d: UUID) {
        let a = raster("A"), b = raster("B"), c = raster("C"), d = raster("D")
        let g = Layer(name: "G", blendMode: .passThrough, content: .group(LayerGroup(children: [b, c])))
        return (DocumentState(width: 10, height: 10, layers: [a, g, d]), a.id, g.id, b.id, c.id, d.id)
    }

    @Test func pathsAndLookup() {
        let (s, a, g, b, c, _) = sample()
        #expect(s.path(of: a) == [0])
        #expect(s.path(of: c) == [1, 1])
        #expect(s.layer(id: b)?.name == "B")
        #expect(s.allLayers.count == 5)
        #expect(s.layer(id: g)?.children.count == 2)
    }

    @Test func insertAndDeleteInsideGroups() {
        var (s, _, _, b, _, _) = sample()
        s.activeLayerID = b
        let e = raster("E")
        s.insertLayerAboveActive(e)
        #expect(s.path(of: e.id) == [1, 1])
        s.deleteActiveLayer()
        #expect(s.path(of: e.id) == nil)
        #expect(s.activeLayerID == b)
    }

    @Test func groupAndUngroup() {
        var (s, a, _, _, _, _) = sample()
        s.activeLayerID = a
        let newGroup = s.groupActiveLayer(name: "Group 1")
        #expect(s.layer(id: newGroup)?.children.map(\.id) == [a])
        #expect(s.path(of: a) == [0, 0])
        s.ungroupActiveLayer()
        #expect(s.path(of: a) == [0])
        #expect(s.layer(id: newGroup) == nil)
    }

    @Test func moveAcrossGroups() {
        var (s, a, g, b, _, d) = sample()
        s.moveLayer(d, above: b)
        #expect(s.path(of: d) == [1, 1])
        s.moveLayer(a, intoTopOf: g)
        #expect(s.layer(id: g)?.children.last?.id == a)
        s.moveLayer(b, above: nil)
        #expect(s.path(of: b) == [0])
        // A group can't be moved into itself.
        s.moveLayer(g, intoTopOf: g)
        #expect(s.path(of: g) != nil)
    }

    @Test func duplicateGroupGetsFreshIDs() {
        var (s, _, g, b, _, _) = sample()
        s.activeLayerID = g
        let copy = s.duplicateActiveLayer()
        #expect(copy?.name == "G copy")
        let ids = Set(s.allLayers.map(\.id))
        #expect(ids.count == s.allLayers.count)
        #expect(copy?.children.contains { $0.id == b } == false)
    }

    @Test func clipBase() {
        var clipped = raster("clip")
        clipped.isClipped = true
        var clipped2 = raster("clip2")
        clipped2.isClipped = true
        let base = raster("base")
        let s = DocumentState(width: 1, height: 1, layers: [base, clipped, clipped2])
        #expect(s.clipBase(for: [2])?.id == base.id)
    }
}

@Suite struct AdjustmentModelTests {
    @Test func monotoneCurve() {
        #expect(CurveMath.evaluate(CurveMath.identity, at: 0.3) == 0.3)
        let pts = [CurvePoint(0, 0), CurvePoint(0.25, 0.5), CurvePoint(0.75, 0.6), CurvePoint(1, 1)]
        var last = -1.0
        for i in 0...100 {
            let v = CurveMath.evaluate(pts, at: Double(i) / 100)
            #expect(v >= last - 1e-12, "not monotone at \(i)")
            last = v
        }
        #expect(abs(CurveMath.evaluate(pts, at: 0.25) - 0.5) < 1e-9)
    }

    @Test func defaultsComeFromTheSchema() {
        let bw = Adjustment(.blackWhite)
        #expect(bw.number("red") == 0.4)
        #expect(Adjustment(.colorBalance).flag("preserveLuminosity"))
        #expect(Adjustment(.channelMixer).number("gg") == 1)
        #expect(Adjustment(.channelMixer).number("gr") == 0)
    }

    @Test func lenientDecoding() throws {
        let json = #"{"kind": "exposure", "numbers": {"exposure": 1.5}}"#
        let a = try JSONDecoder().decode(Adjustment.self, from: Data(json.utf8))
        #expect(a.number("exposure") == 1.5)
        #expect(a.number("gamma") == 1)
        #expect(a.gradient == GradientStop.blackToWhite)
    }

    @Test func shaderParameterCounts() {
        for kind in AdjustmentKind.allCases {
            #expect(Adjustment(kind).shaderParameters.count <= 28, "\(kind)")
        }
    }
}

@Suite struct LayerTreePackageTests {
    @Test func roundTripsEveryLayerKind() throws {
        var adj = Adjustment(.curves)
        adj.curves[.red] = [CurvePoint(0, 0.1), CurvePoint(1, 0.9)]
        var masked = Layer(name: "masked", isClipped: true, content: .raster(TileGrid()))
        var mask = LayerMask.hideAll
        mask.tiles[TileCoord(0, 0)] = gradientTile()
        mask.density = 0.7
        mask.feather = 3
        masked.mask = mask
        var effects = LayerEffects()
        effects.dropShadow = ShadowEffect()
        effects.stroke = StrokeEffect()
        masked.effects = effects

        var source = TileGrid()
        source[TileCoord(0, 0)] = gradientTile(seed: 0.2)
        let smart = Layer(name: "smart", content: .smart(SmartObject(
            source: source, width: 200, height: 100,
            transform: .make(x: 5, y: 6, scaleX: 1.5, scaleY: 1, rotation: 0.3, sourceSize: SIMD2(200, 100)))))
        let fill = Layer(name: "fill", content: .fill(.gradient(GradientFill(start: SIMD2(0, 0), end: SIMD2(10, 20)))))
        let group = Layer(name: "group", blendMode: .passThrough,
                          content: .group(LayerGroup(children: [masked, smart], isExpanded: false)))
        let state = DocumentState(width: 300, height: 200, layers: [
            Layer(name: "adj", opacity: 0.5, blendMode: .overlay, content: .adjustment(adj)), group, fill,
        ])

        let read = try GlimmerPackage.state(from: GlimmerPackage.fileWrapper(for: state))
        #expect(read.allLayers.map(\.id) == state.allLayers.map(\.id))
        guard case .adjustment(let a) = read.layers[0].content else { Issue.record("adjustment"); return }
        #expect(a == adj)
        #expect(read.layers[0].blendMode == .overlay)
        guard case .group(let g) = read.layers[1].content else { Issue.record("group"); return }
        #expect(!g.isExpanded && read.layers[1].blendMode == .passThrough)
        let m = g.children[0]
        #expect(m.isClipped && m.effects == effects)
        #expect(m.mask?.defaultValue == 0 && m.mask?.density == 0.7 && m.mask?.feather == 3)
        #expect(m.mask?.tiles[TileCoord(0, 0)]?.pixels() == mask.tiles[TileCoord(0, 0)]?.pixels())
        guard case .smart(let sm) = g.children[1].content, case .smart(let orig) = smart.content else {
            Issue.record("smart"); return
        }
        #expect(sm.transform == orig.transform && sm.width == 200)
        #expect(sm.source[TileCoord(0, 0)]?.pixels() == source[TileCoord(0, 0)]?.pixels())
        guard case .fill(let f) = read.layers[2].content, case .fill(let of) = fill.content else { Issue.record("fill"); return }
        #expect(f == of)
    }
}

@Suite struct TextAndPathTests {
    @Test func textLayoutAndRender() {
        let t = TextLayer(string: "Hello\nGlimmer", size: 40, origin: SIMD2(10, 20))
        let b = t.bounds
        #expect(b.x == 10 && b.y == 20 && b.width > 80 && b.height > 80)
        let image = t.render()
        #expect(image?.width == b.width)
    }

    @Test func pathFlatteningAndCGPath() {
        var p = VectorPath(name: "p")
        p.subpaths = [Subpath(anchors: [PathAnchor(SIMD2(0, 0)), PathAnchor(SIMD2(100, 0), handleIn: SIMD2(100, 50)),
                                        PathAnchor(SIMD2(100, 100))], isClosed: true)]
        let poly = p.polygons(steps: 10)[0]
        #expect(poly.first == SIMD2(0, 0))
        #expect(poly.count == 1 + 10 + 1 + 1)  // curve segment sampled, straight ones not
        #expect(!p.cgPath.isEmpty)
    }

    @Test func affineDecomposeRoundTrips() {
        let size = SIMD2(200.0, 100.0)
        let t = AffineTransform.make(x: 30, y: 40, scaleX: 1.5, scaleY: 0.5, rotation: 0.4, sourceSize: size)
        let d = t.decompose(sourceSize: size)
        #expect(abs(d.x - 30) < 1e-9 && abs(d.y - 40) < 1e-9 && abs(d.scaleX - 1.5) < 1e-9 && abs(d.scaleY - 0.5) < 1e-9)
        #expect(abs(d.rotation - 0.4) < 1e-9)
    }

    @Test func textAndPathsRoundTrip() throws {
        var state = DocumentState(width: 100, height: 100, layers: [
            Layer(name: "t", content: .text(TextLayer(string: "x", origin: SIMD2(1, 2)))),
        ])
        state.paths = [VectorPath(name: "Path 1", subpaths: [Subpath(anchors: [PathAnchor(SIMD2(1, 1))])])]
        state.aids.guides = [Guide(axis: .vertical, position: 50)]
        state.aids.grid.isVisible = true
        let read = try GlimmerPackage.state(from: GlimmerPackage.fileWrapper(for: state))
        guard case .text(let t) = read.layers[0].content else { Issue.record("text"); return }
        #expect(t.string == "x")
        #expect(read.paths == state.paths && read.aids == state.aids)
    }
}

@Suite struct ProjectiveTransformTests {
    let size = SIMD2(200.0, 100.0)
    let quad = [SIMD2(10.0, 20.0), SIMD2(250.0, 0.0), SIMD2(230.0, 180.0), SIMD2(30.0, 140.0)]

    @Test func quadMapsTheSourceCorners() {
        let t = GlimmerCore.AffineTransform.quad(sourceSize: size, to: quad)
        let src = [SIMD2(0.0, 0.0), SIMD2(size.x, 0), size, SIMD2(0, size.y)]
        for (s, q) in zip(src, quad) { #expect(simd_distance(t.apply(s), q) < 1e-6) }
        #expect(!t.isAffine)
        let back = t.inverse.apply(quad[2])
        #expect(simd_distance(back, size) < 1e-6)
    }

    @Test func parallelogramStaysAffine() {
        let p = [SIMD2(0.0, 0.0), SIMD2(200.0, 0.0), SIMD2(250.0, 100.0), SIMD2(50.0, 100.0)]
        #expect(GlimmerCore.AffineTransform.quad(sourceSize: size, to: p).isAffine)
    }

    @Test func codableIsBackwardCompatible() throws {
        let old = #"{"a":2,"b":0,"c":0,"d":2,"tx":5,"ty":6}"#
        let t = try JSONDecoder().decode(GlimmerCore.AffineTransform.self, from: Data(old.utf8))
        #expect(t.isAffine && t.apply(SIMD2(1, 1)) == SIMD2(7, 8))
        let p = GlimmerCore.AffineTransform.quad(sourceSize: size, to: quad)
        let back = try JSONDecoder().decode(GlimmerCore.AffineTransform.self, from: JSONEncoder().encode(p))
        #expect(back == p)
    }
}

@Suite struct TextOnPathTests {
    @Test func textFollowsTheLine() throws {
        // A diagonal path: the rendered ink must lie near the diagonal, not in a horizontal band.
        var t = TextLayer(string: "GLIMMER ALONG A PATH", size: 30, origin: SIMD2(0, 0))
        t.onPath = [SIMD2(50, 50), SIMD2(450, 450)]
        let b = t.bounds
        #expect(b.x < 50 && b.maxX > 450)
        let image = try #require(t.render())
        let w = image.width, h = image.height
        var px = [UInt8](repeating: 0, count: w * h * 4)
        let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        var near = 0, far = 0
        for y in 0..<h { for x in 0..<w where px[(y * w + x) * 4 + 3] > 128 {
            // Context memory is top-down; document y = b.y + y.
            let dx = Double(b.x + x), dy = Double(b.y + y)
            abs(dx - dy) / 2.0.squareRoot() < 40 ? (near += 1) : (far += 1)
        } }
        #expect(near > 500)
        #expect(far < near / 20, "near \(near) far \(far)")
    }
}

@Suite struct SmartFilterStorageTests {
    @Test func smartFiltersRoundTrip() throws {
        var smart = SmartObject(source: TileGrid(), width: 10, height: 10, transform: .identity)
        smart.filters = [SmartFilter(FilterSettings(.gaussianBlur, ["radius": 6]))]
        smart.filters[0].isEnabled = false
        let state = DocumentState(width: 10, height: 10, layers: [Layer(name: "s", content: .smart(smart))])
        let read = try GlimmerPackage.state(from: GlimmerPackage.fileWrapper(for: state))
        guard case .smart(let s) = read.layers[0].content else { Issue.record("smart"); return }
        #expect(s.filters == smart.filters)
    }
}

@Suite struct VectorShapeTests {
    @Test func shapesAndTransforms() throws {
        let r = CGRectLike(x0: 10, y0: 20, x1: 110, y1: 70)
        let e = VectorPath.ellipse(r)
        let b = try #require(e.controlBounds)
        #expect(abs(b.minX - 10) < 1e-9 && abs(b.maxY - 70) < 1e-9)
        let scaled = e.applying(GlimmerCore.AffineTransform(a: 2, d: 2))
        #expect(abs(try #require(scaled.controlBounds).maxX - 220) < 1e-9)
        let sel = VectorPath.roundedRectangle(r, radius: 10).asSelection
        let inside = sel.values(in: PixelRect(x: 60, y: 45, width: 1, height: 1))[0]
        let corner = sel.values(in: PixelRect(x: 10, y: 20, width: 1, height: 1))[0]
        #expect(inside > 0.99 && corner < 0.1)
    }

    @Test func vectorMaskRoundTrips() throws {
        let path = VectorPath.ellipse(CGRectLike(x0: 0, y0: 0, x1: 50, y1: 40))
        let state = DocumentState(width: 64, height: 64, layers: [
            Layer(name: "shape", mask: path.asSelection.asMask, vectorMask: path, content: .fill(.solid(.black))),
        ])
        let read = try GlimmerPackage.state(from: GlimmerPackage.fileWrapper(for: state))
        #expect(read.layers[0].vectorMask == path)
    }
}

@Suite struct TextWarpTests {
    /// Column-wise ink centre (document y) for an image rendered at `bounds`.
    private func inkCentres(_ t: TextLayer) throws -> [Int: Double] {
        let b = t.bounds
        let image = try #require(t.render())
        let w = image.width, h = image.height
        var px = [UInt8](repeating: 0, count: w * h * 4)
        let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        var result: [Int: Double] = [:]
        for x in 0..<w {
            var sum = 0.0, n = 0.0
            for y in 0..<h where px[(y * w + x) * 4 + 3] > 128 { sum += Double(y); n += 1 }
            if n > 0 { result[b.x + x] = Double(b.y) + sum / n }
        }
        return result
    }

    @Test func formulasMatchTheWebApp() {
        let arch = TextWarp(style: .arch, bend: 1)
        #expect(arch.displacement(u: 0.5, v: 0.3) == SIMD2(0, 0.5))
        #expect(arch.displacement(u: 0, v: 0.3).y == 0)
        let arc = TextWarp(style: .arc, bend: 1)
        #expect(arc.displacement(u: 0.5, v: 1).y == 0)
        #expect(abs(TextWarp(style: .rise, bend: 0.4).displacement(u: 1, v: 0).y - 0.2) < 1e-12)
        let skew = TextWarp(style: .wave, bend: 0, horizontal: 1)
        #expect(skew.displacement(u: 0.3, v: 0).x == -0.3)
        #expect(!TextWarp(style: .arc, bend: 0).isActive && !TextWarp(style: .none, bend: 1).isActive)
    }

    @Test func archBendsTheBaseline() throws {
        var t = TextLayer(string: "WARPED TEXT", size: 60, origin: SIMD2(100, 100))
        let flat = try inkCentres(t)
        let flatBounds = t.bounds
        t.warp = TextWarp(style: .arch, bend: 0.6)
        let b = t.bounds
        #expect(b.height > flatBounds.height + 30 && b.y < flatBounds.y)
        let bent = try inkCentres(t)
        // Average vertical shift of the ink against the flat text, near the ends and in the middle.
        let xs = flat.keys.filter { bent[$0] != nil }.sorted()
        func shift(_ f: Double) -> Double {
            let lo = Int(Double(xs.count) * (f - 0.05)), hi = Int(Double(xs.count) * (f + 0.05))
            let window = xs[max(lo, 0)..<min(hi, xs.count)]
            return window.map { bent[$0]! - flat[$0]! }.reduce(0, +) / Double(window.count)
        }
        let left = shift(0.1), mid = shift(0.5), right = shift(0.9)
        // A positive arch pushes the middle down (web semantics) much more than the ends.
        #expect(mid > 12 && mid > left + 8 && mid > right + 8, "left \(left) mid \(mid) right \(right)")
    }

    @Test func warpRoundTripsAndOldFilesStillDecode() throws {
        var t = TextLayer(string: "A", origin: .zero)
        t.warp = TextWarp(style: .flag, bend: -0.25, vertical: 0.5)
        let data = try JSONEncoder().encode(t)
        #expect(try JSONDecoder().decode(TextLayer.self, from: data) == t)
        var legacy = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        legacy.removeValue(forKey: "warp")
        let old = try JSONDecoder().decode(TextLayer.self, from: JSONSerialization.data(withJSONObject: legacy))
        #expect(old.warp == nil)
    }

    @Test func aipsTextWarpImports() {
        let t = AipsImporter.textLayer(["text": "Hi", "fontSize": 40,
                                        "warp": ["style": "wave", "bend": 0.4, "horizontal": 0, "vertical": 0.1]],
                                       origin: SIMD2(0, 0))
        #expect(t.warp == TextWarp(style: .wave, bend: 0.4, vertical: 0.1))
        #expect(AipsImporter.textLayer(["text": "Hi", "warp": ["style": "none", "bend": 0]], origin: .zero).warp == nil)
    }
}

@Suite struct HistogramTests {
    @Test func countsVisiblePixelsPerChannel() {
        // Two opaque pixels and one fully transparent one.
        let h = Histogram(rgba: [255, 0, 0, 255, 0, 0, 255, 255, 9, 9, 9, 0])
        #expect(h.red[255] == 1 && h.red[0] == 1 && h.red[9] == 0)
        #expect(h.blue[255] == 1 && h.green[0] == 2)
        #expect(h.luminance[54] == 1 && h.luminance[18] == 1)
        #expect(h.bins(.rgb) == h.luminance && h.bins(.green) == h.green)
    }

    @Test func imageHistogramUnpremultiplies() throws {
        let ctx = try #require(CGContext(data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 0,
                                         space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.5))
        ctx.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        let image = try #require(ctx.makeImage())
        let h = try #require(Histogram(image: image))
        #expect(h.red[255] + h.red[254] == 16)
    }

    @Test func belowHidesTheLayerAndEverythingAbove() {
        let a = Layer(name: "A", content: .raster(TileGrid()))
        let b = Layer(name: "B", content: .raster(TileGrid()))
        let c = Layer(name: "C", content: .raster(TileGrid()))
        let group = Layer(name: "G", content: .group(LayerGroup(children: [b, c])))
        let d = Layer(name: "D", content: .raster(TileGrid()))
        let state = DocumentState(width: 10, height: 10, layers: [a, group, d])
        let below = state.below(c.id)
        #expect(below.layer(id: a.id)?.isVisible == true && below.layer(id: group.id)?.isVisible == true)
        #expect(below.layer(id: b.id)?.isVisible == true)
        #expect(below.layer(id: c.id)?.isVisible == false && below.layer(id: d.id)?.isVisible == false)
    }
}

@Suite struct TileAccountingTests {
    @Test func countsTextureTilesOnly() {
        let texture = Tile.texture(TileTexture((try! TileTexture.makeTexture())))
        var grid = TileGrid.solid(SIMD4(1, 0, 0, 1), covering: PixelRect(x: 0, y: 0, width: 512, height: 256))
        grid[TileCoord(0, 0)] = texture
        var masked = Layer(name: "m", content: .raster(TileGrid()))
        masked.mask = LayerMask(tiles: TileGrid([TileCoord(3, 3): .texture(TileTexture((try! TileTexture.makeTexture())))]))
        let state = DocumentState(width: 512, height: 256, layers: [Layer(name: "a", content: .raster(grid)), masked])
        #expect(state.textureTileIDs.count == 2)
    }
}

@Suite struct GraphicsMemoryTests {
    @Test func aShortageIsToldOnceAndSaysWhatToDo() {
        _ = GraphicsMemory.takeShortage()
        #expect(!GraphicsMemory.takeShortage())
        GraphicsMemory.noteShortage(); GraphicsMemory.noteShortage()
        #expect(GraphicsMemory.takeShortage())
        #expect(!GraphicsMemory.takeShortage())
        #expect(GraphicsMemoryError().errorDescription?.contains("merge some layers") == true)
    }
}
