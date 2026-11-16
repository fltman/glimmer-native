#if GLIMMER_RAW   // Config/Features.xcconfig
import CoreGraphics
import Foundation
import GlimmerCore

/// A layer developed from a RAW file: made, and developed again with other settings.
public enum RawLayer {
    /// A layer holding the RAW file and its developed picture, and the picture's size.
    public static func make(from data: Data, fileName: String, settings: RawSettings = RawSettings()) throws -> (layer: Layer, width: Int, height: Int) {
        guard data.count <= RawSource.maxBytes else {
            throw RawDevelopment.Problem(message: "This RAW file is \(ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file)), more than Glimmer keeps in a document.")
        }
        let (image, applied) = try RawDevelopment.develop(data, settings: settings)
        let tiles = try ImageImporter.tiles(from: image)
        var layer = Layer(name: (fileName as NSString).deletingPathExtension.isEmpty ? fileName : (fileName as NSString).deletingPathExtension, content: .raster(tiles))
        layer.raw = RawSource(data: data, fileName: fileName, settings: applied, developedSignature: tiles.contentSignature)
        return (layer, image.width, image.height)
    }

    /// The same layer developed with other settings: new pixels, the same RAW file. Everything
    /// else about the layer (mask, opacity, blend mode, effects) stays. Throws for a layer that has no RAW file.
    public static func developed(_ layer: Layer, with settings: RawSettings) throws -> Layer {
        try developedTimed(layer, with: settings).layer
    }

    /// The same, with how long the decoder took and how long the picture took to become Glimmer's tiles.
    public static func developedTimed(_ layer: Layer, with settings: RawSettings) throws -> (layer: Layer, decoderSeconds: Double, tileSeconds: Double) {
        guard let raw = layer.raw else { throw RawDevelopment.Problem(message: "This layer has no RAW file to develop.") }
        let began = Date()
        let (image, applied) = try RawDevelopment.develop(raw.data, settings: settings)
        let decoded = Date()
        let tiles = try ImageImporter.tiles(from: image)
        let tiled = Date()
        var out = layer
        out.content = .raster(tiles)
        out.raw = RawSource(data: raw.data, fileName: raw.fileName, settings: applied, developedSignature: tiles.contentSignature)
        return (out, decoded.timeIntervalSince(began), tiled.timeIntervalSince(decoded))
    }

    /// Whether the layer's pixels are still the ones its RAW file was developed to. False
    /// when something was painted or pasted on the layer since: developing again replaces that.
    public static func pixelsAreAsDeveloped(_ layer: Layer) -> Bool {
        guard let raw = layer.raw, case .raster(let grid) = layer.content else { return false }
        return raw.developedSignature == grid.contentSignature
    }
}
#endif
