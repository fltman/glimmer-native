import Foundation

/// The Photoshop-style blend modes Glimmer supports (W3C compositing formulas).
public enum BlendMode: String, Codable, CaseIterable, Sendable {
    /// Groups only: children blend straight into what's below.
    case passThrough = "pass-through"
    case normal
    case darken, multiply, colorBurn = "color-burn", linearBurn = "linear-burn", darkerColor = "darker-color"
    case lighten, screen, colorDodge = "color-dodge", linearDodge = "linear-dodge", lighterColor = "lighter-color"
    case overlay, softLight = "soft-light", hardLight = "hard-light"
    case vividLight = "vivid-light", linearLight = "linear-light", pinLight = "pin-light", hardMix = "hard-mix"
    case difference, exclusion, subtract, divide
    case hue, saturation, color, luminosity

    /// Stable index used by the blend shader. Must match `blendColor` in Tiles.metal.
    public var shaderIndex: Int32 {
        switch self {
        case .normal, .passThrough: 0
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
        case .vividLight: 18
        case .linearLight: 19
        case .pinLight: 20
        case .hardMix: 21
        case .subtract: 22
        case .divide: 23
        case .darkerColor: 24
        case .lighterColor: 25
        }
    }

    public var title: String {
        switch self {
        case .passThrough: "Pass Through"
        case .normal: "Normal"
        case .darken: "Darken"
        case .multiply: "Multiply"
        case .colorBurn: "Color Burn"
        case .linearBurn: "Linear Burn"
        case .darkerColor: "Darker Color"
        case .lighterColor: "Lighter Color"
        case .lighten: "Lighten"
        case .screen: "Screen"
        case .colorDodge: "Color Dodge"
        case .linearDodge: "Linear Dodge (Add)"
        case .overlay: "Overlay"
        case .softLight: "Soft Light"
        case .hardLight: "Hard Light"
        case .vividLight: "Vivid Light"
        case .linearLight: "Linear Light"
        case .pinLight: "Pin Light"
        case .hardMix: "Hard Mix"
        case .difference: "Difference"
        case .exclusion: "Exclusion"
        case .subtract: "Subtract"
        case .divide: "Divide"
        case .hue: "Hue"
        case .saturation: "Saturation"
        case .color: "Color"
        case .luminosity: "Luminosity"
        }
    }

    /// Menu groups, in Photoshop order (without Pass Through).
    public static let menuGroups: [[BlendMode]] = [
        [.normal],
        [.darken, .multiply, .colorBurn, .linearBurn, .darkerColor],
        [.lighten, .screen, .colorDodge, .linearDodge, .lighterColor],
        [.overlay, .softLight, .hardLight, .vividLight, .linearLight, .pinLight, .hardMix],
        [.difference, .exclusion, .subtract, .divide],
        [.hue, .saturation, .color, .luminosity],
    ]

    /// The mode a Glimmer for the web project gets: the web app has the W3C modes only, so the
    /// Photoshop extras map to the nearest one there.
    public var webMode: BlendMode {
        switch self {
        case .passThrough: .normal
        case .vividLight, .linearLight, .pinLight, .hardMix: .hardLight
        case .subtract: .difference
        case .darkerColor: .darken
        case .lighterColor: .lighten
        case .divide: .colorDodge
        default: self
        }
    }

    /// All modes the W3C formulas cover (everything except Pass Through).
    public static let pixelModes: [BlendMode] = allCases.filter { $0 != .passThrough }
}

public enum LayerContent: Sendable {
    case raster(TileGrid)
    case adjustment(Adjustment)
    case group(LayerGroup)
    case fill(Fill)
    case smart(SmartObject)
    case text(TextLayer)

    public var kindName: String {
        switch self {
        case .raster: "raster"
        case .adjustment: "adjustment"
        case .group: "group"
        case .fill: "fill"
        case .smart: "smart"
        case .text: "text"
        }
    }
}

