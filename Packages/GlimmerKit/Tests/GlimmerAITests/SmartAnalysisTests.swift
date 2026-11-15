import CoreGraphics
import Foundation
@testable import GlimmerAI
import GlimmerCore
import Testing

@Suite struct SmartAnalysisTests {
    /// A landscape: sky over ground, the horizon tilted by `degrees` (positive =
    /// rising to the right), with a little texture so it looks like a photo.
    static func landscape(width: Int = 800, height: Int = 600, tilt degrees: Double,
                          sky: (Double, Double, Double) = (0.45, 0.65, 0.95),
                          ground: (Double, Double, Double) = (0.3, 0.45, 0.2), gain: Double = 1) -> CGImage {
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        // CG is y-up: fill ground, then the sky polygon above the tilted line.
        ctx.setFillColor(red: ground.0 * gain, green: ground.1 * gain, blue: ground.2 * gain, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let t = tan(degrees * .pi / 180), mid = Double(height) * 0.5, W = Double(width)
        ctx.setFillColor(red: sky.0 * gain, green: sky.1 * gain, blue: sky.2 * gain, alpha: 1)
        ctx.move(to: CGPoint(x: 0, y: mid - t * W / 2))
        ctx.addLine(to: CGPoint(x: W, y: mid + t * W / 2))
        ctx.addLine(to: CGPoint(x: W, y: Double(height)))
        ctx.addLine(to: CGPoint(x: 0, y: Double(height)))
        ctx.fillPath()
        var seed: UInt32 = 7
        for _ in 0..<4000 {
            seed = seed &* 1_664_525 &+ 1_013_904_223
            let x = Double(seed % UInt32(width)); seed = seed &* 1_664_525 &+ 1_013_904_223
            let y = Double(seed % UInt32(height))
            ctx.setFillColor(gray: Double(seed % 100) / 100, alpha: 0.15)
            ctx.fill(CGRect(x: x, y: y, width: 2, height: 2))
        }
        return ctx.makeImage()!
    }

    @Test func darkFlatPhotoGetsANoticeableEnhancement() {
        let image = Self.landscape(tilt: 0, gain: 0.35)
        let recipe = SmartAnalysis.enhanceRecipe(for: image)
        #expect(recipe.isNoticeable)
        // Lifts the image: the curve's midpoint rises.
        #expect(CurveMath.evaluate(recipe.curve, at: 0.3) > 0.3)
        #expect(!recipe.adjustments.isEmpty)
        #expect(recipe.adjustments.allSatisfy { [.curves, .vibrance, .colorBalance].contains($0.kind) })
    }

    @Test func toneStatsSeeADarkImage() {
        let stats = SmartAnalysis.toneStats(Self.landscape(tilt: 0, gain: 0.3))
        #expect(stats.isDark)
        #expect(stats.high < 0.5)
    }

    @Test func foldingShadowsKeepsTheCurveMonotoneAndPinned() {
        let curve = [CurvePoint(0, 0), CurvePoint(0.25, 0.25), CurvePoint(0.5, 0.5), CurvePoint(0.75, 0.75), CurvePoint(1, 1)]
        let folded = SmartAnalysis.folded(curve, shadows: 1, highlights: 0.5)
        #expect(folded.first!.y == 0 && folded.last!.y == 1)
        #expect(folded[1].y > 0.25)       // shadows lifted
        #expect(folded[3].y < 0.75)       // highlights eased
        #expect(zip(folded, folded.dropFirst()).allSatisfy { $0.y <= $1.y })
    }

    @Test func horizonTiltIsReportedWithItsSign() throws {
        let rising = SmartAnalysis.insights(of: Self.landscape(tilt: 4)).horizonDegrees
        let falling = SmartAnalysis.insights(of: Self.landscape(tilt: -4)).horizonDegrees
        let level = SmartAnalysis.insights(of: Self.landscape(tilt: 0)).horizonDegrees
        #expect(level == nil)
        let r = try #require(rising), f = try #require(falling)
        #expect(abs(r - 4) < 1.5)
        #expect(abs(f + 4) < 1.5)
    }

    @Test func tiltOutsideTheUsableRangeIsIgnored() {
        #expect(SmartAnalysis.usableTilt(0.1) == nil)
        #expect(SmartAnalysis.usableTilt(35) == nil)
        #expect(SmartAnalysis.usableTilt(-3) == -3)
    }

    @Test func cropForANewAspectSlidesOverTheSubject() throws {
        // Subject on the right of a 4:3 image; ask for a square.
        let subject = CGRect(x: 0.7, y: 0.4, width: 0.15, height: 0.2)
        let crop = try #require(SmartAnalysis.suggestedCrop(salient: subject, imageWidth: 800, imageHeight: 600, aspect: 1))
        #expect(crop.width == 600 && crop.height == 600)
        #expect(crop.maxX <= 800 && crop.minX >= 0)
        #expect(crop.minX > 100)  // moved toward the subject
        #expect(crop.contains(CGPoint(x: 0.775 * 800, y: 0.5 * 600)))
    }

    @Test func freeCropTightensAroundASmallSubject() throws {
        let subject = CGRect(x: 0.4, y: 0.4, width: 0.1, height: 0.1)
        let crop = try #require(SmartAnalysis.suggestedCrop(salient: subject, imageWidth: 1000, imageHeight: 500, aspect: nil))
        #expect(abs(crop.width / crop.height - 2) < 0.02)  // keeps the image's proportions
        #expect(crop.width < 1000)
        #expect(crop.contains(CGPoint(x: 450, y: 225)))
    }

    @Test func aSubjectFillingTheFrameNeedsNoCrop() {
        let subject = CGRect(x: 0.05, y: 0.05, width: 0.9, height: 0.9)
        #expect(SmartAnalysis.suggestedCrop(salient: subject, imageWidth: 800, imageHeight: 600, aspect: nil) == nil)
    }

    @Test func portraitCropFramesHeadAndShoulders() throws {
        // A face upper-left in a 4000 × 3000 landscape.
        let face = CGRect(x: 0.2, y: 0.2, width: 0.08, height: 0.1)
        let crop = try #require(SmartAnalysis.suggestedCrop(salient: .zero, imageWidth: 4000, imageHeight: 3000,
                                                           aspect: 4.0 / 5, faces: [face]))
        #expect(abs(crop.width / crop.height - 0.8) < 0.01)
        let faceBox = CGRect(x: 800, y: 600, width: 320, height: 300)
        #expect(crop.contains(faceBox))
        // Eyes around the upper third, not centred.
        let rel = (faceBox.midY - crop.minY) / crop.height
        #expect(rel > 0.3 && rel < 0.45)
        #expect(crop.width < 4000 * 0.5)  // tight, not the whole frame
    }

    @Test func portraitCropKeepsAGroupTogether() throws {
        let faces = [CGRect(x: 0.2, y: 0.3, width: 0.06, height: 0.08), CGRect(x: 0.6, y: 0.32, width: 0.06, height: 0.08)]
        let crop = try #require(SmartAnalysis.suggestedCrop(salient: .zero, imageWidth: 3000, imageHeight: 2000,
                                                           aspect: 16.0 / 9, faces: faces))
        #expect(crop.minX < 0.2 * 3000 && crop.maxX > 0.66 * 3000)
        #expect(crop.minX >= 0 && crop.maxX <= 3000 && crop.minY >= 0 && crop.maxY <= 2000)
    }
}
