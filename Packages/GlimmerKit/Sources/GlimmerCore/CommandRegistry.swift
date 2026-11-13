/// Stable identifier for a user-facing command.
///
/// One registry drives the menu bar, the ⌘K palette, the omnibar, keyboard
/// shortcuts and (later) the AI agent's tool list.
public struct CommandID: RawRepresentable, Hashable, Sendable, ExpressibleByStringLiteral {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { self.rawValue = value }
}

public enum CommandCategory: String, Sendable, CaseIterable {
    case file, edit, view, image, layer, select, filter, ai
}

public struct KeyShortcut: Hashable, Sendable {
    public struct Modifiers: OptionSet, Hashable, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        public static let command = Modifiers(rawValue: 1 << 0)
        public static let shift = Modifiers(rawValue: 1 << 1)
        public static let option = Modifiers(rawValue: 1 << 2)
        public static let control = Modifiers(rawValue: 1 << 3)
    }

    public var key: Character
    public var modifiers: Modifiers

    public init(_ key: Character, _ modifiers: Modifiers = .command) {
        self.key = key
        self.modifiers = modifiers
    }
}

public struct CommandDescriptor: Identifiable, Sendable {
    public let id: CommandID
    public let title: String
    public let category: CommandCategory
    public let shortcut: KeyShortcut?
    /// Extra search terms for the palette.
    public let keywords: [String]
    /// Provided by the system (e.g. Undo in the Edit menu); not added to our menus.
    public let isSystemProvided: Bool

    public init(
        _ id: CommandID,
        _ title: String,
        category: CommandCategory,
        shortcut: KeyShortcut? = nil,
        keywords: [String] = [],
        isSystemProvided: Bool = false
    ) {
        self.id = id
        self.title = title
        self.category = category
        self.shortcut = shortcut
        self.keywords = keywords
        self.isSystemProvided = isSystemProvided
    }
}

extension CommandID {
    public static let undo: CommandID = "edit.undo"
    public static let redo: CommandID = "edit.redo"

    public static let zoomIn: CommandID = "view.zoomIn"
    public static let zoomOut: CommandID = "view.zoomOut"
    public static let fitToWindow: CommandID = "view.fit"
    public static let actualSize: CommandID = "view.actualSize"
    public static let rotateViewLeft: CommandID = "view.rotateLeft"
    public static let rotateViewRight: CommandID = "view.rotateRight"
    public static let resetViewRotation: CommandID = "view.resetRotation"
    public static let toggleLayersPanel: CommandID = "view.toggleLayers"

    public static let placeImage: CommandID = "file.placeImage"
    public static let export: CommandID = "file.export"

    public static let newLayer: CommandID = "layer.new"
    public static let duplicateLayer: CommandID = "layer.duplicate"
    public static let deleteLayer: CommandID = "layer.delete"
    public static let bringLayerForward: CommandID = "layer.forward"
    public static let sendLayerBackward: CommandID = "layer.backward"
    public static let bringLayerToFront: CommandID = "layer.front"
    public static let sendLayerToBack: CommandID = "layer.back"
    public static let newGroup: CommandID = "layer.newGroup"
    public static let groupLayers: CommandID = "layer.group"
    public static let ungroupLayers: CommandID = "layer.ungroup"
    public static let toggleClipping: CommandID = "layer.clip"
    public static let addMaskRevealAll: CommandID = "layer.mask.revealAll"
    public static let addMaskHideAll: CommandID = "layer.mask.hideAll"
    public static let toggleMask: CommandID = "layer.mask.toggle"
    public static let deleteMask: CommandID = "layer.mask.delete"
    public static let convertToSmartObject: CommandID = "layer.smart.convert"
    public static let rasterizeLayer: CommandID = "layer.rasterize"
    public static let layerStyle: CommandID = "layer.style"
    public static let toggleGammaBlending: CommandID = "image.gammaBlending"

