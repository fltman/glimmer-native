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
        CommandDescriptor(.toggleLayersPanel, "Show/Hide Layers", category: .view,
                          shortcut: KeyShortcut("l", [.command, .option]), keywords: ["panel", "inspector"]),

        CommandDescriptor(.placeImage, "Place Image…", category: .file,
                          shortcut: KeyShortcut("p", [.command, .option]), keywords: ["import", "open", "layer"]),
        CommandDescriptor(.export, "Export…", category: .file,
                          shortcut: KeyShortcut("w", [.command, .option, .shift]),
                          keywords: ["png", "jpeg", "heic", "tiff", "save as"]),

        CommandDescriptor(.newLayer, "New Layer", category: .layer,
                          shortcut: KeyShortcut("n", [.command, .shift]), keywords: ["add"]),
        CommandDescriptor(.duplicateLayer, "Duplicate Layer", category: .layer,
                          shortcut: KeyShortcut("j"), keywords: ["copy"]),
        CommandDescriptor(.deleteLayer, "Delete Layer", category: .layer, keywords: ["remove"]),
        CommandDescriptor(.bringLayerForward, "Bring Forward", category: .layer,
                          shortcut: KeyShortcut("]"), keywords: ["arrange", "up"]),
        CommandDescriptor(.sendLayerBackward, "Send Backward", category: .layer,
                          shortcut: KeyShortcut("["), keywords: ["arrange", "down"]),
        CommandDescriptor(.bringLayerToFront, "Bring to Front", category: .layer,
                          shortcut: KeyShortcut("]", [.command, .shift]), keywords: ["arrange", "top"]),
        CommandDescriptor(.sendLayerToBack, "Send to Back", category: .layer,
                          shortcut: KeyShortcut("[", [.command, .shift]), keywords: ["arrange", "bottom"]),
    ])
}