public struct Layer: Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var isVisible: Bool
    /// 0...1, applies to the layer and its effects.
    public var opacity: Double
    public var blendMode: BlendMode
    public var mask: LayerMask?
    /// Shape layers: the path the mask is rasterized from (kept so the shape
    /// stays editable and scales without losing quality).
    public var vectorMask: VectorPath?
    /// The words this layer held when it was a text layer in another program's file and came
    /// in as pixels (saved): what it says stays findable though it can't be edited as text.
    public var formerText: String?
    /// A layer developed from a RAW file keeps the file and its settings (saved), so it can
    /// be developed again. Its content is the developed picture, as ordinary pixels.
    public var raw: RawSource?
    /// Clips to the nearest non-clipped sibling below.
    public var isClipped: Bool
    public var effects: LayerEffects
    public var content: LayerContent

    public init(
        id: UUID = UUID(),
        name: String,
        isVisible: Bool = true,
        opacity: Double = 1,
        blendMode: BlendMode = .normal,
        mask: LayerMask? = nil,
        vectorMask: VectorPath? = nil,
        isClipped: Bool = false,
        effects: LayerEffects = LayerEffects(),
        content: LayerContent
    ) {
        self.vectorMask = vectorMask
        self.id = id
        self.name = name
        self.isVisible = isVisible
        self.opacity = opacity
        self.blendMode = blendMode
        self.mask = mask
        self.isClipped = isClipped
        self.effects = effects
        self.content = content
    }

    /// Pixels of a raster layer (empty for other kinds). Setting converts the layer to raster.
    public var tiles: TileGrid {
        get {
            if case .raster(let grid) = content { return grid }
            return TileGrid()
        }
        set { content = .raster(newValue) }
    }

    public var isGroup: Bool { if case .group = content { true } else { false } }
    public var isRaster: Bool { if case .raster = content { true } else { false } }
    public var isAdjustment: Bool { if case .adjustment = content { true } else { false } }
    public var isText: Bool { if case .text = content { true } else { false } }

    public var children: [Layer] {
        if case .group(let g) = content { return g.children }
        return []
    }

    /// This layer and all descendants, depth first.
    public var subtree: [Layer] {
        [self] + children.flatMap(\.subtree)
    }

    /// A deep copy with fresh ids.
    public func duplicated(name: String? = nil) -> Layer {
        var copy = self
        copy.id = UUID()
        if let name { copy.name = name }
        if case .group(var g) = content {
            g.children = g.children.map { $0.duplicated() }
            copy.content = .group(g)
        }
        return copy
    }
}

/// The complete, value-typed state of a document. Snapshots are cheap: tiles are
/// shared, immutable references.
/// "Edit in Glimmer" from a sibling app: which file the document writes back to, kept with
/// the document so a restored window is still linked (SIBLINGS.md §6).
public struct DocumentLink: Codable, Sendable, Equatable {
    /// A security-scoped bookmark of the file, when one could be made.
    public var bookmark: Data?
    /// Where the file was, for display and as a fallback.
    public var path: String
    /// The app that asked ("Flimmer").
    public var requester: String

    public init(bookmark: Data?, path: String, requester: String) {
        self.bookmark = bookmark
        self.path = path
        self.requester = requester
    }

    public var fileName: String { URL(fileURLWithPath: path).lastPathComponent }
}

public struct DocumentState: Sendable {
    public var width: Int
    public var height: Int
    public var colorSpace: WorkingColorSpace
    public var blendSpace: BlendSpace
    /// Root layers, bottom → top.
    public var layers: [Layer]
    public var activeLayerID: UUID?
    /// The current pixel selection (nil = nothing selected). Not saved with the document.
    public var selection: Selection?
    /// Pen-tool paths (saved).
    public var paths: [VectorPath] = []
    /// Guides, grid and rulers (saved).
    public var aids = ViewAids()
    /// The file of another app this document is an edit of (saved, so the link survives a
    /// restart). Only set on the copy that is being written or was just read; the editor
    /// keeps the live link itself.
    public var link: DocumentLink?
    /// What was kept and lost when this document was made from a Photoshop file (saved).
    public var importReport: PSDImportReport?

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

    // MARK: Tree access

    /// Index path from the root (`[2, 0]` = first child of the third root layer).
    public typealias LayerPath = [Int]

    public func path(of id: UUID?) -> LayerPath? {
        guard let id else { return nil }
        func search(_ list: [Layer], _ prefix: LayerPath) -> LayerPath? {
            for (i, layer) in list.enumerated() {
                if layer.id == id { return prefix + [i] }
                if let found = search(layer.children, prefix + [i]) { return found }
            }
            return nil
        }
        return search(layers, [])
    }

    public func layer(at path: LayerPath) -> Layer? {
        var list = layers
        var result: Layer?
        for i in path {
            guard list.indices.contains(i) else { return nil }
            result = list[i]
            list = list[i].children
        }
        return result
    }

    public func layer(id: UUID?) -> Layer? {
        path(of: id).flatMap(layer(at:))
    }

    /// Siblings at the given parent path (`[]` = root).
    public func children(of parent: LayerPath) -> [Layer] {
        parent.isEmpty ? layers : (layer(at: parent)?.children ?? [])
    }

    mutating func modifyChildren(of parent: LayerPath, _ change: (inout [Layer]) -> Void) {
        if parent.isEmpty {
            change(&layers)
            return
        }
        func walk(_ list: inout [Layer], _ rest: ArraySlice<Int>) {
            guard let i = rest.first, list.indices.contains(i) else { return }
            if rest.count == 1 {
                if case .group(var g) = list[i].content {
                    change(&g.children)
                    list[i].content = .group(g)
                }
            } else if case .group(var g) = list[i].content {
                walk(&g.children, rest.dropFirst())
                list[i].content = .group(g)
            }
        }
        walk(&layers, parent[...])
    }

    public var activeLayer: Layer? { layer(id: activeLayerID) }

    /// Every layer in the tree, depth first.
    public var allLayers: [Layer] { layers.flatMap(\.subtree) }

