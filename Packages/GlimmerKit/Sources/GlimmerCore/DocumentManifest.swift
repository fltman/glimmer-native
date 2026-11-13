import Foundation
import UniformTypeIdentifiers

extension UTType {
    /// A `.glimmer` document package.
    public static let glimmerDocument = UTType(exportedAs: "com.brattoo.glimmer.document")
}

/// The colour space documents are tagged with. Pixels are always stored as
/// linear extended sRGB, which covers Display P3 and beyond; the tag decides the
/// default export profile.
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

/// Serialized form of a layer's properties (pixels live in `layers/<id>.tiles`).
public struct LayerRecord: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case raster }

    public var id: UUID
    public var name: String
    public var kind: Kind
    public var visible: Bool
    public var opacity: Double
    public var blendMode: BlendMode
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
    /// Bottom → top.
    public var layers: [LayerRecord]
    public var activeLayerID: UUID?

    public init(
        width: Int,
        height: Int,
        colorSpace: WorkingColorSpace = .sRGB,
        blendSpace: BlendSpace = .linear,
        layers: [LayerRecord] = [],
        activeLayerID: UUID? = nil
    ) {
        self.formatVersion = Self.currentFormatVersion
        self.width = width
        self.height = height
        self.colorSpace = colorSpace
        self.blendSpace = blendSpace
        self.layers = layers
        self.activeLayerID = activeLayerID
    }
}
