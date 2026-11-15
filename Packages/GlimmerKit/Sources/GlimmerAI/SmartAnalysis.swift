import CoreGraphics
import CoreImage
import Foundation
import GlimmerCore
import Vision

/// On-device image analysis: what the photo needs, found without a network
/// call. Feeds Auto Enhance, Auto Straighten, crop suggestions and the
/// omnibar's suggestions for the open image.
public enum SmartAnalysis {
    // MARK: Insights

    public struct Insights: Sendable, Equatable {
        /// Tilt of the horizon in degrees (positive = rising to the right).
        /// nil when there is no clear horizon or it is already level.
        public var horizonDegrees: Double?
        public var faceCount: Int
        /// Whether the image shows readable text.
        public var hasText: Bool
        /// Union of the salient objects, normalised (0…1, y down).
        public var salientRect: CGRect?
        public var tone: ToneStats
        public var enhance: EnhanceRecipe

        public init(horizonDegrees: Double? = nil, faceCount: Int = 0, hasText: Bool = false, salientRect: CGRect? = nil,
                    tone: ToneStats = ToneStats(), enhance: EnhanceRecipe = EnhanceRecipe()) {
            self.horizonDegrees = horizonDegrees
            self.faceCount = faceCount
            self.hasText = hasText
            self.salientRect = salientRect
            self.tone = tone
            self.enhance = enhance
        }
    }

    /// Luminance statistics in perceptual (sRGB) units, 0…1.
    public struct ToneStats: Sendable, Equatable {
        public var mean = 0.5
        /// 2nd and 98th percentiles.
        public var low = 0.0
        public var high = 1.0
        /// Mean HSV saturation.
        public var saturation = 0.3
        public init() {}

        public var range: Double { high - low }
        public var isFlat: Bool { range < 0.6 }
        public var isDark: Bool { mean < 0.3 }
        public var isBright: Bool { mean > 0.75 }
        public var isMuted: Bool { saturation < 0.12 }
    }

    /// Horizon tilts below this are left alone; above `maxTilt` the detection is
    /// more likely a diagonal in the scene than a crooked camera.
    public static let minTilt = 0.4, maxTilt = 20.0

    /// Everything at once, on a downscaled copy (the analysis needs ~1 MP at most).
    public static func insights(of image: CGImage) -> Insights {
        let small = downscaled(image, maxSide: 1024) ?? image
        var result = Insights()
        result.tone = toneStats(small)
        result.enhance = enhanceRecipe(for: small)
        let handler = VNImageRequestHandler(cgImage: small, options: [:])
        let horizon = VNDetectHorizonRequest()
        let saliency = VNGenerateAttentionBasedSaliencyImageRequest()
        let faces = VNDetectFaceRectanglesRequest()
        let text = VNRecognizeTextRequest()
        text.recognitionLevel = .fast
        text.usesLanguageCorrection = false
        try? handler.perform([horizon, saliency, faces, text])
        if let angle = horizon.results?.first?.angle {
            // Vision measures the angle the other way round (a horizon rising to the right is negative).
            result.horizonDegrees = usableTilt(-Double(angle) * 180 / .pi)
        }
        if let objects = (saliency.results?.first)?.salientObjects, !objects.isEmpty {
            let union = objects.map(\.boundingBox).reduce(CGRect.null) { $0.union($1) }
            result.salientRect = CGRect(x: union.minX, y: 1 - union.maxY, width: union.width, height: union.height)
        }
        result.faceCount = faces.results?.count ?? 0
        let words = (text.results ?? []).filter { ($0.topCandidates(1).first?.confidence ?? 0) > 0.5 }
        result.hasText = words.reduce(0) { $0 + ($1.topCandidates(1).first?.string.count ?? 0) } >= 6
        return result
    }

    /// A detected tilt worth correcting, or nil.
    public static func usableTilt(_ degrees: Double) -> Double? {
        abs(degrees) >= minTilt && abs(degrees) <= maxTilt ? degrees : nil
    }

    // MARK: Auto Enhance

    /// Core Image's automatic corrections, expressed as Glimmer adjustments so
    /// they land as editable layers instead of baked pixels.
    public struct EnhanceRecipe: Sendable, Equatable {
        /// RGB curve (sRGB values, like the Curves adjustment).
        public var curve: [CurvePoint] = CurveMath.identity
        public var vibrance = 0.0
        public init() {}

        /// Whether applying it would visibly change the image.
        public var isNoticeable: Bool {
            curve.contains { abs($0.y - $0.x) > 0.025 } || abs(vibrance) > 0.08
        }

        public var adjustments: [Adjustment] {
            var list: [Adjustment] = []
            if curve.contains(where: { abs($0.y - $0.x) > 0.005 }) {
                var a = Adjustment(.curves)
                a.curves[.rgb] = curve
                list.append(a)
            }
            if abs(vibrance) > 0.01 {
                var a = Adjustment(.vibrance)
                a.numbers["vibrance"] = vibrance
                list.append(a)
            }
            return list
        }
    }