    /// The bytes of the RAW files this document's layers keep (they are saved with it and held while it is open).
    public var keptRawBytes: Int { allLayers.reduce(0) { $0 + ($1.raw?.data.count ?? 0) } }

    public mutating func updateLayer(_ id: UUID, _ change: (inout Layer) -> Void) {
        guard let path = path(of: id) else { return }
        modifyChildren(of: Array(path.dropLast())) { change(&$0[path.last!]) }
    }

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
        let taken = Set(allLayers.map(\.name))
        var n = 1
        while taken.contains("\(prefix) \(n)") { n += 1 }
        return "\(prefix) \(n)"
    }

    /// Inserts above the active layer, in the same group, and activates it.
    public mutating func insertLayerAboveActive(_ layer: Layer) {
        if let path = path(of: activeLayerID) {
            modifyChildren(of: Array(path.dropLast())) { $0.insert(layer, at: path.last! + 1) }
        } else {
            layers.append(layer)
        }
        activeLayerID = layer.id
    }

    @discardableResult
    public mutating func duplicateActiveLayer() -> Layer? {
        guard let path = path(of: activeLayerID), let original = layer(at: path) else { return nil }
        let copy = original.duplicated(name: original.name + " copy")
        modifyChildren(of: Array(path.dropLast())) { $0.insert(copy, at: path.last! + 1) }
        activeLayerID = copy.id
        return copy
    }

    public mutating func deleteActiveLayer() {
        guard let path = path(of: activeLayerID) else { return }
        let parent = Array(path.dropLast())
        let i = path.last!
        modifyChildren(of: parent) { $0.remove(at: i) }
        let siblings = children(of: parent)
        if !siblings.isEmpty {
            activeLayerID = siblings[max(0, i - 1)].id
        } else if !parent.isEmpty {
            activeLayerID = layer(at: parent)?.id
        } else {
            activeLayerID = nil
        }
    }

    /// Moves the active layer by `delta` positions among its siblings (positive = up).
    @discardableResult
    public mutating func moveActiveLayer(by delta: Int) -> Bool {
        guard let path = path(of: activeLayerID) else { return false }
        let parent = Array(path.dropLast())
        let i = path.last!
        let count = children(of: parent).count
        let target = min(max(i + delta, 0), count - 1)
        guard target != i else { return false }
        modifyChildren(of: parent) { list in
            let layer = list.remove(at: i)
            list.insert(layer, at: target)
        }
        return true
    }

    /// Removes a layer (and its subtree) and returns it.
    @discardableResult
    public mutating func removeLayer(_ id: UUID) -> Layer? {
        guard let path = path(of: id), let layer = layer(at: path) else { return nil }
        modifyChildren(of: Array(path.dropLast())) { $0.remove(at: path.last!) }
        return layer
    }

    /// Moves `id` so it sits directly above `target` in target's parent, or into
    /// the bottom of the root when `target` is nil.
    public mutating func moveLayer(_ id: UUID, above target: UUID?) {
        guard id != target else { return }
        if let target, let moving = layer(id: id), moving.subtree.contains(where: { $0.id == target }) {
            return  // can't move a group into itself
        }
        guard let moving = removeLayer(id) else { return }
        if let target, let tp = path(of: target) {
            modifyChildren(of: Array(tp.dropLast())) { $0.insert(moving, at: tp.last! + 1) }
        } else {
            layers.insert(moving, at: 0)
        }
    }

    /// Moves `id` to the top of `group`'s children.
    public mutating func moveLayer(_ id: UUID, intoTopOf group: UUID) {
        guard id != group, let moving = layer(id: id),
              !moving.subtree.contains(where: { $0.id == group }) else { return }
        removeLayer(id)
        guard let gp = path(of: group) else { return }
        modifyChildren(of: gp) { $0.append(moving) }
    }

    /// Wraps the active layer in a new group. Returns the group's id.
    @discardableResult
    public mutating func groupActiveLayer(name: String) -> UUID? {
        guard let path = path(of: activeLayerID), let layer = layer(at: path) else { return nil }
        let group = Layer(name: name, blendMode: .passThrough, content: .group(LayerGroup(children: [layer])))
        modifyChildren(of: Array(path.dropLast())) { $0[path.last!] = group }
        activeLayerID = group.id
        return group.id
    }

    /// Replaces the active group with its children.
    public mutating func ungroupActiveLayer() {
        guard let path = path(of: activeLayerID), let group = layer(at: path), group.isGroup else { return }
        let kids = group.children
        modifyChildren(of: Array(path.dropLast())) { $0.replaceSubrange(path.last!...path.last!, with: kids) }
        activeLayerID = kids.last?.id
    }

    /// The layer a clipped layer at `path` clips to (nearest non-clipped sibling below).
    public func clipBase(for path: LayerPath) -> Layer? {
        let siblings = children(of: Array(path.dropLast()))
        var i = path.last! - 1
        while i >= 0 {
            if !siblings[i].isClipped { return siblings[i] }
            i -= 1
        }
        return nil
    }
}
