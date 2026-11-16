#if GLIMMER_RAW   // Config/Features.xcconfig: not in a release until a real camera file has been looked at
import CoreGraphics
import CoreImage
import Foundation
import GlimmerCore

/// How a RAW file is developed. Saved with the layer, so the same file gives the same picture
/// again. Values left nil are the decoder's own for that file.
public struct RawSettings: Codable, Hashable, Sendable {
    /// In stops, added to the file's own exposure.
    public var exposure: Double = 0
    /// White balance in kelvin and tint; nil is as the camera shot it.
    public var temperature: Double?
    public var tint: Double?
    /// 0…2; 1 leaves the shadows as they are, more lifts them.
    public var shadows: Double = 1
    public var contrast: Double?
    public var highlightRecovery = true
    public var luminanceNoise: Double?
    public var colorNoise: Double?
    public var sharpness: Double?
    public var lensCorrection: Bool?
    /// The decoder version the picture was developed with ("9", "9.dng" …). Kept, so that a
    /// newer system doesn't change an old document's look; nil until the first development.
    public var process: String?

    public init() {}
}

/// What a RAW file's decoder says about it, before anything is developed.
public struct RawInfo: Sendable, Equatable {
    public var width: Int, height: Int
    /// The decoder versions this Mac offers for the file, oldest first.
    public var processes: [String]
    public var supportsLensCorrection: Bool, supportsHighlightRecovery: Bool
    public var supportsLuminanceNoise: Bool, supportsColorNoise: Bool, supportsSharpness: Bool, supportsContrast: Bool
    /// The file's own white balance and the decoder's defaults for it.
    public var temperature: Double, tint: Double
    public var luminanceNoise: Double, colorNoise: Double, sharpness: Double, contrast: Double
    public var lensCorrection: Bool
}

public enum RawDevelopment {
    public struct Problem: Error, LocalizedError, Equatable, Sendable {
        public let message: String
        public var errorDescription: String? { message }
    }

    static let notRaw = Problem(message: "This isn't a RAW file that this Mac can develop. Which cameras work is decided by macOS.")

    private static func filter(_ data: Data) throws -> CIRAWFilter {
        // The decoder is Apple's, inside this process: Glimmer checks what it can before and after.
        guard data.count >= 64, let filter = CIRAWFilter(imageData: data, identifierHint: nil), filter.nativeSize.width >= 1, filter.nativeSize.height >= 1,
              !filter.supportedDecoderVersions.isEmpty else { throw notRaw }
        return filter
    }

    /// The file's size and what can be set, read from its header: nothing is developed. A
    /// file larger than this Mac handles is refused here, before the first decode.
    public static func info(_ data: Data, maxPixels: Int = DocumentLimits.maxCanvasPixels()) throws -> RawInfo {
        let f = try filter(data)
        let width = Int(f.nativeSize.width), height = Int(f.nativeSize.height)
        let (pixels, overflow) = width.multipliedReportingOverflow(by: height)
        guard !overflow, pixels <= maxPixels, width <= DocumentManifest.maxDimension, height <= DocumentManifest.maxDimension else {
            throw Problem(message: DocumentLimits.refusal(width: width, height: height) ?? "This RAW file is \(width) × \(height) pixels, more than this Mac handles.")
        }
        return RawInfo(width: width, height: height, processes: f.supportedDecoderVersions.map(\.rawValue),
                       supportsLensCorrection: f.isLensCorrectionSupported, supportsHighlightRecovery: f.isHighlightRecoverySupported,
                       supportsLuminanceNoise: f.isLuminanceNoiseReductionSupported, supportsColorNoise: f.isColorNoiseReductionSupported,
                       supportsSharpness: f.isSharpnessSupported, supportsContrast: f.isContrastSupported,
                       temperature: Double(f.neutralTemperature), tint: Double(f.neutralTint),
                       luminanceNoise: Double(f.luminanceNoiseReductionAmount), colorNoise: Double(f.colorNoiseReductionAmount),
                       sharpness: Double(f.sharpnessAmount), contrast: Double(f.contrastAmount), lensCorrection: f.isLensCorrectionEnabled)
    }

