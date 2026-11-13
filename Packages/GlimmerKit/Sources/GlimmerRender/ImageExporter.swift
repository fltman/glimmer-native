import CoreGraphics
import Foundation
import GlimmerCore
import ImageIO
import Metal
import UniformTypeIdentifiers

public struct ExportOptions: Equatable, Sendable {
    public enum Format: String, CaseIterable, Sendable, Identifiable {
        case png, jpeg, heic, tiff

        public var id: String { rawValue }
        public var title: String {
            switch self {
            case .png: "PNG"
            case .jpeg: "JPEG"
            case .heic: "HEIC"
            case .tiff: "TIFF"
            }
        }
        public var contentType: UTType {
            switch self {
            case .png: .png
            case .jpeg: .jpeg
            case .heic: .heic
            case .tiff: .tiff
            }
        }
        public var supportsAlpha: Bool { self == .png || self == .tiff || self == .heic }
        public var supports16Bit: Bool { self == .png || self == .tiff }
        public var isLossy: Bool { self == .jpeg || self == .heic }
    }

    public var format: Format
    public var sixteenBit: Bool
    /// 0...1, lossy formats only.
    public var quality: Double
    public var colorSpace: WorkingColorSpace
    /// Straight sRGB colour used behind transparent pixels for formats without alpha.
    public var matte: SIMD3<Double>

    public init(format: Format = .png, sixteenBit: Bool = false, quality: Double = 0.92,
                colorSpace: WorkingColorSpace = .sRGB, matte: SIMD3<Double> = SIMD3(1, 1, 1)) {
        self.format = format
        self.sixteenBit = sixteenBit
        self.quality = quality
        self.colorSpace = colorSpace
        self.matte = matte
    }
}

public enum ImageExporter {
    /// Flattens the document to a CGImage in linear extended sRGB (Float16, premultiplied).
    public static func flatten(_ state: DocumentState, context: MetalContext) throws -> CGImage {
        let compositor = try DocumentCompositor(context: context)
        let (buffer, bytesPerRow, rect) = try compositor.renderPixels(state)
        let data = Data(bytesNoCopy: buffer.contents(), count: buffer.length, deallocator: .custom { _, _ in
            _ = buffer  // keep the Metal buffer alive as long as the data
        })
        guard let provider = CGDataProvider(data: data as CFData),
              let image = CGImage(
                width: rect.width, height: rect.height,
                bitsPerComponent: 16, bitsPerPixel: 64, bytesPerRow: bytesPerRow,
                space: ImageImporter.workingColorSpace,
                bitmapInfo: CGBitmapInfo(rawValue: CGBitmapInfo.floatComponents.rawValue
                    | CGBitmapInfo.byteOrder16Little.rawValue
                    | CGImageAlphaInfo.premultipliedLast.rawValue),
                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        else { throw RenderError.resourceCreationFailed("flattened image") }
        return image
    }

    /// Converts a linear image to the export colour space and bit depth, and
    /// flattens it over the matte when the format has no alpha.
    public static func convert(_ image: CGImage, options: ExportOptions) throws -> CGImage {
        let space = CGColorSpace(name: options.colorSpace == .displayP3 ? CGColorSpace.displayP3 : CGColorSpace.sRGB)!
        let sixteen = options.sixteenBit && options.format.supports16Bit
        let keepAlpha = options.format.supportsAlpha
        let bpc = sixteen ? 16 : 8
        let alpha: CGImageAlphaInfo = keepAlpha ? .premultipliedLast : .noneSkipLast
        var info = alpha.rawValue
        if sixteen { info |= CGBitmapInfo.byteOrder16Little.rawValue }

        guard let ctx = CGContext(data: nil, width: image.width, height: image.height,
                                  bitsPerComponent: bpc, bytesPerRow: 0, space: space, bitmapInfo: info) else {
            throw RenderError.resourceCreationFailed("export context")
        }
        let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        if !keepAlpha {
            let m = options.matte
            ctx.setFillColor(CGColor(srgbRed: m.x, green: m.y, blue: m.z, alpha: 1))
            ctx.fill(rect)
        }
        ctx.interpolationQuality = .none
        ctx.draw(image, in: rect)
        guard let converted = ctx.makeImage() else { throw RenderError.resourceCreationFailed("export image") }
        return converted
    }

    public static func encode(_ image: CGImage, options: ExportOptions) throws -> Data {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            data as CFMutableData, options.format.contentType.identifier as CFString, 1, nil) else {
            throw RenderError.resourceCreationFailed("no encoder for \(options.format.title)")
        }
        var props: [CFString: Any] = [:]
        if options.format.isLossy { props[kCGImageDestinationLossyCompressionQuality] = options.quality }
        CGImageDestinationAddImage(dest, try convert(image, options: options), props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else {
            throw RenderError.resourceCreationFailed("encoding \(options.format.title) failed")
        }
        return data as Data
    }

    public static func export(_ state: DocumentState, options: ExportOptions, to url: URL,
                              context: MetalContext) throws {
        let flat = try flatten(state, context: context)
        try encode(flat, options: options).write(to: url, options: .atomic)
    }
}
