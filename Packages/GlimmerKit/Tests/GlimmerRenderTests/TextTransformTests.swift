import CoreGraphics
import Foundation
@testable import GlimmerCore
@testable import GlimmerRender
import Testing

/// Free Transform keeps text editable: the transform rides on the text layer.
@Suite struct TextTransformTests {
    static func text() -> TextLayer { TextLayer(string: "Glimmer", size: 40, color: .black, origin: SIMD2(100, 100)) }

    @Test func aQuarterTurnSwapsTheBounds() throws {
        var t = Self.text()
        let plain = t.bounds
        let c = SIMD2(Double(plain.x) + Double(plain.width) / 2, Double(plain.y) + Double(plain.height) / 2)
        // Rotate 90° about the text's centre.
        t.transform = GlimmerCore.AffineTransform(tx: c.x, ty: c.y)
            .concatenating(GlimmerCore.AffineTransform(a: 0, b: 1, c: -1, d: 0))
            .concatenating(GlimmerCore.AffineTransform(tx: -c.x, ty: -c.y))
        let turned = t.bounds
        #expect(abs(turned.width - plain.height) <= 2 && abs(turned.height - plain.width) <= 2)
        let image = try #require(t.render())
        #expect(image.width == turned.width && image.height == turned.height)
        #expect(t.layoutBounds == plain, "the layout itself is unchanged, so the text stays editable")
    }

    @Test func movingATransformedTextMovesItsTransform() throws {
        var t = Self.text()
        t.transform = GlimmerCore.AffineTransform(a: 2, d: 2)  // scaled ×2 about the origin
        let before = t.bounds
        let layer = Layer(name: "T", content: .text(t))
        let context = try #require(MetalContext.shared)
        let moved = try TileOperations.translate(layer, by: SIMD2(30, -10), context: context)
        guard case .text(let m) = moved.content else { Issue.record("not text"); return }
        #expect(m.origin == t.origin, "the layout stays put")
        #expect(m.bounds.x == before.x + 30 && m.bounds.y == before.y - 10)
    }

    @Test func theTransformIsSaved() throws {
        var t = Self.text()
        t.transform = GlimmerCore.AffineTransform(a: 0.9, b: 0.3, c: -0.3, d: 0.9, tx: 12, ty: -4)
        let back = try JSONDecoder().decode(TextLayer.self, from: JSONEncoder().encode(t))
        #expect(back == t)
        // Documents saved before the property existed still open.
        var old = try JSONSerialization.jsonObject(with: JSONEncoder().encode(Self.text())) as! [String: Any]
        old.removeValue(forKey: "transform")
        let decoded = try JSONDecoder().decode(TextLayer.self, from: JSONSerialization.data(withJSONObject: old))
        #expect(decoded.transform == nil)
    }
}
