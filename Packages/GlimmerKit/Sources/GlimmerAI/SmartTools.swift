import CoreGraphics
import CoreImage
import Foundation
import GlimmerCore
import Vision

// MARK: People

extension SubjectSegmentation {
    /// A soft mask (0...255) of every person in the image (Vision's accurate
    /// person segmentation: hair and edges are better than the subject mask).
    public static func peopleMask(of image: CGImage) throws -> GrayImage {
        let request = VNGeneratePersonSegmentationRequest()
        request.qualityLevel = .accurate
        request.outputPixelFormat = kCVPixelFormatType_OneComponent8
        try VNImageRequestHandler(cgImage: image).perform([request])
        guard let buffer = request.results?.first?.pixelBuffer else { throw SegmentationError.noSubject }
        let mask = try grayImage(from: buffer, width: image.width, height: image.height)
        // An empty mask means nobody was found.
        guard mask.values.contains(where: { $0 > 128 }) else { throw SegmentationError.noSubject }
        return mask
    }
}

// MARK: Text in the image

public enum ImageText {
    public struct Line: Sendable, Equatable {
        public var string: String
        /// Pixel rectangle, y down.
        public var box: CGRect
        public var confidence: Double
    }

    /// The text Vision can read, line by line, top to bottom.
    public static func lines(in image: CGImage) throws -> [Line] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true
        try VNImageRequestHandler(cgImage: image).perform([request])
        let w = Double(image.width), h = Double(image.height)
        let lines: [Line] = (request.results ?? []).compactMap { observation in
            guard let top = observation.topCandidates(1).first, top.confidence > 0.3 else { return nil }
            let b = observation.boundingBox  // normalised, y up
            let box = CGRect(x: b.minX * w, y: (1 - b.maxY) * h, width: b.width * w, height: b.height * h)
            return Line(string: top.string, box: box, confidence: Double(top.confidence))
        }
        return lines.sorted { abs($0.box.midY - $1.box.midY) > min($0.box.height, $1.box.height) / 2
            ? $0.box.midY < $1.box.midY : $0.box.minX < $1.box.minX }
    }

    /// The lines as plain text, one per line.
    public static func plainText(_ lines: [Line]) -> String {
        lines.map(\.string).joined(separator: "\n")
    }

    /// An editable text layer that covers `line`: its width matches the
    /// original's (the height follows), its colour is sampled from the image.
    public static func textLayer(for line: Line, in image: CGImage, fontName: String = "HelveticaNeue-Medium") -> Layer {
        let box = line.box
        var text = TextLayer(string: line.string, fontName: fontName, size: max(box.height * 0.8, 4),
                             color: textColor(in: image, box: box), origin: .zero)
        let width = text.layoutSize.width
        if width > 4 { text.size *= min(max(box.width / width, 0.5), 2) }
        let layout = text.layoutSize
        text.origin = SIMD2(box.minX - 1, box.midY - layout.height / 2)
        return Layer(name: String(line.string.prefix(32)), content: .text(text))
    }

    /// The text colour inside `box`: the pixels that differ most from the
    /// box's typical (background) colour. Works for dark-on-light and light-on-dark.
    public static func textColor(in image: CGImage, box: CGRect) -> SRGBColor {
        let rect = box.integral.intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard rect.width >= 2, rect.height >= 2, let crop = image.cropping(to: rect) else { return .black }
        let w = min(crop.width, 160), h = max(1, Int(Double(crop.height) * Double(w) / Double(crop.width)))
        var px = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return .black }
        ctx.draw(crop, in: CGRect(x: 0, y: 0, width: w, height: h))
        var samples: [(l: Double, c: SIMD3<Double>)] = []
        for i in stride(from: 0, to: px.count, by: 4) {
            let c = SIMD3(Double(px[i]), Double(px[i + 1]), Double(px[i + 2])) / 255
            samples.append((0.2126 * c.x + 0.7152 * c.y + 0.0722 * c.z, c))
        }
        let sorted = samples.map(\.l).sorted()
        let background = sorted[sorted.count / 2]
        let far = samples.sorted { abs($0.l - background) > abs($1.l - background) }.prefix(max(1, samples.count / 10))
        let mean = far.reduce(SIMD3<Double>.zero) { $0 + $1.c } / Double(far.count)
        return SRGBColor(mean.x, mean.y, mean.z)
    }
}

