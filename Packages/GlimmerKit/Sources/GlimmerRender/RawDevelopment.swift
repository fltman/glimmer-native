#if GLIMMER_RAW   // Config/Features.xcconfig: not in a release until a real camera file has been looked at
import CoreGraphics
import CoreImage
import Foundation
import GlimmerCore

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

    static let notRaw = Problem(message: "macOS gives no picture for this RAW file. Which cameras and recording modes work is decided by macOS; another recording mode of the same camera may work.")

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
        // The size of the picture as it will be developed: turned the way the camera was held.
        // (The decoder's "native size" is the sensor's; a portrait shot has the two swapped.)
        var width = Int(f.nativeSize.width), height = Int(f.nativeSize.height)
        if let extent = f.outputImage?.extent, !extent.isInfinite, extent.width >= 1, extent.height >= 1 {
            width = Int(extent.width.rounded()); height = Int(extent.height.rounded())
        }
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
        return (f, try apply(settings, to: f))
    }

    /// Puts the settings on a decoder; returns them as applied (the process filled in).
    fileprivate static func apply(_ settings: RawSettings, to f: CIRAWFilter) throws -> RawSettings {
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
        return applied
    }

    fileprivate static func newFilter(_ data: Data, maxPixels: Int) throws -> CIRAWFilter {
        _ = try info(data, maxPixels: maxPixels)
        return try filter(data)
    }

    private static let context = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!, .cacheIntermediates: false])

    /// The developed picture, in Glimmer's own pixels (linear light, half floats), and the
    /// settings as they were applied (the process filled in). `scale` below 1 is a quick,
    /// smaller draft for while a control is being moved.
    public static func develop(_ data: Data, settings: RawSettings, scale: Double = 1, maxPixels: Int = DocumentLimits.maxCanvasPixels()) throws -> (image: CGImage, applied: RawSettings) {
        let (f, applied) = try configured(data, settings, maxPixels: maxPixels)
        guard var output = f.outputImage, !output.extent.isInfinite, output.extent.width >= 1, output.extent.height >= 1 else {
            throw Problem(message: "macOS couldn't develop this RAW file.")
        }
        if scale < 1 {
            // The picture is made smaller after developing, not by the decoder's own scale
            // setting: with that setting some DNG files came back cropped instead of scaled
            // (a phone file, 2026-11-16).
            let s = min(max(scale, 0.02), 1)
            output = output.transformed(by: CGAffineTransform(scaleX: s, y: s), highQualityDownsample: true)
        }
        let extent = output.extent.integral
        // Developed here and now, not when the picture is first drawn. A deferred picture came back in
        // 0.1 s and was then developed piece by piece while it was cut into tiles: 11 to 44 s for a
        // 40-megapixel file, and the cause of a Develop that seemed stuck (2026-11-16).
        guard let image = context.createCGImage(output, from: extent, format: .RGBAh, colorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!, deferred: false) else {
            throw Problem(message: "macOS couldn't develop this RAW file.")
        }
        return (image, applied)
    }

    /// White balance from something that should be grey: the temperature and tint that make
    /// the pixel at `point` (in the developed picture's pixels, from the top left) neutral.
    public static func whiteBalance(for data: Data, settings: RawSettings, neutralAt point: CGPoint, maxPixels: Int = DocumentLimits.maxCanvasPixels()) throws -> (temperature: Double, tint: Double) {
        let (f, _) = try configured(data, settings, maxPixels: maxPixels)
        // The decoder counts from the bottom left.
        let size = f.outputImage.map { $0.extent.isInfinite ? f.nativeSize : $0.extent.size } ?? f.nativeSize
        f.neutralLocation = CGPoint(x: min(max(point.x, 0), size.width - 1), y: min(max(size.height - 1 - point.y, 0), size.height - 1))
        return (Double(f.neutralTemperature), Double(f.neutralTint))
    }

    /// The largest side of a draft, in pixels.
    public static let draftSide = 1600

    /// The camera models this Mac's decoder knows, for showing in the app instead of listing them in the manual.
    public static var cameras: [String] { CIRAWFilter.supportedCameraModels.sorted() }
}

/// The picture while a control is being moved. One decoder is kept for as long as the Develop
/// sheet is open: making a new one for every change is what costs (0.3 to 4 s per change on
/// camera files, 2026-11-16). With it kept, a change is the real development, scaled down
/// afterwards, so the picture does not jump when the control is let go (0.02 to 0.06 of 255
/// from the finished picture on six camera files).
///
/// The decoder's own scale setting is not used: tried on the same six files against scaling
/// afterwards, it gave a different picture on every one (1.6 to 127 of 255 on average; a
/// crop rather than a smaller picture on four). Its draft mode is not used either (1 to 7).
/// Not for use from several threads at once.
public final class RawDraft {
    private let filter: CIRAWFilter
    private let context = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!])
    public let scale: Double
    /// The draft's size in pixels.
    public let width: Int, height: Int

    public init(_ data: Data, maxSide: Int = RawDevelopment.draftSide, maxPixels: Int = DocumentLimits.maxCanvasPixels()) throws {
        filter = try RawDevelopment.newFilter(data, maxPixels: maxPixels)
        guard let extent = filter.outputImage?.extent, !extent.isInfinite, extent.width >= 1, extent.height >= 1 else {
            throw RawDevelopment.Problem(message: "macOS couldn't develop this RAW file.")
        }
        scale = min(1, Double(maxSide) / Double(max(extent.width, extent.height)))
        width = max(1, Int((extent.width * scale).rounded())); height = max(1, Int((extent.height * scale).rounded()))
    }

    private func bytes() throws -> [UInt8] {
        guard var output = filter.outputImage, !output.extent.isInfinite else { throw RawDevelopment.Problem(message: "macOS couldn't develop this RAW file.") }
        if scale < 1 { output = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale), highQualityDownsample: true) }
        // Rendered now, into bytes: a picture that is only drawn when first shown would move the wait to the main thread.
        let rowBytes = width * 4
        var bytes = [UInt8](repeating: 0, count: rowBytes * height)
        let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
        bytes.withUnsafeMutableBytes { context.render(output, toBitmap: $0.baseAddress!, rowBytes: rowBytes, bounds: CGRect(x: output.extent.minX, y: output.extent.minY, width: CGFloat(width), height: CGFloat(height)), format: .RGBA8, colorSpace: srgb) }
        return bytes
    }

    /// Renders the kinds of change a person makes first (exposure, white balance, shadows), a
    /// hair away from `settings`, and throws the pictures away. The first change of each kind
    /// costs far more than the following ones (measured in the app, 2026-11-16: 0.3 to 1.7 s
    /// against 10 to 60 ms), so the sheet does this when it opens, before a control is touched.
    public func warmUp(from settings: RawSettings) {
        var exposure = settings; exposure.exposure += 0.01
        var balance = settings; balance.temperature = (settings.temperature ?? Double(filter.neutralTemperature)) * 1.002
        balance.tint = (settings.tint ?? Double(filter.neutralTint)) + 0.5
        var shadows = settings; shadows.shadows = min(2, settings.shadows + 0.01)
        for variant in [exposure, balance, shadows, settings] {
            _ = try? RawDevelopment.apply(variant, to: filter)
            _ = try? bytes()
        }
    }

    /// The draft for these settings, in sRGB with 8 bits per channel, for showing.
    public func picture(_ settings: RawSettings) throws -> CGImage {
        _ = try RawDevelopment.apply(settings, to: filter)
        let bytes = try bytes()
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue), provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) else {
            throw RawDevelopment.Problem(message: "macOS couldn't develop this RAW file.")
        }
        return image
    }
}
#endif
