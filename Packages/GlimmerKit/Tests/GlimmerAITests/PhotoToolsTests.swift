import CoreGraphics
import CoreImage
import CoreText
import Foundation
@testable import GlimmerAI
import Testing

@Suite struct PhotoToolsTests {
    /// A textured, photo-like scene with fine detail.
    static func detailed(width: Int = 1200, height: Int = 800) -> CGImage {
        var px = [UInt8](repeating: 255, count: width * height * 4)
        var seed: UInt32 = 11
        for y in 0..<height {
            for x in 0..<width {
                seed = seed &* 1_664_525 &+ 1_013_904_223
                let i = (y * width + x) * 4
                let stripe = ((x / 6 + y / 9) % 2) * 90
                px[i] = UInt8(min(255, 60 + stripe + Int(seed >> 27)))
                px[i + 1] = UInt8(min(255, 80 + stripe / 2 + Int((seed >> 22) & 31)))
                px[i + 2] = UInt8(min(255, 100 + (x * 100 / width) + Int((seed >> 17) & 31)))
            }
        }
        let ctx = CGContext(data: &px, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return ctx.makeImage()!
    }

    static func blurred(_ image: CGImage, radius: Double) -> CGImage {
        let ci = CIImage(cgImage: image)
        let out = ci.clampedToExtent().applyingFilter("CIGaussianBlur", parameters: ["inputRadius": radius]).cropped(to: ci.extent)
        return CIContext().createCGImage(out, from: ci.extent)!
    }

    @Test func sharpBeatsBlurred() {
        let sharp = Self.detailed()
        let soft = Self.blurred(sharp, radius: 8)
        let a = PhotoQuality.sharpness(sharp), b = PhotoQuality.sharpness(soft)
        #expect(a > PhotoQuality.blurThreshold)
        #expect(b < PhotoQuality.blurThreshold)
        #expect(a > b)
    }

    @Test func flatGraphicsAreNeverBlurry() {
        let ctx = CGContext(data: nil, width: 400, height: 300, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(red: 0.2, green: 0.4, blue: 0.9, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: 400, height: 300))
        ctx.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
        ctx.fillEllipse(in: CGRect(x: 100, y: 50, width: 200, height: 200))
        let graphic = ctx.makeImage()!
        #expect(PhotoQuality.colorVariety(graphic) < PhotoQuality.photoColorVariety)
        #expect(!PhotoQuality.rate(graphic).isBlurry)
        #expect(PhotoQuality.colorVariety(Self.detailed()) >= PhotoQuality.photoColorVariety)
    }

    @Test func blurryPhotosRankLower() {
        let sharp = PhotoQuality.Rating(aesthetics: 0.3, isUtility: false, sharpness: 0.9)
        let soft = PhotoQuality.Rating(aesthetics: 0.3, isUtility: false, sharpness: 0.2)
        #expect(soft.isBlurry && !sharp.isBlurry)
        #expect(sharp.score > soft.score)
        #expect(sharp.stars >= soft.stars)
        #expect((1...5).contains(PhotoQuality.Rating(aesthetics: -1, isUtility: false, sharpness: 0).stars))
        #expect(PhotoQuality.Rating(aesthetics: 1, isUtility: false, sharpness: 1).stars == 5)
    }

    /// A sheet of paper with lines of text, seen at an angle, on a darker desk.
    static func paperInPerspective() -> (CGImage, DocumentDetection.Quad) {
        let w = 1200, h = 900
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(red: 0.35, green: 0.25, blue: 0.18, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        // y-down corners of the sheet.
        let quad = DocumentDetection.Quad(topLeft: CGPoint(x: 330, y: 140), topRight: CGPoint(x: 900, y: 190),
                                          bottomRight: CGPoint(x: 960, y: 800), bottomLeft: CGPoint(x: 240, y: 760))
        func up(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x, y: Double(h) - p.y) }
        ctx.setFillColor(red: 0.97, green: 0.97, blue: 0.95, alpha: 1)
        ctx.move(to: up(quad.topLeft))
        for p in [quad.topRight, quad.bottomRight, quad.bottomLeft] { ctx.addLine(to: up(p)) }
        ctx.closePath()
        ctx.fillPath()
        ctx.setFillColor(gray: 0.15, alpha: 1)
        for row in 0..<10 {
            let t = (Double(row) + 1.5) / 12
            let a = CGPoint(x: quad.topLeft.x + (quad.bottomLeft.x - quad.topLeft.x) * t + 60,
                            y: quad.topLeft.y + (quad.bottomLeft.y - quad.topLeft.y) * t)
            ctx.fill(CGRect(x: a.x, y: Double(h) - a.y - 10, width: 380, height: 12))
        }
        return (ctx.makeImage()!, quad)
    }

    @Test func findsAndFlattensADocument() throws {
        let (image, truth) = Self.paperInPerspective()
        let quad = try #require(DocumentDetection.quad(in: image))
        for (a, b) in zip(quad.corners, truth.corners) {
            #expect(hypot(a.x - b.x, a.y - b.y) < 40, "corner \(a) vs \(b)")
        }
        let flat = try #require(DocumentDetection.corrected(image, quad: quad))
        let size = quad.outputSize
        // Core Image allows for foreshortening, so the result is at least as big as the edges, not exactly them.
        #expect(Double(flat.width) > size.width * 0.8 && Double(flat.width) < size.width * 1.5)
        #expect(Double(flat.height) > size.height * 0.8 && Double(flat.height) < size.height * 1.5)
        #expect(flat.height > flat.width)  // a portrait sheet
    }

    @Test func noDocumentInAScene() {
        #expect(DocumentDetection.quad(in: Self.detailed()) == nil)
    }
}

@Suite struct SkySelectionTests {
    /// Depth for a landscape: the sky (top half) far away, the ground coming nearer toward the bottom.
    static func depth(width: Int, height: Int) -> GrayImage {
        var v = [Float](repeating: 0, count: width * height)
        for y in 0..<height { for x in 0..<width { v[y * width + x] = y < height / 2 ? 5 : 60 + Float(y) / Float(height) * 190 } }
        return GrayImage(width: width, height: height, values: v)
    }

    @Test func promptsSitInTheSkyAndBelowIt() throws {
        let image = SmartAnalysisTests.landscape(tilt: 0)  // sky above y = 300 of 600
        let points = try #require(SkySelection.prompts(image: image, depth: Self.depth(width: 800, height: 600)))
        #expect(points.count <= MagicSelector.maxPoints)
        let positives = points.filter(\.positive), negatives = points.filter { !$0.positive }
        #expect(positives.count >= 2)
        #expect(positives.allSatisfy { $0.location.y < 290 })
        #expect(!negatives.isEmpty && negatives.allSatisfy { $0.location.y > 310 })
    }

    @Test func noSkyWhenTheTopIsDarkForeground() {
        // Bright ground below a dark, near top: nothing to seed from.
        let image = SmartAnalysisTests.landscape(tilt: 0, sky: (0.1, 0.1, 0.1), ground: (0.9, 0.9, 0.8))
        var near = Self.depth(width: 800, height: 600)
        near.values = near.values.map { _ in 220 }
        #expect(SkySelection.prompts(image: image, depth: near) == nil)
    }

    @Test func magicSelectKeepsTheLatestPoints() {
        let points = (0..<20).map { MagicSelector.Point(SIMD2(Double($0), 0), positive: true) }
        let usable = MagicSelector.usable(points)
        #expect(usable.count == MagicSelector.maxPoints)
        #expect(usable.last?.location.x == 19)
    }
}
