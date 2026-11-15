import CoreGraphics
import CoreImage
import Foundation
import Vision

// MARK: Rating photos

/// How good a photo is, judged on this Mac: Apple's aesthetics model plus a
/// sharpness measure, for picking the keepers out of a batch.
public enum PhotoQuality {
    public struct Rating: Sendable, Equatable {
        /// Apple's overall aesthetics score, −1 (poor) … 1 (great).
        public var aesthetics: Double
        /// Screenshots, receipts, documents: pictures taken to keep information, not memories.
        public var isUtility: Bool
        /// 0 (very soft) … 1 (crisp); see `PhotoQuality.sharpness`.
        public var sharpness: Double
        /// A photograph rather than a flat graphic (see `colorVariety`).
        public var isPhotographic: Bool

        public init(aesthetics: Double, isUtility: Bool, sharpness: Double, isPhotographic: Bool = true) {
            self.aesthetics = aesthetics
            self.isUtility = isUtility
            self.sharpness = sharpness
            self.isPhotographic = isPhotographic
        }

        public var isBlurry: Bool { isPhotographic && sharpness < PhotoQuality.blurThreshold }

        /// A single number to sort by (higher is better): aesthetics, with soft
        /// pictures pushed down.
        public var score: Double { aesthetics - (isBlurry ? 0.6 : 0) + min(sharpness, 1) * 0.2 }

        /// 1…5 stars.
        public var stars: Int { min(5, max(1, Int(((score + 1) / 2 * 5).rounded(.up)))) }
    }

    /// Distinct colours (5 bits per channel) on a small copy: photos have
    /// thousands, flat graphics and screenshots far fewer.
    public static func colorVariety(_ image: CGImage) -> Int {
        let w = 128, h = max(1, 128 * image.height / max(image.width, 1))
        var px = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return 0 }
        ctx.interpolationQuality = .none
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        var seen = Set<Int>()
        for i in stride(from: 0, to: px.count, by: 4) where px[i + 3] > 128 {
            seen.insert(Int(px[i] >> 3) << 10 | Int(px[i + 1] >> 3) << 5 | Int(px[i + 2] >> 3))
        }
        return seen.count
    }

    /// Sharpness below this reads as out of focus or shaken.
    public static let blurThreshold = 0.56
    /// Fewer distinct colours than this: a graphic or screenshot, never called blurry.
    public static let photoColorVariety = 200

    public static func rate(_ image: CGImage) -> Rating {
        let small = SmartAnalysis.downscaled(image, maxSide: 1024) ?? image
        let request = VNCalculateImageAestheticsScoresRequest()
        try? VNImageRequestHandler(cgImage: small).perform([request])
        let observation = request.results?.first
        return Rating(aesthetics: Double(observation?.overallScore ?? 0), isUtility: observation?.isUtility ?? false,
                      sharpness: sharpness(small), isPhotographic: colorVariety(small) >= photoColorVariety)
    }

    /// Focus of the sharpest part of the picture: in the best of 4×4 regions,
    /// the variance of the Laplacian relative to the region's own contrast, on a
    /// 768-pixel copy, mapped to 0…1.
    /// Using the best region means a sharp subject on a soft background still
    /// counts as sharp.
    public static func sharpness(_ image: CGImage) -> Double {
        let side = 768
        let k = Double(side) / Double(max(image.width, image.height))
        let w = max(8, Int(Double(image.width) * min(k, 1))), h = max(8, Int(Double(image.height) * min(k, 1)))
        var gray = [UInt8](repeating: 0, count: w * h)
        guard let ctx = CGContext(data: &gray, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return 0 }
        ctx.interpolationQuality = .medium
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        let cells = 4
        var best = 0.0
        for cy in 0..<cells {
            for cx in 0..<cells {
                let x0 = max(1, cx * w / cells), x1 = min(w - 1, (cx + 1) * w / cells)
                let y0 = max(1, cy * h / cells), y1 = min(h - 1, (cy + 1) * h / cells)
                var sum = 0.0, sum2 = 0.0, isum = 0.0, isum2 = 0.0, n = 0.0
                for y in y0..<y1 {
                    for x in x0..<x1 {
                        let i = y * w + x
                        let v = Double(gray[i])
                        let l = 4 * v - Double(gray[i - 1]) - Double(gray[i + 1]) - Double(gray[i - w]) - Double(gray[i + w])
                        sum += l
                        sum2 += l * l
                        isum += v
                        isum2 += v * v
                        n += 1
                    }
                }
                guard n > 0 else { continue }
                let lapVar = sum2 / n - (sum / n) * (sum / n)
                let intensityVar = isum2 / n - (isum / n) * (isum / n)
                // Flat regions (sky, walls) say nothing about focus.
                guard intensityVar > 60 else { continue }
                // Relative to the region's own contrast, so a hazy or dark photo isn't called soft.
                best = max(best, lapVar / intensityVar)
            }
        }
        // Ratio ~1.2 is crisp, ~0.3 slightly soft, below 0.2 shaken or out of focus.
        return min(1, max(0, (log10(max(best, 1e-4)) + 1.7) / 1.8))
    }
}

