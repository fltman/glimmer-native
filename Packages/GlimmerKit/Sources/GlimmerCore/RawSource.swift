import Foundation

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

/// The RAW file a layer was developed from, kept with the layer: the file's bytes as they
/// were, how they were developed, and which pixels that gave. The layer's pixels are the
/// developed picture, a cache that can always be made again from the bytes and the settings.
/// (These types are in every build, so a document keeps its RAW layers whatever the build
/// can do; developing is behind GLIMMER_RAW.)
public struct RawSource: Sendable, Equatable {
    /// The RAW file, unchanged.
    public var data: Data
    /// The file's name when it was opened, for showing and for saving it out again.
    public var fileName: String
    public var settings: RawSettings
    /// The signature of the layer's pixels as they were developed. If the layer's pixels no
    /// longer have it, something was painted or pasted on it since, and developing again replaces that.
    public var developedSignature: Int?

    public init(data: Data, fileName: String, settings: RawSettings, developedSignature: Int? = nil) {
        self.data = data; self.fileName = fileName; self.settings = settings; self.developedSignature = developedSignature
    }

    /// The most a kept RAW file may be: larger files are not kept in a document.
    public static let maxBytes = 512 << 20
}