    public static let selectAll: CommandID = "select.all"
    public static let deselect: CommandID = "select.none"
    public static let invertSelection: CommandID = "select.invert"
    public static let selectSubject: CommandID = "select.subject"
    public static let featherSelection: CommandID = "select.feather"
    public static let growSelection: CommandID = "select.grow"
    public static let shrinkSelection: CommandID = "select.shrink"
    public static let copy: CommandID = "edit.copy"
    public static let cut: CommandID = "edit.cut"
    public static let layerViaCopy: CommandID = "layer.viaCopy"
    public static let clearPixels: CommandID = "edit.clear"
    public static let freeTransform: CommandID = "edit.transform"
    public static let crop: CommandID = "image.crop"
    public static let flipHorizontal: CommandID = "image.flipHorizontal"
    public static let flipVertical: CommandID = "image.flipVertical"
    public static let rotateRight: CommandID = "image.rotateRight"
    public static let rotateLeft: CommandID = "image.rotateLeft"
    public static let rotate180: CommandID = "image.rotate180"
    public static let toggleRulers: CommandID = "view.rulers"
    public static let toggleGrid: CommandID = "view.grid"
    public static let toggleSnap: CommandID = "view.snap"
    public static let clearGuides: CommandID = "view.clearGuides"

    public static let aiGenerate: CommandID = "ai.generate"
    public static let aiEditImage: CommandID = "ai.edit"
    public static let aiGenerativeFill: CommandID = "ai.fill"
    public static let aiRemoveObject: CommandID = "ai.remove"
    public static let aiExpand: CommandID = "ai.expand"
    public static let aiRemoveBackground: CommandID = "ai.cutout"
    public static let aiColorMatch: CommandID = "ai.colorMatch"
    public static let showAssistant: CommandID = "ai.assistant"
    public static let aiRelight: CommandID = "ai.relight"
    public static let aiReflections: CommandID = "ai.reflections"
    public static let aiHarmonize: CommandID = "ai.harmonize"
    public static let aiUpscale: CommandID = "ai.upscale"
    public static let aiDistractions: CommandID = "ai.distractions"
    public static let aiPresets: CommandID = "ai.presets"
    public static let aiLensBlur: CommandID = "ai.lensBlur"

    public static func filter(_ kind: FilterKind) -> CommandID { CommandID(rawValue: "filter.\(kind.rawValue)") }
    public static let liquify: CommandID = "filter.liquify"
    public static let commandPalette: CommandID = "view.palette"
    public static let toggleNavigator: CommandID = "view.navigator"
    public static let toggleClassicLayout: CommandID = "view.classicLayout"
    public static let repeatFilter: CommandID = "filter.repeat"

    /// The filter for a `filter(_:)` id.
    public var filterKind: FilterKind? {
        guard rawValue.hasPrefix("filter.") else { return nil }
        return FilterKind(rawValue: String(rawValue.dropFirst("filter.".count)))
    }

    public static func newAdjustment(_ kind: AdjustmentKind) -> CommandID { CommandID(rawValue: "layer.adjustment.\(kind.rawValue)") }
    public static let newSolidFill: CommandID = "layer.fill.solid"
    public static let newGradientFill: CommandID = "layer.fill.gradient"
    public static let newPatternFill: CommandID = "layer.fill.pattern"

    /// The adjustment kind for a `newAdjustment` id.
    public var adjustmentKind: AdjustmentKind? {
        guard rawValue.hasPrefix("layer.adjustment.") else { return nil }
        return AdjustmentKind(rawValue: String(rawValue.dropFirst("layer.adjustment.".count)))
    }
}

public struct CommandRegistry: Sendable {
    public let descriptors: [CommandDescriptor]

    public init(_ descriptors: [CommandDescriptor]) {
        self.descriptors = descriptors
    }

    public func descriptor(for id: CommandID) -> CommandDescriptor? {
        descriptors.first { $0.id == id }
    }

    public func descriptors(in category: CommandCategory) -> [CommandDescriptor] {
        descriptors.filter { $0.category == category }
    }

