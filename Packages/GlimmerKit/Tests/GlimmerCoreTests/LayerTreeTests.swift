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
