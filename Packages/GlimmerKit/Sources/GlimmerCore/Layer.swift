import Foundation

/// The Photoshop-style blend modes Glimmer supports (W3C compositing formulas).
public enum BlendMode: String, Codable, CaseIterable, Sendable {
    case normal
    case darken, multiply, colorBurn = "color-burn", linearBurn = "linear-burn"
    case lighten, screen, colorDodge = "color-dodge", linearDodge = "linear-dodge"
    case overlay, softLight = "soft-light", hardLight = "hard-light"
    case difference, exclusion
    case hue, saturation, color, luminosity

    /// Stable index used by the blend shader. Must match `blendColor` in Tiles.metal.
    public var shaderIndex: Int32 {
        switch self {
        case .normal: 0
        case .multiply: 1
        case .screen: 2
        case .overlay: 3
        case .darken: 4
        case .lighten: 5
        case .colorDodge: 6
        case .colorBurn: 7
        case .hardLight: 8
        case .softLight: 9
        case .difference: 10
        case .exclusion: 11
        case .linearDodge: 12
        case .linearBurn: 13
        case .hue: 14
        case .saturation: 15
        case .color: 16
        case .luminosity: 17
        }
    }

    public var title: String {
        switch self {
        case .normal: "Normal"
        case .darken: "Darken"
        case .multiply: "Multiply"
        case .colorBurn: "Color Burn"
        case .linearBurn: "Linear Burn"
        case .lighten: "Lighten"
        case .screen: "Screen"
        case .colorDodge: "Color Dodge"
        case .linearDodge: "Linear Dodge (Add)"
        case .overlay: "Overlay"
        case .softLight: "Soft Light"
        case .hardLight: "Hard Light"
        case .difference: "Difference"
        case .exclusion: "Exclusion"
        case .hue: "Hue"
        case .saturation: "Saturation"
        case .color: "Color"
        case .luminosity: "Luminosity"
        }
    }

    /// Menu groups, in Photoshop order.
    public static let menuGroups: [[BlendMode]] = [
        [.normal],
        [.darken, .multiply, .colorBurn, .linearBurn],
        [.lighten, .screen, .colorDodge, .linearDodge],
        [.overlay, .softLight, .hardLight],
        [.difference, .exclusion],
        [.hue, .saturation, .color, .luminosity],
    ]
}

public enum LayerContent: Sendable {
    case raster(TileGrid)
}

public struct Layer: Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var isVisible: Bool
    /// 0...1
    public var opacity: Double
    public var blendMode: BlendMode
    public var content: LayerContent

    public init(
        id: UUID = UUID(),
        name: String,
        isVisible: Bool = true,
        opacity: Double = 1,
        blendMode: BlendMode = .normal,
        content: LayerContent
    ) {
        self.id = id
        self.name = name
        self.isVisible = isVisible
        self.opacity = opacity
        self.blendMode = blendMode
        self.content = content
    }

    public var tiles: TileGrid {
        get {
            switch content {
            case .raster(let grid): grid
            }
        }
        set { content = .raster(newValue) }
    }
}

/// The complete, value-typed state of a document. Snapshots are cheap: tiles are
/// shared, immutable references.
public struct DocumentState: Sendable {
    public var width: Int
    public var height: Int
    public var colorSpace: WorkingColorSpace
    public var blendSpace: BlendSpace
    /// Bottom → top.
    public var layers: [Layer]
    public var activeLayerID: UUID?

    public init(
        width: Int,
        height: Int,
        colorSpace: WorkingColorSpace = .sRGB,
        blendSpace: BlendSpace = .linear,
        layers: [Layer] = [],
        activeLayerID: UUID? = nil
    ) {
        self.width = width
        self.height = height
        self.colorSpace = colorSpace
        self.blendSpace = blendSpace
        self.layers = layers
        self.activeLayerID = activeLayerID ?? layers.last?.id
    }

    public var size: SIMD2<Double> { SIMD2(Double(width), Double(height)) }
    public var bounds: PixelRect { PixelRect(x: 0, y: 0, width: width, height: height) }

    public func index(of id: UUID?) -> Int? {
        guard let id else { return nil }
        return layers.firstIndex { $0.id == id }
    }

    public var activeIndex: Int? { index(of: activeLayerID) }

    public var activeLayer: Layer? { activeIndex.map { layers[$0] } }

    // MARK: Factories

    public enum Background: Sendable, Equatable {
        case transparent
        /// Premultiplied linear colour.
        case color(SIMD4<Float>)

        public static let white = Background.color(SIMD4(1, 1, 1, 1))
        public static let black = Background.color(SIMD4(0, 0, 0, 1))
    }

    public static func new(width: Int, height: Int, background: Background) -> DocumentState {
        let bounds = PixelRect(x: 0, y: 0, width: width, height: height)
        let layer: Layer
        switch background {
        case .transparent:
            layer = Layer(name: "Layer 1", content: .raster(TileGrid()))
        case .color(let c):
            layer = Layer(name: "Background", content: .raster(.solid(c, covering: bounds)))
        }
        return DocumentState(width: width, height: height, layers: [layer])
    }

    // MARK: Layer operations (pure; callers register undo)

    /// A name like "Layer 3" that isn't taken yet.
    public func nextLayerName(prefix: String = "Layer") -> String {
        let taken = Set(layers.map(\.name))
        var n = layers.count + 1
        while taken.contains("\(prefix) \(n)") { n += 1 }
        return "\(prefix) \(n)"
    }

    /// Inserts above the active layer (or on top) and activates it.
    public mutating func insertLayerAboveActive(_ layer: Layer) {
        let index = activeIndex.map { $0 + 1 } ?? layers.count
        layers.insert(layer, at: index)
        activeLayerID = layer.id
    }

    @discardableResult
    public mutating func duplicateActiveLayer() -> Layer? {
        guard let i = activeIndex else { return nil }
        var copy = layers[i]
        copy.id = UUID()
        copy.name = layers[i].name + " copy"
        layers.insert(copy, at: i + 1)
        activeLayerID = copy.id
        return copy
    }

    public mutating func deleteActiveLayer() {
        guard let i = activeIndex else { return }
        layers.remove(at: i)
        activeLayerID = layers.isEmpty ? nil : layers[max(0, i - 1)].id
    }

    /// Moves the active layer by `delta` positions (positive = up). Returns false if it can't move.
    @discardableResult
    public mutating func moveActiveLayer(by delta: Int) -> Bool {
        guard let i = activeIndex else { return false }
        let target = min(max(i + delta, 0), layers.count - 1)
        guard target != i else { return false }
        let layer = layers.remove(at: i)
        layers.insert(layer, at: target)
        return true
    }

    public mutating func updateLayer(_ id: UUID, _ change: (inout Layer) -> Void) {
        guard let i = index(of: id) else { return }
        change(&layers[i])
    }
}
