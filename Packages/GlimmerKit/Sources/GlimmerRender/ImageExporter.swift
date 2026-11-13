import CoreGraphics
import Foundation
import GlimmerCore
import ImageIO
import Metal
import UniformTypeIdentifiers

public struct ExportOptions: Equatable, Sendable {
    public enum Format: String, CaseIterable, Sendable, Identifiable {
        case png, jpeg, heic, tiff, webp

        public var id: String { rawValue }
        public var title: String {
            switch self {
            case .png: "PNG"
            case .jpeg: "JPEG"
            case .heic: "HEIC"
            case .tiff: "TIFF"
            case .webp: "WebP"
            }
        }
        public var contentType: UTType {
            switch self {
            case .png: .png
            case .jpeg: .jpeg
            case .heic: .heic
            case .tiff: .tiff
            case .webp: .webP
            }
        }
        public var supportsAlpha: Bool { self != .jpeg }
        /// Bit depths the format can store (WebP is written losslessly, 8-bit).
        public var bitDepths: [BitDepth] {
            switch self {
            case .png: [.eight, .sixteen]
            case .tiff: [.eight, .sixteen, .float32]
            case .jpeg, .heic, .webp: [.eight]
            }
        }
        public var supports16Bit: Bool { bitDepths.contains(.sixteen) }
        public var isLossy: Bool { self == .jpeg || self == .heic }
        /// Shows the quality slider (WebP is lossless at 100 % and lossy below).
        public var hasQuality: Bool { isLossy || self == .webp }
    }

    public enum BitDepth: Int, CaseIterable, Sendable, Identifiable {
        case eight = 8, sixteen = 16
        /// 32-bit float, linear light (HDR values above 1 are kept).
        case float32 = 32

        public var id: Int { rawValue }
        public var title: String {
            switch self {
            case .eight: "8-bit"
            case .sixteen: "16-bit"
            case .float32: "32-bit float (linear)"
            }
        }
    }

    public var format: Format
    public var bitDepth: BitDepth

    /// The depth actually written: the requested one, or the deepest the format supports below it.
    public var effectiveBitDepth: BitDepth {
        format.bitDepths.last { $0.rawValue <= bitDepth.rawValue } ?? .eight
    }
    /// 0...1, lossy formats only.
    public var quality: Double
    public var colorSpace: WorkingColorSpace
    /// Straight sRGB colour used behind transparent pixels for formats without alpha.
    public var matte: SIMD3<Double>

    public init(format: Format = .png, bitDepth: BitDepth = .eight, quality: Double = 0.92,
                colorSpace: WorkingColorSpace = .sRGB, matte: SIMD3<Double> = SIMD3(1, 1, 1)) {
        self.format = format
        self.bitDepth = bitDepth
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

    /// The document composite as 8-bit straight sRGB (what AI models receive).
    public static func flattenedSRGB(_ state: DocumentState, context: MetalContext) throws -> CGImage {
        try convert(flatten(state, context: context), options: ExportOptions(format: .png))
    }

    /// One layer on its own (normal blending, full opacity, no mask) over the document bounds.
    public static func layerImageSRGB(_ layer: Layer, in state: DocumentState, context: MetalContext) throws -> CGImage {
        var solo = layer
        solo.isVisible = true
        solo.opacity = 1
        solo.blendMode = layer.isGroup ? .passThrough : .normal
        solo.mask = nil
        solo.isClipped = false
        var single = state
        single.layers = [solo]
        return try flattenedSRGB(single, context: context)
    }

    /// Converts a linear image to the export colour space and bit depth, and
    /// flattens it over the matte when the format has no alpha.
    public static func convert(_ image: CGImage, options: ExportOptions) throws -> CGImage {
        let depth = options.effectiveBitDepth
        let p3 = options.colorSpace == .displayP3
        // Float output stays linear and unclamped; integer output is gamma-encoded.
        let space = depth == .float32
            ? CGColorSpace(name: p3 ? CGColorSpace.extendedLinearDisplayP3 : CGColorSpace.extendedLinearSRGB)!
            : CGColorSpace(name: p3 ? CGColorSpace.displayP3 : CGColorSpace.sRGB)!
        let keepAlpha = options.format.supportsAlpha
        let bpc = depth.rawValue
        let alpha: CGImageAlphaInfo = keepAlpha ? .premultipliedLast : .noneSkipLast
        var info = alpha.rawValue
        switch depth {
        case .eight: break
        case .sixteen: info |= CGBitmapInfo.byteOrder16Little.rawValue
        case .float32: info |= CGBitmapInfo.byteOrder32Little.rawValue | CGBitmapInfo.floatComponents.rawValue
        }

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
        if options.format == .webp { return try encodeWebP(image, options: options) }
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

    /// WebP through `WebPEncoder` (lossless or lossy by quality), with the ICC profile embedded for Display P3.
    static func encodeWebP(_ image: CGImage, options: ExportOptions) throws -> Data {
        var eight = options
        eight.bitDepth = .eight
        let converted = try convert(image, options: eight)
        let w = converted.width, h = converted.height
        var px = [UInt8](repeating: 0, count: w * h * 4)
        let drawn = px.withUnsafeMutableBytes { buffer -> Bool in
            guard let space = converted.colorSpace,
                  let ctx = CGContext(data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.draw(converted, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drawn else { throw RenderError.resourceCreationFailed("WebP pixels") }
        // Straight alpha.
        for i in stride(from: 0, to: px.count, by: 4) where px[i + 3] < 255 && px[i + 3] > 0 {
            let a = Int(px[i + 3])
            for c in 0..<3 { px[i + c] = UInt8(min((Int(px[i + c]) * 255 + a / 2) / a, 255)) }
        }
        let icc = options.colorSpace == .displayP3 ? converted.colorSpace?.copyICCData() as Data? : nil
        // 100 % is lossless (VP8L); anything lower is lossy (VP8).
        if options.quality >= 0.995 {
            return try WebPEncoder.encode(rgba: px, width: w, height: h, iccProfile: icc)
        }
        return try WebPEncoder.encodeLossy(rgba: px, width: w, height: h, quality: options.quality, iccProfile: icc)
    }

    public static func export(_ state: DocumentState, options: ExportOptions, to url: URL,
                              context: MetalContext) throws {
        let flat = try flatten(state, context: context)
        try encode(flat, options: options).write(to: url, options: .atomic)
    }
}
