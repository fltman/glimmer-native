import CoreGraphics
import CoreImage
import CoreVideo
import Foundation
import Vision

public enum SegmentationError: Error, LocalizedError {
    case noSubject

    public var errorDescription: String? {
        switch self {
        case .noSubject: "No subject was found in the image."
        }
    }
}

/// On-device subject segmentation (Vision). Replaces the web app's in-browser
/// RMBG-1.4 model: free, offline and fast.
public enum SubjectSegmentation {
    /// A soft mask (0...255) of all foreground subjects at the image's size.
    public static func subjectMask(of image: CGImage) throws -> GrayImage {
        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: image)
        try handler.perform([request])
        guard let observation = request.results?.first, !observation.allInstances.isEmpty else {
            throw SegmentationError.noSubject
        }
        let buffer = try observation.generateScaledMaskForImage(forInstances: observation.allInstances, from: handler)
        return try grayImage(from: buffer, width: image.width, height: image.height)
    }

    /// Reads a one-channel float (or 8-bit) pixel buffer, resampled to the requested size.
    static func grayImage(from buffer: CVPixelBuffer, width: Int, height: Int) throws -> GrayImage {
        let ci = CIImage(cvPixelBuffer: buffer)
        let sx = Double(width) / ci.extent.width, sy = Double(height) / ci.extent.height
        let scaled = ci.transformed(by: CGAffineTransform(scaleX: sx, y: sy))
        var values = [Float](repeating: 0, count: width * height)
        let context = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull()])
        values.withUnsafeMutableBytes { raw in
            context.render(scaled, toBitmap: raw.baseAddress!, rowBytes: width * 4,
                           bounds: CGRect(x: 0, y: 0, width: width, height: height), format: .Rf, colorSpace: nil)
        }
        return GrayImage(width: width, height: height, values: values.map { min(max($0, 0), 1) * 255 })
    }
}