    public static let standard = CommandRegistry([
        CommandDescriptor(.undo, "Undo", category: .edit,
                          shortcut: KeyShortcut("z"), isSystemProvided: true),
        CommandDescriptor(.redo, "Redo", category: .edit,
                          shortcut: KeyShortcut("z", [.command, .shift]), isSystemProvided: true),

        CommandDescriptor(.zoomIn, "Zoom In", category: .view,
                          shortcut: KeyShortcut("+"), keywords: ["magnify", "bigger"]),
        CommandDescriptor(.zoomOut, "Zoom Out", category: .view,
                          shortcut: KeyShortcut("-"), keywords: ["smaller"]),
        CommandDescriptor(.fitToWindow, "Fit on Screen", category: .view,
                          shortcut: KeyShortcut("0"), keywords: ["zoom", "fit"]),
        CommandDescriptor(.actualSize, "Actual Pixels (100%)", category: .view,
                          shortcut: KeyShortcut("1"), keywords: ["zoom", "100"]),
        CommandDescriptor(.rotateViewLeft, "Rotate View Left 15°", category: .view,
                          keywords: ["rotate", "canvas"]),
        CommandDescriptor(.rotateViewRight, "Rotate View Right 15°", category: .view,
                          keywords: ["rotate", "canvas"]),
        CommandDescriptor(.resetViewRotation, "Reset View Rotation", category: .view,
                          keywords: ["rotate", "straighten"]),
        CommandDescriptor(.toggleRulers, "Rulers", category: .view, shortcut: KeyShortcut("r"), keywords: ["ruler", "guides"]),
        CommandDescriptor(.toggleGrid, "Grid", category: .view, shortcut: KeyShortcut("'"), keywords: ["grid"]),
        CommandDescriptor(.toggleSnap, "Snap", category: .view, shortcut: KeyShortcut(";", [.command, .shift]), keywords: ["snap"]),
        CommandDescriptor(.clearGuides, "Clear Guides", category: .view, keywords: ["guides", "remove"]),
        CommandDescriptor(.commandPalette, "Command Palette…", category: .view, shortcut: KeyShortcut("k"),
                          keywords: ["search", "omnibar", "find command", "ask"]),
        CommandDescriptor(.toggleClassicLayout, "Classic Layout", category: .view,
                          keywords: ["docked", "panels", "sidebar", "omni"]),
        CommandDescriptor(.toggleNavigator, "Navigator", category: .view, shortcut: KeyShortcut("n", [.command, .option]),
                          keywords: ["minimap", "overview", "zoom"]),
        CommandDescriptor(.toggleLayersPanel, "Show/Hide Layers", category: .view,
                          shortcut: KeyShortcut("l", [.command, .option]), keywords: ["panel", "inspector"]),

        CommandDescriptor(.placeImage, "Place Image…", category: .file,
                          shortcut: KeyShortcut("p", [.command, .option]), keywords: ["import", "open", "layer"]),
        CommandDescriptor(.export, "Export…", category: .file,
                          shortcut: KeyShortcut("w", [.command, .option, .shift]),
                          keywords: ["png", "jpeg", "heic", "tiff", "save as"]),

        CommandDescriptor(.newLayer, "New Layer", category: .layer,
                          shortcut: KeyShortcut("n", [.command, .shift]), keywords: ["add"]),
        CommandDescriptor(.duplicateLayer, "Duplicate Layer", category: .layer, keywords: ["copy"]),
        CommandDescriptor(.deleteLayer, "Delete Layer", category: .layer, keywords: ["remove"]),
        CommandDescriptor(.bringLayerForward, "Bring Forward", category: .layer,
                          shortcut: KeyShortcut("]"), keywords: ["arrange", "up"]),
        CommandDescriptor(.sendLayerBackward, "Send Backward", category: .layer,
                          shortcut: KeyShortcut("["), keywords: ["arrange", "down"]),
        CommandDescriptor(.bringLayerToFront, "Bring to Front", category: .layer,
                          shortcut: KeyShortcut("]", [.command, .shift]), keywords: ["arrange", "top"]),
        CommandDescriptor(.sendLayerToBack, "Send to Back", category: .layer,
                          shortcut: KeyShortcut("[", [.command, .shift]), keywords: ["arrange", "bottom"]),
        CommandDescriptor(.newGroup, "New Group", category: .layer, keywords: ["folder"]),
        CommandDescriptor(.groupLayers, "Group Layer", category: .layer,
                          shortcut: KeyShortcut("g"), keywords: ["folder"]),
        CommandDescriptor(.ungroupLayers, "Ungroup", category: .layer,
                          shortcut: KeyShortcut("g", [.command, .shift])),
        CommandDescriptor(.toggleClipping, "Create/Release Clipping Mask", category: .layer,
                          shortcut: KeyShortcut("g", [.command, .option]), keywords: ["clip"]),
        CommandDescriptor(.addMaskRevealAll, "Add Layer Mask (Reveal All)", category: .layer, keywords: ["mask"]),
        CommandDescriptor(.addMaskHideAll, "Add Layer Mask (Hide All)", category: .layer, keywords: ["mask"]),
        CommandDescriptor(.toggleMask, "Enable/Disable Layer Mask", category: .layer, keywords: ["mask"]),
        CommandDescriptor(.deleteMask, "Delete Layer Mask", category: .layer, keywords: ["mask"]),
        CommandDescriptor(.convertToSmartObject, "Convert to Smart Object", category: .layer, keywords: ["smart"]),
        CommandDescriptor(.rasterizeLayer, "Rasterize Layer", category: .layer, keywords: ["flatten", "merge group"]),
        CommandDescriptor(.layerStyle, "Layer Style…", category: .layer,
                          keywords: ["effects", "fx", "shadow", "stroke", "glow", "overlay"]),
        CommandDescriptor(.newSolidFill, "Solid Color…", category: .layer, keywords: ["fill"]),
        CommandDescriptor(.newGradientFill, "Gradient…", category: .layer, keywords: ["fill"]),
        CommandDescriptor(.newPatternFill, "Pattern…", category: .layer, keywords: ["fill"]),
        CommandDescriptor(.selectAll, "All", category: .select, shortcut: KeyShortcut("a"), keywords: ["select all"]),
        CommandDescriptor(.deselect, "Deselect", category: .select, shortcut: KeyShortcut("d"), keywords: ["select none"]),
        CommandDescriptor(.invertSelection, "Inverse", category: .select,
                          shortcut: KeyShortcut("i", [.command, .shift]), keywords: ["invert selection"]),
        CommandDescriptor(.selectSubject, "Subject", category: .select,
                          keywords: ["select subject", "person", "object", "ai"]),
        CommandDescriptor(.featherSelection, "Feather…", category: .select, keywords: ["soften", "blur selection"]),
        CommandDescriptor(.growSelection, "Expand…", category: .select, keywords: ["grow", "dilate"]),
        CommandDescriptor(.shrinkSelection, "Contract…", category: .select, keywords: ["shrink", "erode"]),
        CommandDescriptor(.copy, "Copy", category: .edit, shortcut: KeyShortcut("c"), isSystemProvided: true),
        CommandDescriptor(.cut, "Cut", category: .edit, shortcut: KeyShortcut("x"), isSystemProvided: true),
        CommandDescriptor(.clearPixels, "Clear", category: .edit, keywords: ["delete pixels", "erase selection"],
                          isSystemProvided: true),
        CommandDescriptor(.layerViaCopy, "New Layer via Copy", category: .layer,
                          shortcut: KeyShortcut("j"), keywords: ["copy selection to layer"]),

        CommandDescriptor(.showAssistant, "Assistant", category: .ai,
                          shortcut: KeyShortcut("k", [.command, .shift]), keywords: ["chat", "ai", "prompt"]),
        CommandDescriptor(.aiGenerate, "Generate Image…", category: .ai, keywords: ["text to image", "create"]),
        CommandDescriptor(.aiEditImage, "Edit Image with Prompt…", category: .ai, keywords: ["describe", "change"]),
        CommandDescriptor(.aiGenerativeFill, "Generative Fill…", category: .ai, keywords: ["inpaint", "replace", "selection"]),
        CommandDescriptor(.aiRemoveObject, "Remove Object", category: .ai,
                          keywords: ["content-aware fill", "erase", "delete", "cleanup"]),
        CommandDescriptor(.aiExpand, "Expand…", category: .ai, keywords: ["outpaint", "extend", "uncrop"]),
        CommandDescriptor(.aiRemoveBackground, "Remove Background", category: .ai,
                          keywords: ["cutout", "mask", "subject"]),
        CommandDescriptor(.aiColorMatch, "Match Color…", category: .ai, keywords: ["grade", "transfer", "reference"]),
        CommandDescriptor(.aiRelight, "Relight…", category: .ai, keywords: ["light", "lighting", "shadow"]),
        CommandDescriptor(.aiReflections, "Remove Reflections…", category: .ai, keywords: ["glare", "glass", "window"]),
        CommandDescriptor(.aiHarmonize, "Harmonize Layer…", category: .ai, keywords: ["blend", "composite", "match lighting"]),
        CommandDescriptor(.aiUpscale, "Upscale…", category: .ai, keywords: ["enlarge", "super resolution", "enhance"]),
        CommandDescriptor(.aiDistractions, "Find Distractions…", category: .ai, keywords: ["cleanup", "clean up", "remove clutter"]),
        CommandDescriptor(.aiPresets, "Presets…", category: .ai, keywords: ["look", "grade", "filter", "style"]),
        CommandDescriptor(.aiLensBlur, "Lens Blur…", category: .ai, keywords: ["depth", "bokeh", "background blur", "portrait"]),

        CommandDescriptor(.freeTransform, "Free Transform", category: .image, shortcut: KeyShortcut("t"),
                          keywords: ["scale", "rotate", "resize layer"]),
        CommandDescriptor(.crop, "Crop", category: .image, keywords: ["trim", "canvas size"]),
        CommandDescriptor(.flipHorizontal, "Flip Horizontal", category: .image, keywords: ["mirror", "flip canvas", "reverse"]),
        CommandDescriptor(.flipVertical, "Flip Vertical", category: .image, keywords: ["mirror", "flip canvas", "upside down"]),
        CommandDescriptor(.rotateRight, "Rotate 90° Clockwise", category: .image, keywords: ["turn", "rotate image", "right"]),
        CommandDescriptor(.rotateLeft, "Rotate 90° Counterclockwise", category: .image, keywords: ["turn", "rotate image", "left"]),
        CommandDescriptor(.rotate180, "Rotate 180°", category: .image, keywords: ["turn", "rotate image", "upside down"]),
        CommandDescriptor(.toggleGammaBlending, "Blend Colors in Gamma Space", category: .image,
                          keywords: ["photoshop", "linear", "color space"]),
        CommandDescriptor(.repeatFilter, "Repeat Last Filter", category: .filter, shortcut: KeyShortcut("f", [.command, .control]),
                          keywords: ["again", "filter"]),
        CommandDescriptor(.liquify, "Liquify…", category: .filter, shortcut: KeyShortcut("x", [.command, .shift]),
                          keywords: ["warp", "push", "bloat", "pucker", "twirl", "reshape"]),
    ] + AdjustmentKind.allCases.map {
        CommandDescriptor(.newAdjustment($0), $0.title, category: .image, keywords: ["adjustment", "layer"])
    } + FilterKind.allCases.map {
        CommandDescriptor(.filter($0), $0.fields.isEmpty ? $0.title : "\($0.title)…", category: .filter,
                          keywords: ["filter", $0.group.lowercased()])
    })
}
