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

/// Serialized form of a layer. Pixels live in separate tile files:
/// `layers/<id>.tiles` (raster), `<id>.mask.tiles`, `<id>.smart.tiles`.
public struct LayerRecord: Codable, Sendable {
    public enum Kind: String, Codable, Sendable { case raster, adjustment, group, fill, smart, text }

    public struct MaskRecord: Codable, Sendable {
        public var defaultValue: Float
        public var enabled: Bool
        public var density: Double
        public var feather: Double
    }

    public struct SmartRecord: Codable, Sendable {
        public var width: Int
        public var height: Int
        public var transform: AffineTransform
        public var filters: [SmartFilter]?
    }

    public var id: UUID
    public var name: String
    public var kind: Kind
    public var visible: Bool
    public var opacity: Double
    public var blendMode: BlendMode
    public var clipped: Bool?
    public var mask: MaskRecord?
    public var vectorMask: VectorPath?
    public var effects: LayerEffects?
    public var adjustment: Adjustment?
    public var fill: Fill?
    public var smart: SmartRecord?
    public var text: TextLayer?
    public var expanded: Bool?
    /// Groups only, bottom → top.
    public var children: [LayerRecord]?
}

/// Top-level description of a document, stored as `manifest.json` in the package.
public struct DocumentManifest: Codable, Sendable {
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
    public var paths: [VectorPath]?
    public var aids: ViewAids?

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