    private static func configured(_ data: Data, _ settings: RawSettings, maxPixels: Int) throws -> (filter: CIRAWFilter, applied: RawSettings) {
        _ = try info(data, maxPixels: maxPixels)
        let f = try filter(data)
        var applied = settings
        let offered = f.supportedDecoderVersions
        if let wanted = settings.process {
            guard let version = offered.first(where: { $0.rawValue == wanted }) else {
                throw Problem(message: "This picture was developed with process \(wanted), which this version of macOS no longer offers. Develop it again to use the current one; it may look a little different.")
            }
            f.decoderVersion = version
        } else if let newest = offered.last {
            f.decoderVersion = newest
            applied.process = newest.rawValue
        }
        f.exposure = Float(min(max(settings.exposure, -5), 5))
        if let t = settings.temperature { f.neutralTemperature = Float(min(max(t, 2_000), 50_000)) }
        if let t = settings.tint { f.neutralTint = Float(min(max(t, -150), 150)) }
        f.boostShadowAmount = Float(min(max(settings.shadows, 0), 2))
        if f.isHighlightRecoverySupported { f.isHighlightRecoveryEnabled = settings.highlightRecovery }
        if let v = settings.contrast, f.isContrastSupported { f.contrastAmount = Float(min(max(v, 0), 1)) }
        if let v = settings.luminanceNoise, f.isLuminanceNoiseReductionSupported { f.luminanceNoiseReductionAmount = Float(min(max(v, 0), 1)) }
        if let v = settings.colorNoise, f.isColorNoiseReductionSupported { f.colorNoiseReductionAmount = Float(min(max(v, 0), 1)) }
        if let v = settings.sharpness, f.isSharpnessSupported { f.sharpnessAmount = Float(min(max(v, 0), 1)) }
        if let v = settings.lensCorrection, f.isLensCorrectionSupported { f.isLensCorrectionEnabled = v }
        return (f, applied)
    }

    private static let context = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!, .cacheIntermediates: false])

    /// The developed picture, in Glimmer's own pixels (linear light, half floats), and the
    /// settings as they were applied (the process filled in). `scale` below 1 is a quick,
    /// smaller draft for while a control is being moved.
    public static func develop(_ data: Data, settings: RawSettings, scale: Double = 1, maxPixels: Int = DocumentLimits.maxCanvasPixels()) throws -> (image: CGImage, applied: RawSettings) {
        let (f, applied) = try configured(data, settings, maxPixels: maxPixels)
        if scale < 1 {
            f.scaleFactor = Float(min(max(scale, 0.02), 1))
            f.isDraftModeEnabled = true
        }
        guard let output = f.outputImage, !output.extent.isInfinite, output.extent.width >= 1, output.extent.height >= 1,
              let image = context.createCGImage(output, from: output.extent, format: .RGBAh, colorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!) else {
            throw Problem(message: "macOS couldn't develop this RAW file.")
        }
        return (image, applied)
    }

    /// White balance from something that should be grey: the temperature and tint that make
    /// the pixel at `point` (in the developed picture's pixels, from the top left) neutral.
    public static func whiteBalance(for data: Data, settings: RawSettings, neutralAt point: CGPoint, maxPixels: Int = DocumentLimits.maxCanvasPixels()) throws -> (temperature: Double, tint: Double) {
        let (f, _) = try configured(data, settings, maxPixels: maxPixels)
        // The decoder counts from the bottom left.
        f.neutralLocation = CGPoint(x: min(max(point.x, 0), f.nativeSize.width - 1), y: min(max(f.nativeSize.height - 1 - point.y, 0), f.nativeSize.height - 1))
        return (Double(f.neutralTemperature), Double(f.neutralTint))
    }

    /// The camera models this Mac's decoder knows, for showing in the app instead of listing them in the manual.
    public static var cameras: [String] { CIRAWFilter.supportedCameraModels.sorted() }
}
#endif
