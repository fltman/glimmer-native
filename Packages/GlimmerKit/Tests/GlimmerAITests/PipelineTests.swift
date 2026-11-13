import CoreGraphics
import Foundation
import GlimmerCore
import Testing
@testable import GlimmerAI

/// Returns a fixed image (optionally a function of the inputs) and records calls.
final class FakeModel: ImageModel, @unchecked Sendable {
    let lock = NSLock()
    var prompts: [String] = []
    var inputCounts: [Int] = []
    let make: @Sendable ([RGBAImage]) -> RGBAImage

    init(_ make: @escaping @Sendable ([RGBAImage]) -> RGBAImage) {
        self.make = make
    }

    func generate(prompt: String, images: [RGBAImage], seed: Int?) async throws -> AIImageResult {
        lock.withLock {
            prompts.append(prompt)
            inputCounts.append(images.count)
        }
        return AIImageResult(image: make(images), cost: 0.01)
    }
}

private func solid(_ w: Int, _ h: Int, _ c: SIMD4<Float>) -> RGBAImage { RGBAImage(width: w, height: h, fill: c) }

@Suite struct ImagingTests {
    @Test func colorMatchRecoversGainAndOffset() {
        // result = (ref − 10) / 1.2 everywhere; matching must undo it.
        var ref = RGBAImage(width: 20, height: 20, fill: .zero)
        var res = ref
        for i in 0..<400 {
            let v = Float(i % 200 + 20)
            for c in 0..<3 {
                ref.pixels[i * 4 + c] = v
                res.pixels[i * 4 + c] = ((v - 10) / 1.2).rounded()
            }
            ref.pixels[i * 4 + 3] = 255; res.pixels[i * 4 + 3] = 255
        }
        let matched = Imaging.colorMatch(res, to: ref, trusted: GrayImage(width: 20, height: 20, fill: 255))
        for i in [0, 57, 399] {
            #expect(abs(matched.pixels[i * 4] - ref.pixels[i * 4]) <= 1.5)
        }
    }

    @Test func colorMatchDegenerateUsesOffset() {
        let ref = solid(8, 8, SIMD4(100, 100, 100, 255))
        let res = solid(8, 8, SIMD4(80, 80, 80, 255))
        let m = Imaging.colorMatch(res, to: ref, trusted: GrayImage(width: 8, height: 8, fill: 255))
        #expect(m.pixels[0] == 100)
        // No trusted pixels → identity.
        let id = Imaging.colorMatch(res, to: ref, trusted: GrayImage(width: 8, height: 8, fill: 0))
        #expect(id.pixels[0] == 80)
    }

    @Test func featherErodesThenBlurs() {
        var m = GrayImage(width: 40, height: 1, fill: 0)
        for x in 10..<30 { m.values[x] = 255 }
        let f = Imaging.featherMask(m, erode: 2, blur: 1)
        #expect(f.values[20] > 250)       // centre stays
        #expect(f.values[10] < 20)        // eroded edge
        #expect(f.values[13] > f.values[11])
    }

    @Test func clampROIPads() {
        let r = Imaging.clampROI(PixelRect(x: 10, y: 10, width: 100, height: 50), width: 1000, height: 1000)
        #expect(r == PixelRect(x: -20, y: -5, width: 160, height: 80).intersection(PixelRect(x: 0, y: 0, width: 1000, height: 1000)))
    }

    @Test func labTransferMovesTowardReference() {
        var src = solid(4, 4, SIMD4(60, 60, 60, 255))
        src.pixels[0] = 120
        let ref = solid(4, 4, SIMD4(200, 120, 80, 255))
        let out = Imaging.labColorTransfer(src, reference: ref, strength: 1)
        #expect(out.pixels[4] > 150 && out.pixels[6] < 110)  // pixel 1 becomes warm
        let same = Imaging.labColorTransfer(ref, reference: ref)
        #expect(abs(same.pixels[0] - 200) < 1.5)
    }

    @Test func resizeAndRoundTrip() throws {
        let img = solid(10, 6, SIMD4(10, 200, 30, 255))
        let big = img.resized(width: 20, height: 12)
        #expect(big.width == 20 && big.height == 12)
        #expect(abs(big.pixels[0] - 10) <= 1 && abs(big.pixels[1] - 200) <= 1)
        let back = RGBAImage(try ImageImporter.image(from: img.pngData()))
        #expect(back == img)
    }
}

@Suite struct AIPipelineTests {
    @Test func inpaintLimitsTheResultToTheMask() async throws {
        let image = solid(200, 100, SIMD4(50, 100, 150, 255))
        var mask = GrayImage(width: 200, height: 100, fill: 0)
        for y in 40..<60 { for x in 90..<110 { mask.values[y * 200 + x] = 255 } }
        // The model returns red everywhere, slightly brighter than the source in the unmasked area.
        let model = FakeModel { inputs in solid(inputs[0].width * 2, inputs[0].height * 2, SIMD4(255, 0, 0, 255)) }
        let result = try await AIPipelines.inpaint(image: image, mask: mask,
                                                   selectionBounds: PixelRect(x: 90, y: 40, width: 20, height: 20),
                                                   mode: .fill, prompt: "a red ball", model: model)
        #expect(result.origin == SIMD2(84, 34))  // 30 % padding
        #expect(result.image.width == 32 && result.image.height == 32)
        let centre = (16 * 32 + 16) * 4
        #expect(result.image.pixels[centre + 3] > 250)  // inside the mask: visible
        #expect(result.image.pixels[3] < 3)             // corner: (almost) transparent
        #expect(model.prompts[0].contains("replace ONLY the white region with: a red ball."))
        #expect(model.inputCounts == [2])
    }

