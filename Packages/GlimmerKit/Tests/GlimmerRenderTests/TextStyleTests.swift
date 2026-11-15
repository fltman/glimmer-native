import CoreGraphics
import CoreText
import Foundation
@testable import GlimmerCore
@testable import GlimmerRender
import Testing

/// Single words styled differently within one text layer.
@Suite struct TextStyleTests {
    static let red = SRGBColor(1, 0, 0)
    static func text(_ s: String = "Hello brave world") -> TextLayer {
        TextLayer(string: s, fontName: "HelveticaNeue", size: 40, color: .black, origin: SIMD2(10, 10))
    }

    @Test func styleARangeAndReadItBack() {
        var t = Self.text()
        t.setStyle(in: NSRange(location: 6, length: 5), fontName: "HelveticaNeue-Bold", color: Self.red)
        #expect(t.styles == [TextStyleRun(location: 6, length: 5, fontName: "HelveticaNeue-Bold", color: Self.red)])
        #expect(t.style(at: 0) == t.baseStyle)
        #expect(t.style(at: 8) == TextStyle(fontName: "HelveticaNeue-Bold", size: 40, color: Self.red))
        let runs = t.resolvedRuns()
        #expect(runs.map(\.range) == [NSRange(location: 0, length: 6), NSRange(location: 6, length: 5), NSRange(location: 11, length: 6)])
    }

    @Test func overlappingChangesSplitAndMergeRuns() {
        var t = Self.text()
        t.setStyle(in: NSRange(location: 0, length: 11), color: Self.red)
        t.setStyle(in: NSRange(location: 6, length: 5), size: 60)
        #expect(t.styles == [TextStyleRun(location: 0, length: 6, color: Self.red),
                             TextStyleRun(location: 6, length: 5, size: 60, color: Self.red)])
        // Setting the layer's own values again removes the runs.
        t.setStyle(in: NSRange(location: 0, length: 17), size: 40, color: .black)
        #expect(t.styles == nil && !t.hasStyledRuns)
    }

    @Test func aWholeLayerChangeWinsOverWords() {
        var t = Self.text()
        t.setStyle(in: NSRange(location: 6, length: 5), size: 60, color: Self.red)
        let old = t
        t.color = SRGBColor(0, 0, 1)
        t.dropStyles(changedFrom: old)
        #expect(t.styles == [TextStyleRun(location: 6, length: 5, size: 60)], "the colour applies everywhere, the size stays")
    }

    @Test func editingTheTextKeepsStylesOnTheirWords() {
        var t = Self.text()
        t.setStyle(in: NSRange(location: 6, length: 5), color: Self.red)  // "brave"
        let old = t.string
        t.string = "Oh, hello brave world!"
        t.carryStyles(from: old)
        let ns = t.string as NSString
        let red = t.resolvedRuns().filter { $0.style.color == Self.red }.map { ns.substring(with: $0.range) }
        #expect(red == ["brave"], "\(red)")
    }

    @Test func theEditorsRunsAreStoredAsDifferences() {
        var t = Self.text()
        let base = t.baseStyle
        var bold = base
        bold.fontName = "HelveticaNeue-Bold"
        t.setStyledText("One two", runs: [(NSRange(location: 0, length: 4), base), (NSRange(location: 4, length: 3), bold)])
        #expect(t.string == "One two")
        #expect(t.styles == [TextStyleRun(location: 4, length: 3, fontName: "HelveticaNeue-Bold")])
    }

    @Test func olderFilesWithoutStylesStillOpen() throws {
        let t = Self.text()
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(t)) as! [String: Any]
        json["styles"] = nil
        let decoded = try JSONDecoder().decode(TextLayer.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(decoded == t && decoded.styles == nil)
        var styled = t
        styled.setStyle(in: NSRange(location: 0, length: 5), size: 80)
        #expect(try JSONDecoder().decode(TextLayer.self, from: JSONEncoder().encode(styled)) == styled)
    }

    @Test func aBiggerWordMakesItsLineTallerAndTheTextWider() {
        var t = Self.text()
        let plain = t.layoutSize
        t.setStyle(in: NSRange(location: 6, length: 5), size: 80)
        let big = t.layoutSize
        #expect(big.height > plain.height + 30)
        #expect(big.width > plain.width + 40)
    }

    @Test func eachWordIsDrawnInItsColour() throws {
        var t = TextLayer(string: "AAAA BBBB", fontName: "HelveticaNeue-Bold", size: 60, color: .black, origin: SIMD2(0, 0))
        t.setStyle(in: NSRange(location: 5, length: 4), color: Self.red)
        func colours(_ t: TextLayer) throws -> (left: Int, right: Int) {
            let image = try #require(t.render())
            let w = image.width, h = image.height
            var px = [UInt8](repeating: 0, count: w * h * 4)
            let ctx = try #require(CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                             space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            var redLeft = 0, redRight = 0
            for y in 0..<h {
                for x in 0..<w {
                    let i = (y * w + x) * 4
                    guard px[i + 3] > 200, px[i] > 200, px[i + 1] < 60 else { continue }
                    if x < w / 2 { redLeft += 1 } else { redRight += 1 }
                }
            }
            return (redLeft, redRight)
        }
        let flat = try colours(t)
        #expect(flat.left == 0 && flat.right > 200, "only the second word is red")
        // The same through the warp, which fills outlines itself.
        t.warp = TextWarp(style: .arc, bend: 0.3)
        let warped = try colours(t)
        #expect(warped.left == 0 && warped.right > 200)
    }

    @Test func attributedStringCarriesTheRuns() {
        var t = Self.text()
        t.setStyle(in: NSRange(location: 6, length: 5), size: 60)
        let s = t.attributedString()
        let font = s.attribute(NSAttributedString.Key(kCTFontAttributeName as String), at: 7, effectiveRange: nil) as! CTFont
        #expect(CTFontGetSize(font) == 60)
        let first = s.attribute(NSAttributedString.Key(kCTFontAttributeName as String), at: 0, effectiveRange: nil) as! CTFont
        #expect(CTFontGetSize(first) == 40)
    }
}
