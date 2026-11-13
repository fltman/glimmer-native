import Testing
@testable import GlimmerCore

@Suite struct SelectionTests {
    @Test func rectangleIsExactWithAntialiasedEdges() {
        let s = Selection.rectangle(CGRectLike(x0: 10, y0: 10, x1: 20.5, y1: 20))
        let v = s.values(in: PixelRect(x: 0, y: 0, width: 30, height: 30))
        #expect(v[15 * 30 + 15] == 1)
        #expect(v[15 * 30 + 20] == 0.5)
        #expect(v[5 * 30 + 5] == 0)
        #expect(s.bounds(in: PixelRect(x: 0, y: 0, width: 100, height: 100)) == PixelRect(x: 10, y: 10, width: 11, height: 10))
    }

    @Test func ellipse() {
        let s = Selection.ellipse(in: CGRectLike(x0: 0, y0: 0, x1: 100, y1: 50))
        let v = s.values(in: PixelRect(x: 0, y: 0, width: 100, height: 50))
        #expect(v[25 * 100 + 50] == 1)
        #expect(v[0] == 0)
    }

    @Test func combineAndInvert() {
        let a = Selection.rectangle(CGRectLike(x0: 0, y0: 0, x1: 300, y1: 10))
        let b = Selection.rectangle(CGRectLike(x0: 100, y0: 0, x1: 400, y1: 10))
        let r = PixelRect(x: 0, y: 0, width: 400, height: 10)
        func at(_ s: Selection, _ x: Int) -> Float { s.values(in: r)[5 * 400 + x] }
        let add = a.combined(with: b, .add), sub = a.combined(with: b, .subtract), both = a.combined(with: b, .intersect)
        #expect(at(add, 50) == 1 && at(add, 350) == 1)
        #expect(at(sub, 50) == 1 && at(sub, 150) == 0)
        #expect(at(both, 50) == 0 && at(both, 150) == 1)
        let inv = a.inverted()
        #expect(at(inv, 50) == 0 && at(inv, 350) == 1)
        #expect(inv.bounds(in: r) == r)
        #expect(Selection().bounds(in: r) == nil)
    }
}