    @Test func removeAndReferencePrompts() async throws {
        let image = solid(50, 50, SIMD4(1, 2, 3, 255))
        let mask = GrayImage(width: 50, height: 50, fill: 255)
        let model = FakeModel { $0[0] }
        _ = try await AIPipelines.inpaint(image: image, mask: mask, selectionBounds: PixelRect(x: 0, y: 0, width: 50, height: 50),
                                          mode: .remove, prompt: "ignored", model: model)
        _ = try await AIPipelines.inpaint(image: image, mask: mask, selectionBounds: PixelRect(x: 0, y: 0, width: 50, height: 50),
                                          mode: .fill, prompt: "", reference: solid(8, 8, .zero), model: model)
        #expect(model.prompts[0].contains("REMOVE whatever object"))
        #expect(model.prompts[1].contains("THIRD image is a REFERENCE"))
        #expect(model.inputCounts == [2, 3])
    }

    @Test func expandKeepsTheOriginalInset() async throws {
        let image = solid(40, 30, SIMD4(10, 20, 30, 255))
        let model = FakeModel { inputs in solid(inputs[0].width, inputs[0].height, SIMD4(200, 200, 200, 255)) }
        let margins = AIPipelines.Margins(top: 5, right: 10, bottom: 5, left: 10)
        let result = try await AIPipelines.expand(image, margins: margins, prompt: "beach", model: model)
        #expect(result.image.width == 60 && result.image.height == 40)
        let inset = ((5 + 15) * 60 + 10 + 20) * 4
        #expect(result.image.pixels[inset] == 10 && result.image.pixels[inset + 2] == 30)
        #expect(result.image.pixels[0] > 100)  // painted border
        #expect(model.prompts[0].hasSuffix("The newly revealed area should depict: beach."))
    }

    @Test func editRealignsToSourceSize() async throws {
        let model = FakeModel { _ in solid(512, 512, SIMD4(0, 0, 0, 255)) }
        let result = try await AIPipelines.edit(solid(300, 200, .zero), instruction: "x", model: model)
        #expect(result.image.width == 300 && result.image.height == 200)
    }

    @Test func generatePrompt() async throws {
        let model = FakeModel { _ in solid(4, 4, .zero) }
        _ = try await AIPipelines.generate(prompt: "a cat", negative: "dogs", width: 1024, height: 768, model: model)
        #expect(model.prompts[0] == "a cat\n\nAvoid: dogs\n\nTarget dimensions: 1024x768 pixels.")
    }
}

@Suite struct ResponseParsingTests {
    let png = "data:image/png;base64," + RGBAImage(width: 2, height: 2, fill: SIMD4(1, 2, 3, 255)).pngData().base64EncodedString()

    @Test func imagesArray() {
        let json: [String: Any] = ["choices": [["message": ["content": "here", "images": [["image_url": ["url": png]]]]]],
                                   "usage": ["cost": 0.04]]
        #expect(OpenRouterClient.extractImage(from: json) != nil)
        #expect(OpenRouterClient.cost(json) == 0.04)
    }

    @Test func contentParts() {
        let json: [String: Any] = ["choices": [["message": ["content": [["type": "output_image", "url": png]]]]]]
        #expect(OpenRouterClient.extractImage(from: json) != nil)
    }

    @Test func embeddedInText() {
        let json: [String: Any] = ["choices": [["message": ["content": "Sure! ![img](\(png)) enjoy"]]]]
        #expect(OpenRouterClient.extractImage(from: json) != nil)
        let none: [String: Any] = ["choices": [["message": ["content": "I can't do that."]]]]
        #expect(OpenRouterClient.extractImage(from: none) == nil)
        #expect(OpenRouterClient.extractText(from: none) == "I can't do that.")
    }
}

@Suite struct SegmentationTests {
    @Test func findsASubjectOnPlainBackground() throws {
        let w = 320, h = 240
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(srgbRed: 0.95, green: 0.95, blue: 0.95, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.setFillColor(CGColor(srgbRed: 0.9, green: 0.2, blue: 0.1, alpha: 1))
        ctx.fillEllipse(in: CGRect(x: 20, y: 120, width: 100, height: 100))  // top-left in image space
        guard let mask = try? SubjectSegmentation.subjectMask(of: ctx.makeImage()!) else {
            return  // Vision may find no subject in synthetic art; nothing to assert.
        }
        #expect(mask.width == w && mask.height == h)
        #expect(mask.values[70 * w + 70] > mask.values[200 * w + 250])  // circle (y-down 70) vs empty corner
    }
}