// MARK: Colour cast

extension SmartAnalysis {
    /// The colour cast of the image's near-neutral pixels (sRGB, per channel,
    /// relative to their grey), or nil when there are too few neutrals to judge.
    /// Saturated pixels are ignored, so a red car or a blue sky doesn't count as a cast.
    public static func colorCast(_ image: CGImage) -> SIMD3<Double>? {
        let w = min(image.width, 256), h = max(1, Int(Double(image.height) * Double(w) / Double(max(image.width, 1))))
        var px = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        var sum = SIMD3<Double>.zero, n = 0, total = 0
        for i in stride(from: 0, to: px.count, by: 4) where px[i + 3] > 8 {
            total += 1
            let c = SIMD3(Double(px[i]), Double(px[i + 1]), Double(px[i + 2])) / 255
            let mx = max(c.x, c.y, c.z), mn = min(c.x, c.y, c.z)
            let l = (c.x + c.y + c.z) / 3
            guard l > 0.15, l < 0.95, mx - mn < 0.25 else { continue }
            sum += c - SIMD3(repeating: l)
            n += 1
        }
        guard total > 0, Double(n) / Double(total) > 0.05 else { return nil }
        return sum / Double(n)
    }

    /// A cast worth correcting: larger than `threshold` in any channel.
    public static func isNoticeableCast(_ cast: SIMD3<Double>?, threshold: Double = 0.02) -> Bool {
        guard let cast else { return false }
        return max(abs(cast.x), abs(cast.y), abs(cast.z)) > threshold
    }

    /// A Color Balance adjustment that removes `cast` (most of it: a little
    /// warmth or coolness is often intended).
    public static func castCorrection(_ cast: SIMD3<Double>, strength: Double = 0.8) -> Adjustment {
        var a = Adjustment(.colorBalance)
        // The shader adds value × 0.5 × tone weight, and the three tone weights sum to 1.
        let shift = -cast * 2 * strength
        for tone in ["shadows", "midtones", "highlights"] {
            a.numbers["\(tone)R"] = min(max(shift.x, -1), 1)
            a.numbers["\(tone)G"] = min(max(shift.y, -1), 1)
            a.numbers["\(tone)B"] = min(max(shift.z, -1), 1)
        }
        a.flags["preserveLuminosity"] = true
        return a
    }
}

// MARK: What's in the picture

public enum ImageLabel {
    /// A short name for what the image shows ("Dog", "Beach"), or nil when
    /// Vision isn't confident.
    public static func name(for image: CGImage, minimumConfidence: Float = 0.35) -> String? {
        let request = VNClassifyImageRequest()
        try? VNImageRequestHandler(cgImage: image).perform([request])
        guard let best = (request.results ?? []).filter({ $0.confidence >= minimumConfidence })
            .max(by: { $0.confidence < $1.confidence }) else { return nil }
        let words = best.identifier.split(separator: "_").joined(separator: " ")
        return words.prefix(1).uppercased() + words.dropFirst()
    }

    /// Names a camera or the system gave the file ("IMG_1234", "Screenshot …",
    /// "Pasted Image"): worth replacing with what the image shows.
    public static func isGeneric(_ name: String) -> Bool {
        let n = name.trimmingCharacters(in: .whitespaces).lowercased()
        if n.isEmpty { return true }
        let prefixes = ["img", "dsc", "dscf", "dscn", "pxl", "mvimg", "photo", "image", "pasted", "screenshot",
                        "skärmavbild", "skarmavbild", "untitled", "namnlös", "layer", "clipboard", "scan"]
        if prefixes.contains(where: { n.hasPrefix($0) }) { return true }
        let digits = n.filter(\.isNumber).count
        return Double(digits) / Double(n.count) > 0.5
    }
}
