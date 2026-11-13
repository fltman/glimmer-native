import GlimmerCore
import SwiftUI

/// Builds menus from the command registry and routes them to the focused
/// window's editor session.
struct GlimmerCommands: Commands {
    @FocusedValue(\.editorSession) private var session
    @Environment(\.newDocument) private var newDocument

    private let registry = CommandRegistry.standard

    var body: some Commands {
        let _ = DocumentOpener.shared.newDocumentAction = newDocument
        CommandGroup(replacing: .importExport) {
            items(registry.descriptors(in: .file))
        }
        CommandGroup(before: .toolbar) {
            items(registry.descriptors(in: .view).filter { ![.toggleRulers, .toggleGrid, .toggleSnap].contains($0.id) })
            Divider()
            toggle(.toggleRulers)
            toggle(.toggleGrid)
            toggle(.toggleSnap)
            Divider()
        }
        CommandMenu("Image") {
            Menu("Adjustments") {
                items(AdjustmentKind.allCases.map { .newAdjustment($0) })
            }
            items([.freeTransform, .crop])
            Divider()
            toggle(.toggleGammaBlending)
        }
        CommandMenu("Select") {
            items(registry.descriptors(in: .select))
        }
        CommandMenu("AI") {
            items(registry.descriptors(in: .ai))
        }
        CommandMenu("Layer") {
            Menu("New") { items([.newLayer, .newGroup]) }
            Menu("New Adjustment Layer") { items(AdjustmentKind.allCases.map { .newAdjustment($0) }) }
            Menu("New Fill Layer") { items([.newSolidFill, .newGradientFill, .newPatternFill]) }
            Divider()
            items([.duplicateLayer, .deleteLayer])
            Divider()
            items([.groupLayers, .ungroupLayers])
            Menu("Arrange") { items([.bringLayerToFront, .bringLayerForward, .sendLayerBackward, .sendLayerToBack]) }
            Divider()
            toggle(.toggleClipping)
            Menu("Layer Mask") {
                items([.addMaskRevealAll, .addMaskHideAll])
                Divider()
                toggle(.toggleMask)
                items([.deleteMask])
            }
            Menu("Smart Objects") { items([.convertToSmartObject]) }
            items([.rasterizeLayer])
            Divider()
            items([.layerStyle])
        }
    }

    @ViewBuilder
    private func items(_ ids: [CommandID]) -> some View {
        items(ids.compactMap { registry.descriptor(for: $0) })
    }

    @ViewBuilder
    private func items(_ commands: [CommandDescriptor]) -> some View {
        ForEach(commands.filter { !$0.isSystemProvided }) { command in
            Button(command.title) {
                session?.perform(command.id)
            }
            // ⌘A stays with Edit › Select All so text fields keep it; the canvas answers selectAll:.
            .keyboardShortcut(command.id == .selectAll ? nil : command.shortcut?.swiftUI)
            .disabled(!(session?.canPerform(command.id) ?? false))
        }
    }

    /// A menu item with a checkmark.
    private func toggle(_ id: CommandID) -> some View {
        let command = registry.descriptor(for: id)!
        return Toggle(command.title, isOn: Binding(
            get: { session?.isChecked(id) ?? false },
            set: { _ in session?.perform(id) }
        ))
        .keyboardShortcut(command.shortcut?.swiftUI)
        .disabled(!(session?.canPerform(id) ?? false))
    }
}

extension KeyShortcut {
    var swiftUI: KeyboardShortcut {
        var mods: EventModifiers = []
        if modifiers.contains(.command) { mods.insert(.command) }
        if modifiers.contains(.shift) { mods.insert(.shift) }
        if modifiers.contains(.option) { mods.insert(.option) }
        if modifiers.contains(.control) { mods.insert(.control) }
        return KeyboardShortcut(KeyEquivalent(key), modifiers: mods)
    }
}
