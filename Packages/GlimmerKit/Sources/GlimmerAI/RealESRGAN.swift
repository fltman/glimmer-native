import Accelerate
import CoreML
import Foundation

/// 4× super-resolution on this Mac with Real-ESRGAN's compact general model
/// (realesr-general-x4v3, BSD-3-Clause, bundled as a compiled Core ML model).
///
/// The model takes fixed 256 px tiles. Tiles overlap by `margin` pixels of
/// context on each side and only their centres are kept, so there are no seams.
public enum RealESRGAN {
    public static let factor = 4
    static let tile = 256
    static let margin = 16

    public enum Error: Swift.Error, LocalizedError {
        case modelMissing

        public var errorDescription: String? { "The Real-ESRGAN model is missing from the app." }
    }

    private static let shared = Loader()

    private actor Loader {
        var model: LoadedModel?

        func get() throws -> LoadedModel {
            if let model { return model }
            guard let url = Bundle.module.url(forResource: "RealESRGAN", withExtension: "mlmodelc") else { throw Error.modelMissing }
            let config = MLModelConfiguration()
            config.computeUnits = .all
            let loaded = LoadedModel(try MLModel(contentsOf: url, configuration: config))
            model = loaded
            return loaded
        }
    }

    /// Tile origins along one axis: steps of `tile − 2·margin`, the last one flush with the end.
    static func origins(length: Int) -> [Int] {
        let step = tile - 2 * margin
        var result: [Int] = []
        var x = -margin
        while true {
            result.append(x)
            if x + tile - margin >= length { break }
            x += step
        }
        return result
    }

    /// Upscales `image` (straight sRGB, 0…255) by `scale` (2 or 4). The network
    /// always runs at 4×; for 2× each tile is averaged down as it lands, so
    /// memory stays at the output size. Colour goes through the network,
    /// alpha is resampled. `progress` gets 0…1.
    public static func upscale(_ image: RGBAImage, scale: Int = 4,
                               progress: (@Sendable (Double) -> Void)? = nil) async throws -> RGBAImage {
        let model = try await shared.get()
        let w = image.width, h = image.height, f = factor
        let down = scale == 2 ? 2 : 1, ow = w * f / down, oh = h * f / down
        var out = [Float](repeating: 0, count: ow * oh * 4)
        let xs = origins(length: w), ys = origins(length: h)
        let total = Double(xs.count * ys.count)
        var done = 0.0
        let input = try MLMultiArray(shape: [1, 3, NSNumber(value: tile), NSNumber(value: tile)], dataType: .float32)
        let plane = tile * tile
        for y0 in ys {
            for x0 in xs {
                try Task.checkCancellation()
                // Gather the tile row by row (vectorised), clamping at the image edges.
                input.withUnsafeMutableBufferPointer(ofType: Float.self) { dst, _ in
                    image.pixels.withUnsafeBufferPointer { src in
                        var scale: Float = 1 / 255
                        let first = max(-x0, 0), last = min(w - x0, tile)  // tile columns inside the image
                        for ty in 0..<tile {
                            let sy = min(max(y0 + ty, 0), h - 1)
                            for c in 0..<3 {
                                let row = dst.baseAddress! + c * plane + ty * tile
                                vDSP_vsmul(src.baseAddress! + (sy * w + x0 + first) * 4 + c, 4, &scale, row + first, 1,
                                           vDSP_Length(last - first))
                                if first > 0 { var v = row[first]; vDSP_vfill(&v, row, 1, vDSP_Length(first)) }
                                if last < tile { var v = row[last - 1]; vDSP_vfill(&v, row + last, 1, vDSP_Length(tile - last)) }
                            }
                        }
                    }
                }
                let result = try await model.prediction(from: MLDictionaryFeatureProvider(dictionary: ["input": input]))
                guard let output = result.featureValue(for: "output")?.multiArrayValue else { throw Error.modelMissing }
                // Keep the tile's centre (its margin is context only), unless it touches the image edge.
                let keepX0 = x0 <= -margin ? 0 : margin, keepY0 = y0 <= -margin ? 0 : margin
                output.withUnsafeBufferPointer(ofType: Float.self) { src in
                    let strides = output.strides.map(\.intValue)
                    let cs = strides[1], rs = strides[2]
                    // Columns and rows of the 4× tile to keep, clipped to the image.
                    let tx0 = max(keepX0 * f, -x0 * f), tx1 = min((tile - margin) * f, (w - x0) * f)
                    let ty0 = max(keepY0 * f, -y0 * f), ty1 = min((tile - margin) * f, (h - y0) * f)
                    guard tx1 > tx0, ty1 > ty0 else { return }
                    let n = tx1 - tx0
                    var lo: Float = 0, hi: Float = 1, weight: Float = 255 / Float(down * down)
                    var clipped = [Float](repeating: 0, count: n)
                    var paired = [Float](repeating: 0, count: n / 2)
                    out.withUnsafeMutableBufferPointer { dst in
                        for ty in ty0..<ty1 {
                            let dy = (y0 * f + ty) / down
                            for c in 0..<3 {
                                vDSP_vclip(src.baseAddress! + c * cs + ty * rs + tx0, 1, &lo, &hi, &clipped, 1, vDSP_Length(n))
                                let target = dst.baseAddress! + (dy * ow + (x0 * f + tx0) / down) * 4 + c
                                if down == 1 {
                                    vDSP_vsmul(clipped, 1, &weight, target, 4, vDSP_Length(n))
                                } else {
                                    // Average 2 × 2: add neighbours across, accumulate the two rows.
                                    clipped.withUnsafeBufferPointer { p in
                                        vDSP_vadd(p.baseAddress!, 2, p.baseAddress! + 1, 2, &paired, 1, vDSP_Length(n / 2))
                                    }
                                    vDSP_vsma(paired, 1, &weight, target, 4, target, 4, vDSP_Length(n / 2))
                                }
                            }
                        }
                    }
                }
                done += 1
                progress?(done / total)
            }
        }
        // Alpha: opaque images (the usual case) just get 255; otherwise plain resampling.
        var minAlpha: Float = 255
        image.pixels.withUnsafeBufferPointer { vDSP_minv($0.baseAddress! + 3, 4, &minAlpha, vDSP_Length(w * h)) }
        if minAlpha >= 255 {
            var opaque: Float = 255
            out.withUnsafeMutableBufferPointer { vDSP_vfill(&opaque, $0.baseAddress! + 3, 4, vDSP_Length(ow * oh)) }
        } else {
            let alpha = image.resized(width: ow, height: oh)
            for i in stride(from: 3, to: out.count, by: 4) { out[i] = alpha.pixels[i] }
        }
        return RGBAImage(width: ow, height: oh, pixels: out)
    }
}
