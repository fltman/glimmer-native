import CoreGraphics
import CoreText
import Foundation
@testable import GlimmerAI
import GlimmerCore
import Testing

/// Serialized: the text tests load the system's text-recognition model, and several loads at
/// once on a busy Mac fail ("e5rt … compute operation … call failed").
@Suite(.serialized) struct SmartToolsTests {
    /// Text recognition with patience: the system's model sometimes fails to load while the Mac is
    /// under load (other builds, a full test run). That says nothing about Glimmer, so try again.
    static func lines(in image: CGImage) throws -> [ImageText.Line] {
        var last: (any Error)?
        for attempt in 0..<4 {
            do { return try ImageText.lines(in: image) } catch { last = error }
            Thread.sleep(forTimeInterval: 2 + Double(attempt) * 3)
        }
        throw last!
    }

    /// A grey scene (several neutral tones) with an optional cast.
    static func greyScene(cast: SIMD3<Double> = .zero, width: Int = 300, height: Int = 200) -> CGImage {
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        for (i, g) in [0.25, 0.4, 0.55, 0.7, 0.85].enumerated() {
            let c = SIMD3(repeating: g) + cast
            ctx.setFillColor(red: c.x, green: c.y, blue: c.z, alpha: 1)
            ctx.fill(CGRect(x: i * width / 5, y: 0, width: width / 5 + 1, height: height))
        }
        // A saturated object that must not count as a cast.
        ctx.setFillColor(red: 0.9, green: 0.1, blue: 0.1, alpha: 1)
        ctx.fill(CGRect(x: 20, y: 20, width: 60, height: 60))
        return ctx.makeImage()!
    }

    @Test func neutralSceneHasNoCast() {
        let cast = SmartAnalysis.colorCast(Self.greyScene())
        #expect(!SmartAnalysis.isNoticeableCast(cast))
    }

    @Test func warmCastIsFoundAndCorrected() throws {
        let tint = SIMD3(0.06, 0.0, -0.06)
        let cast = try #require(SmartAnalysis.colorCast(Self.greyScene(cast: tint)))
        #expect(SmartAnalysis.isNoticeableCast(cast))
        #expect(cast.x > 0.03 && cast.z < -0.03)
        // The Color Balance shader adds value × 0.5 per tone weight (weights sum to 1).
        let a = SmartAnalysis.castCorrection(cast, strength: 1)
        let shift = SIMD3(a.numbers["midtonesR"]!, a.numbers["midtonesG"]!, a.numbers["midtonesB"]!) * 0.5
        let corrected = cast + shift
        #expect(max(abs(corrected.x), abs(corrected.y), abs(corrected.z)) < 0.005)
        #expect(a.flags["preserveLuminosity"] == true)
    }

    @Test func autoEnhanceIncludesAClearCast() {
        let recipe = SmartAnalysis.enhanceRecipe(for: Self.greyScene(cast: SIMD3(0.0, 0.0, 0.08)))
        #expect(recipe.correctsCast)
        #expect(recipe.adjustments.contains { $0.kind == .colorBalance })
    }

    static func textImage(_ text: String, light: Bool) -> CGImage {
        let w = 900, h = 220
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(gray: light ? 0.1 : 0.95, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        let font = CTFontCreateWithName("Helvetica-Bold" as CFString, 72, nil)
        let color = light ? CGColor(srgbRed: 1, green: 0.9, blue: 0.2, alpha: 1) : CGColor(gray: 0.05, alpha: 1)
        let attr = NSAttributedString(string: text, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
        ])
        ctx.textPosition = CGPoint(x: 60, y: 80)
        CTLineDraw(CTLineCreateWithAttributedString(attr), ctx)
        return ctx.makeImage()!
    }

    @Test func readsTextWithItsPositionAndColour() throws {
        let image = Self.textImage("Grand Opening", light: true)
        let lines = try Self.lines(in: image)
        let line = try #require(lines.first)
        #expect(line.string.localizedCaseInsensitiveContains("grand opening"))
        // CG drew the baseline at y = 80 from the bottom: the box sits around 220 − 80 − ~50 (y down).
        #expect(line.box.minX > 40 && line.box.minX < 90)
        #expect(line.box.midY > 90 && line.box.midY < 140)
        let color = ImageText.textColor(in: image, box: line.box)
        #expect(color.r > 0.7 && color.g > 0.6 && color.b < 0.5)  // yellow, not the dark background
        #expect(ImageText.plainText(lines).contains("Opening"))
    }

    @Test func textLayerCoversTheOriginalLine() throws {
        let image = Self.textImage("Grand Opening", light: true)
        let line = try #require(try Self.lines(in: image).first)
        let layer = ImageText.textLayer(for: line, in: image)
        guard case .text(let text) = layer.content else { Issue.record("not a text layer"); return }
        let size = text.layoutSize
        #expect(abs(size.width - line.box.width) < line.box.width * 0.15)
        #expect(abs((text.origin.y + size.height / 2) - line.box.midY) < 3)
        #expect(text.size > 40 && text.size < 110)  // drawn at 72 pt
        #expect(text.color.r > 0.7 && text.color.b < 0.5)
    }

    @Test func darkTextOnLightReadsDark() throws {
        let image = Self.textImage("Hello", light: false)
        let line = try #require(try Self.lines(in: image).first)
        let color = ImageText.textColor(in: image, box: line.box)
        #expect(color.r < 0.3)
    }

    @Test func noPeopleInALandscape() {
        #expect(throws: SegmentationError.self) {
            try SubjectSegmentation.peopleMask(of: Self.greyScene())
        }
    }

    @Test func genericFileNamesAreRecognised() {
        for name in ["IMG_1234", "DSC01234", "Screenshot 2026-11-15 at 10.00.00", "Pasted Image", "20261115_101010", "PXL_2026"] {
            #expect(ImageLabel.isGeneric(name), "\(name)")
        }
        for name in ["Logo", "Golden Gate", "mum's birthday"] {
            #expect(!ImageLabel.isGeneric(name), "\(name)")
        }
    }
}
