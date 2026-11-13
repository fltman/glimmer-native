import Foundation
import Testing
@testable import GlimmerAI

@Suite struct RealESRGANTests {
    @Test func tilesCoverTheImage() {
        for length in [1, 100, 224, 240, 241, 1000] {
            let o = RealESRGAN.origins(length: length)
            #expect(o.first == -RealESRGAN.margin)
            #expect(o.last! + RealESRGAN.tile - RealESRGAN.margin >= length)
            #expect(zip(o, o.dropFirst()).allSatisfy { $1 - $0 == RealESRGAN.tile - 2 * RealESRGAN.margin })
        }
    }

    @Test func upscalesFourTimesAndKeepsColours() async throws {
        // A soft gradient with a hard-edged square and a transparent corner.
        let w = 300, h = 170
        var px = [Float](repeating: 0, count: w * h * 4)
        for y in 0..<h {
            for x in 0..<w {
                let i = (y * w + x) * 4
                let inSquare = (100..<160).contains(x) && (60..<120).contains(y)
                px[i] = inSquare ? 230 : Float(x) / Float(w) * 255
                px[i + 1] = inSquare ? 30 : Float(y) / Float(h) * 255
                px[i + 2] = inSquare ? 40 : 120
                px[i + 3] = x < 20 && y < 20 ? 0 : 255
            }
        }
        let image = RGBAImage(width: w, height: h, pixels: px)
        let start = Date()
        let up = try await RealESRGAN.upscale(image)
        print("Real-ESRGAN \(w)×\(h) → \(up.width)×\(up.height) in \(String(format: "%.2f", Date().timeIntervalSince(start))) s")
        #expect(up.width == w * 4 && up.height == h * 4)
        #expect(up.pixels.allSatisfy { $0.isFinite && $0 >= 0 && $0 <= 255 })
        // Compare with a plain resize: same picture, small average difference.
        let reference = image.resized(width: w * 4, height: h * 4)
        var diff = 0.0, n = 0.0
        for i in stride(from: 0, to: up.pixels.count, by: 4) where reference.pixels[i + 3] > 250 {
            for c in 0..<3 { diff += Double(abs(up.pixels[i + c] - reference.pixels[i + c])) }
            n += 3
        }
        #expect(diff / n < 8, "mean difference \(diff / n)")
        // Inside the square, the red stays red.
        let centre = ((90 * 4) * (w * 4) + 130 * 4) * 4
        #expect(up.pixels[centre] > 200 && up.pixels[centre + 1] < 60)
        // Alpha is carried over.
        #expect(up.pixels[3] < 5 && up.pixels[(400 * w * 4 + 400) * 4 + 3] > 250)
    }

    @Test func twoTimesAveragesTheNetworkOutput() async throws {
        let image = RGBAImage(width: 64, height: 40, fill: SIMD4(200, 100, 50, 255))
        let up = try await RealESRGAN.upscale(image, scale: 2)
        #expect(up.width == 128 && up.height == 80)
        let mid = (40 * 128 + 64) * 4
        #expect(abs(up.pixels[mid] - 200) < 6 && abs(up.pixels[mid + 1] - 100) < 6 && abs(up.pixels[mid + 2] - 50) < 6)
    }
}
