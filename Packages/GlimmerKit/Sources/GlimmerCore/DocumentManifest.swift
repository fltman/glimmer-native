import Foundation
import UniformTypeIdentifiers

extension UTType {
    /// A `.glimmer` document package.
    public static let glimmerDocument = UTType(exportedAs: "com.brattoo.glimmer.document")
}

/// The color space document pixels are stored in (always linear, extended range).
public enum WorkingColorSpace: String, Codable, Sendable, CaseIterable {
    case sRGB
    case displayP3
}

/// Where blend modes are evaluated.
public enum BlendSpace: String, Codable, Sendable, CaseIterable {
    /// Linear light. Matches Glimmer for the web.
    case linear
    /// Gamma-encoded, Photoshop-compatible.
    case gamma
}

/// Top-level description of a document, stored as `manifest.json` in the package.
public struct DocumentManifest: Codable, Equatable, Sendable {
    public static let currentFormatVersion = 1
    public static let maxDimension = 32_768

    public var formatVersion: Int
    public var width: Int
    public var height: Int
    public var colorSpace: WorkingColorSpace
    public var blendSpace: BlendSpace

    public init(
        width: Int,
        height: Int,
        colorSpace: WorkingColorSpace = .sRGB,
        blendSpace: BlendSpace = .linear
    ) {
        self.formatVersion = Self.currentFormatVersion
        self.width = width
        self.height = height
        self.colorSpace = colorSpace
        self.blendSpace = blendSpace
    }

    public var size: SIMD2<Double> { SIMD2(Double(width), Double(height)) }

    public static let defaultNewDocument = DocumentManifest(width: 1920, height: 1080)
}
