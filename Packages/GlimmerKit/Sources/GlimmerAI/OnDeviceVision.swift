import CoreGraphics
import CoreImage
import CoreML
import CoreVideo
import Foundation

/// Converts a CGImage into a BGRA pixel buffer of a given size (stretched).
func pixelBuffer(_ image: CGImage, width: Int, height: Int) throws -> CVPixelBuffer {
    var buffer: CVPixelBuffer?
    let attrs = [kCVPixelBufferCGImageCompatibilityKey: true, kCVPixelBufferCGBitmapContextCompatibilityKey: true] as CFDictionary
    CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, attrs, &buffer)
    guard let buffer else { throw CocoaError(.featureUnsupported) }
    CVPixelBufferLockBaseAddress(buffer, [])
    defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
    let ctx = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height, bitsPerComponent: 8,
                        bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
    ctx.interpolationQuality = .high
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    return buffer
}

// MARK: Depth

/// Relative depth from Depth Anything V2 Small (Core ML). Near = 255.
public enum DepthEstimator {
    public static func depth(of image: CGImage, store: ModelStore = .shared,
                             progress: (@Sendable (Double) -> Void)? = nil) async throws -> GrayImage {
        let model = try await store.load(OnDeviceModel.depth.packages[0], of: .depth, progress: progress)
        let input = try pixelBuffer(image, width: 518, height: 392)
        let output = try await model.prediction(from: MLDictionaryFeatureProvider(dictionary: ["image": input]))
        guard let depth = output.featureValue(for: "depth")?.imageBufferValue else {
            throw CocoaError(.coderReadCorrupt)
        }
        var gray = try SubjectSegmentation.grayImage(from: depth, width: image.width, height: image.height)
        // Normalize: Depth Anything predicts relative inverse depth (larger = nearer).
        let lo = gray.values.min() ?? 0, hi = gray.values.max() ?? 255
        let span = max(hi - lo, 1e-3)
        gray.values = gray.values.map { ($0 - lo) / span * 255 }
        return gray
    }
}

// MARK: Segment Anything

/// Click-to-select with SAM 2.1 Tiny (Core ML). Encode the image once, then
/// segment repeatedly from positive/negative points.
public actor MagicSelector {
    public struct Point: Sendable, Equatable {
        /// Image pixel coordinates (y-down).
        public var location: SIMD2<Double>
        public var positive: Bool

        public init(_ location: SIMD2<Double>, positive: Bool) {
            self.location = location
            self.positive = positive
        }
    }

    private let store: ModelStore
    private var encoded: (key: Int, outputs: MLFeatureProvider, size: SIMD2<Int>)?

    public init(store: ModelStore = .shared) {
        self.store = store
    }

    static let inputSize = 1024

    /// Runs the image encoder (cached per `key`).
    public func prepare(_ image: CGImage, key: Int, progress: (@Sendable (Double) -> Void)? = nil) async throws {
        if encoded?.key == key { return }
        let encoder = try await store.load(OnDeviceModel.segmentAnything.packages[0], of: .segmentAnything, progress: progress)
        let input = try pixelBuffer(image, width: Self.inputSize, height: Self.inputSize)
        let out = try await encoder.prediction(from: MLDictionaryFeatureProvider(dictionary: ["image": input]))
        encoded = (key, out, SIMD2(image.width, image.height))
    }

    /// The best of SAM's three candidate masks for `points`, at image size (0...255).
    /// The mask decoder takes at most 15 prompt tokens (the points plus one padding token).
    public static let maxPoints = 14

    /// Points beyond `maxPoints`: the latest ones count (later clicks refine earlier ones).
    static func usable(_ points: [Point]) -> [Point] { Array(points.suffix(maxPoints)) }

    public func segment(_ points: [Point]) async throws -> GrayImage {
        let points = Self.usable(points)
        guard let encoded, !points.isEmpty else { throw CocoaError(.featureUnsupported) }
        let promptEncoder = try await store.load(OnDeviceModel.segmentAnything.packages[1], of: .segmentAnything)
        let decoder = try await store.load(OnDeviceModel.segmentAnything.packages[2], of: .segmentAnything)

        let n = points.count
        let coords = try MLMultiArray(shape: [1, NSNumber(value: n), 2], dataType: .float32)
        let labels = try MLMultiArray(shape: [1, NSNumber(value: n)], dataType: .float32)
        let sx = Double(Self.inputSize) / Double(encoded.size.x), sy = Double(Self.inputSize) / Double(encoded.size.y)
        for (i, p) in points.enumerated() {
            coords[[0, NSNumber(value: i), 0]] = NSNumber(value: p.location.x * sx)
            coords[[0, NSNumber(value: i), 1]] = NSNumber(value: p.location.y * sy)
            labels[[0, NSNumber(value: i)]] = NSNumber(value: p.positive ? 1 : 0)
        }
        let prompt = try await promptEncoder.prediction(from: MLDictionaryFeatureProvider(dictionary: [
            "points": coords, "labels": labels,
        ]))
        let decoded = try await decoder.prediction(from: MLDictionaryFeatureProvider(dictionary: [
            "image_embedding": encoded.outputs.featureValue(for: "image_embedding")!,
            "feats_s0": encoded.outputs.featureValue(for: "feats_s0")!,
            "feats_s1": encoded.outputs.featureValue(for: "feats_s1")!,
            "sparse_embedding": prompt.featureValue(for: "sparse_embeddings")!,
            "dense_embedding": prompt.featureValue(for: "dense_embeddings")!,
        ]))
        guard let masks = decoded.featureValue(for: "low_res_masks")?.multiArrayValue,
              let scores = decoded.featureValue(for: "scores")?.multiArrayValue else {
            throw CocoaError(.coderReadCorrupt)
        }
        var best = 0
        for i in 0..<3 where scores[[0, NSNumber(value: i)]].floatValue > scores[[0, NSNumber(value: best)]].floatValue {
            best = i
        }
        // Logits → 0...255 at 256², then stretched back to the image.
        let side = 256
        var low = [Float](repeating: 0, count: side * side)
        for y in 0..<side {
            for x in 0..<side {
                let logit = masks[[0, NSNumber(value: best), NSNumber(value: y), NSNumber(value: x)]].floatValue
                low[y * side + x] = 255 / (1 + exp(-logit * 4))  // sharpened sigmoid keeps soft edges
            }
        }
        return GrayImage(width: side, height: side, values: low).resized(width: encoded.size.x, height: encoded.size.y)
    }

    public func reset() {
        encoded = nil
    }
}
