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
                // Gather the tile, clamping at the image edges.
                input.withUnsafeMutableBufferPointer(ofType: Float.self) { dst, _ in
                    image.pixels.withUnsafeBufferPointer { src in
                        for ty in 0..<tile {
                            let sy = min(max(y0 + ty, 0), h - 1)
                            for tx in 0..<tile {
                                let sx = min(max(x0 + tx, 0), w - 1)
                                let s = (sy * w + sx) * 4, d = ty * tile + tx
                                dst[d] = src[s] / 255
                                dst[plane + d] = src[s + 1] / 255
                                dst[2 * plane + d] = src[s + 2] / 255
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
                    let weight = 255 / Float(down * down)
                    out.withUnsafeMutableBufferPointer { dst in
                        for ty in (keepY0 * f)..<((tile - margin) * f) {
                            let dy = (y0 * f + ty) / down
                            guard y0 * f + ty >= 0, dy < oh else { continue }
                            for tx in (keepX0 * f)..<((tile - margin) * f) {
                                let dx = (x0 * f + tx) / down
                                guard x0 * f + tx >= 0, dx < ow else { continue }
                                let d = (dy * ow + dx) * 4, s = ty * rs + tx
                                dst[d] += min(max(src[s], 0), 1) * weight
                                dst[d + 1] += min(max(src[cs + s], 0), 1) * weight
                                dst[d + 2] += min(max(src[2 * cs + s], 0), 1) * weight
                            }
                        }
                    }
                }
                done += 1
                progress?(done / total)
            }
        }
        // Alpha: plain resampling.
        let alpha = image.resized(width: ow, height: oh)
        for i in stride(from: 3, to: out.count, by: 4) { out[i] = alpha.pixels[i] }
        return RGBAImage(width: ow, height: oh, pixels: out)
    }
}