    public static func enhanceRecipe(for image: CGImage) -> EnhanceRecipe {
        let ci = CIImage(cgImage: image)
        let filters = ci.autoAdjustmentFilters(options: [.redEye: false, .features: []])
        var recipe = EnhanceRecipe()
        var shadows = 0.0, highlights = 1.0
        for filter in filters {
            switch filter.name {
            case "CIToneCurve":
                recipe.curve = (0..<5).compactMap { i in
                    (filter.value(forKey: "inputPoint\(i)") as? CIVector).map { CurvePoint(Double($0.x), Double($0.y)) }
                }
            case "CIVibrance":
                recipe.vibrance = (filter.value(forKey: "inputAmount") as? NSNumber)?.doubleValue ?? 0
            case "CIHighlightShadowAdjust":
                shadows = (filter.value(forKey: "inputShadowAmount") as? NSNumber)?.doubleValue ?? 0
                highlights = (filter.value(forKey: "inputHighlightAmount") as? NSNumber)?.doubleValue ?? 1
            default:
                break
            }
        }
        if recipe.curve.count < 2 { recipe.curve = CurveMath.identity }
        recipe.curve = folded(recipe.curve, shadows: shadows, highlights: highlights)
        recipe.vibrance = min(max(recipe.vibrance, -1), 1)
        return recipe
    }

    /// Core Image's shadow/highlight step is local; Glimmer approximates it
    /// globally by lifting the dark end and easing the bright end of the curve.
    static func folded(_ curve: [CurvePoint], shadows: Double, highlights: Double) -> [CurvePoint] {
        let lift = min(max(shadows, 0), 1) * 0.1, ease = min(max(1 - highlights, 0), 1) * 0.08
        guard lift > 0.001 || ease > 0.001 else { return curve }
        var points = curve.sorted { $0.x < $1.x }
        for i in points.indices where points[i].x > 0 && points[i].x < 1 {
            let x = points[i].x
            points[i].y += lift * pow(1 - x, 2) * 4 * x  // peaks in the shadows, zero at both ends
            points[i].y -= ease * pow(x, 2) * 4 * (1 - x)
            points[i].y = min(max(points[i].y, 0), 1)
        }
        // Keep it monotone.
        for i in points.indices.dropFirst() { points[i].y = max(points[i].y, points[i - 1].y) }
        return points
    }

    // MARK: Crop suggestion

    /// A crop that frames the salient part of the image, in pixels (y down).
    /// With an aspect that differs from the image's, the largest box of that
    /// aspect slides over the subject; without one, the box tightens around it
    /// at the image's own proportions. nil when the whole image is the best crop.
    public static func suggestedCrop(salient: CGRect, imageWidth: Int, imageHeight: Int, aspect: Double?) -> CGRect? {
        let w = Double(imageWidth), h = Double(imageHeight)
        guard w > 0, h > 0, salient.width > 0, salient.height > 0 else { return nil }
        let s = CGRect(x: salient.minX * w, y: salient.minY * h, width: salient.width * w, height: salient.height * h)
        let imageAspect = w / h
        let a = aspect ?? imageAspect
        var bw: Double, bh: Double
        if a > imageAspect { bw = w; bh = w / a } else { bh = h; bw = h * a }
        if aspect == nil || abs(a - imageAspect) < 0.01 {
            // Tighten: the subject plus breathing room, never below 55 % of the frame.
            let k = min(1, max(0.55, max(s.width * 1.5 / bw, s.height * 1.5 / bh)))
            guard k < 0.95 else { return nil }
            bw *= k
            bh *= k
        }
        // Centre on the subject, nudged so it sits on the nearer third line.
        var cx = s.midX, cy = s.midY
        if s.width < bw * 0.5 { cx += (s.midX < w / 2 ? 1 : -1) * bw / 6 * 0.5 }
        if s.height < bh * 0.5 { cy += bh / 6 * 0.5 }  // a little headroom
        let x = min(max(cx - bw / 2, 0), w - bw), y = min(max(cy - bh / 2, 0), h - bh)
        return CGRect(x: x.rounded(), y: y.rounded(), width: bw.rounded(), height: bh.rounded())
    }

    // MARK: Helpers

    static func toneStats(_ image: CGImage) -> ToneStats {
        let w = min(image.width, 256), h = max(1, Int(Double(image.height) * Double(w) / Double(max(image.width, 1))))
        var px = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return ToneStats() }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        var histogram = [Int](repeating: 0, count: 256)
        var sum = 0.0, sat = 0.0, n = 0
        for i in stride(from: 0, to: px.count, by: 4) where px[i + 3] > 8 {
            let r = Double(px[i]), g = Double(px[i + 1]), b = Double(px[i + 2])
            let y = 0.2126 * r + 0.7152 * g + 0.0722 * b
            histogram[min(255, Int(y))] += 1
            sum += y
            let mx = max(r, g, b), mn = min(r, g, b)
            sat += mx > 0 ? (mx - mn) / mx : 0
            n += 1
        }
        guard n > 0 else { return ToneStats() }
        func percentile(_ p: Double) -> Double {
            let target = Int(Double(n) * p)
            var acc = 0
            for (v, c) in histogram.enumerated() {
                acc += c
                if acc > target { return Double(v) / 255 }
            }
            return 1
        }
        var stats = ToneStats()
        stats.mean = sum / Double(n) / 255
        stats.low = percentile(0.02)
        stats.high = percentile(0.98)
        stats.saturation = sat / Double(n)
        return stats
    }

    static func downscaled(_ image: CGImage, maxSide: Int) -> CGImage? {
        let side = max(image.width, image.height)
        guard side > maxSide else { return image }
        let k = Double(maxSide) / Double(side)
        let w = max(1, Int(Double(image.width) * k)), h = max(1, Int(Double(image.height) * k))
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .medium
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }
}
