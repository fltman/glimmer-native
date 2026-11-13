import Foundation
import Testing
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
