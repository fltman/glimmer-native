import CoreGraphics
import Foundation
import Testing
@testable import GlimmerAI

/// Runs against pre-downloaded models: set GLIMMER_MODELS_DIR to a folder with the
/// .mlpackage directories (see ModelStore).
@Suite(.enabled(if: ProcessInfo.processInfo.environment["GLIMMER_MODELS_DIR"] != nil), .serialized)
struct OnDeviceModelTests {
    /// A red mug on a two-tone background.
    func mug() -> CGImage {
        let w = 640, h = 480
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(srgbRed: 0.75, green: 0.85, blue: 0.95, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.setFillColor(CGColor(srgbRed: 0.3, green: 0.6, blue: 0.3, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: w, height: 140))
        ctx.setFillColor(CGColor(srgbRed: 0.85, green: 0.2, blue: 0.15, alpha: 1)); ctx.fill(CGRect(x: 240, y: 120, width: 160, height: 210))
        return ctx.makeImage()!
    }

    func store() -> ModelStore {
        ModelStore(root: FileManager.default.temporaryDirectory.appending(path: "glimmer-test-models"))
    }

    @Test func magicSelectFindsTheClickedObject() async throws {
        let selector = MagicSelector(store: store())
        let image = mug()
        let clock = ContinuousClock()
        let t = try await clock.measure { try await selector.prepare(image, key: 1) }
        // The mug spans x 240..<400, y (top-down) 150..<360.
        let mask = try await selector.segment([.init(SIMD2(320, 250), positive: true)])
        print("SAM encode \(t); mask \(mask.width)×\(mask.height)")
        #expect(mask.width == 640 && mask.height == 480)
        #expect(mask.values[250 * 640 + 320] > 200)  // clicked point
        #expect(mask.values[40 * 640 + 40] < 50)     // sky corner
    }

    @Test func depthHasStructure() async throws {
        let depth = try await DepthEstimator.depth(of: mug(), store: store())
        #expect(depth.width == 640 && depth.height == 480)
        let lo = depth.values.min()!, hi = depth.values.max()!
        #expect(lo < 5 && hi > 250)  // normalized to the full range
    }
}