// MARK: Documents and perspective

public enum DocumentDetection {
    /// A quadrilateral in pixel coordinates (y down), corners in order.
    public struct Quad: Sendable, Equatable {
        public var topLeft: CGPoint
        public var topRight: CGPoint
        public var bottomRight: CGPoint
        public var bottomLeft: CGPoint

        public init(topLeft: CGPoint, topRight: CGPoint, bottomRight: CGPoint, bottomLeft: CGPoint) {
            self.topLeft = topLeft
            self.topRight = topRight
            self.bottomRight = bottomRight
            self.bottomLeft = bottomLeft
        }

        public var corners: [CGPoint] { [topLeft, topRight, bottomRight, bottomLeft] }

        /// Width and height of the flattened result: the longer of each pair of opposite edges.
        public var outputSize: CGSize {
            func d(_ a: CGPoint, _ b: CGPoint) -> Double { hypot(a.x - b.x, a.y - b.y) }
            return CGSize(width: max(d(topLeft, topRight), d(bottomLeft, bottomRight)).rounded(),
                          height: max(d(topLeft, bottomLeft), d(topRight, bottomRight)).rounded())
        }
    }

    /// The document, sign, whiteboard or screen in the picture, if there is a
    /// clear one covering a fair part of the frame.
    public static func quad(in image: CGImage) -> Quad? {
        let w = Double(image.width), h = Double(image.height)
        func pixel(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x * w, y: (1 - p.y) * h) }
        let handler = VNImageRequestHandler(cgImage: image)
        let document = VNDetectDocumentSegmentationRequest()
        let rectangles = VNDetectRectanglesRequest()
        rectangles.minimumSize = 0.2
        rectangles.minimumConfidence = 0.6
        rectangles.maximumObservations = 1
        rectangles.quadratureTolerance = 30
        try? handler.perform([document, rectangles])
        let found: VNRectangleObservation? = (document.results?.first.map { $0 as VNRectangleObservation })
            ?? rectangles.results?.first
        guard let o = found, o.confidence > 0.5 else { return nil }
        let quad = Quad(topLeft: pixel(o.topLeft), topRight: pixel(o.topRight),
                        bottomRight: pixel(o.bottomRight), bottomLeft: pixel(o.bottomLeft))
        let size = quad.outputSize
        guard size.width * size.height > w * h * 0.08 else { return nil }
        return quad
    }

    /// The quad flattened to a rectangle (Core Image's perspective correction),
    /// kept in linear extended sRGB so no precision is lost.
    public static func corrected(_ image: CGImage, quad: Quad) -> CGImage? {
        let h = Double(image.height)
        func ci(_ p: CGPoint) -> CIVector { CIVector(x: p.x, y: h - p.y) }  // Core Image is y up
        let input = CIImage(cgImage: image)
        let output = input.applyingFilter("CIPerspectiveCorrection", parameters: [
            "inputTopLeft": ci(quad.topLeft), "inputTopRight": ci(quad.topRight),
            "inputBottomRight": ci(quad.bottomRight), "inputBottomLeft": ci(quad.bottomLeft),
        ])
        let linear = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
        let context = CIContext(options: [.workingColorSpace: linear])
        return context.createCGImage(output, from: output.extent.integral, format: .RGBAh, colorSpace: linear)
    }
}
