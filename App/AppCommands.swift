import AppKit
import GlimmerCore
import SwiftUI

/// Builds menus from the command registry and routes them to the focused
/// window's editor session.
struct GlimmerCommands: Commands {
    @FocusedValue(\.editorSession) private var session
    @Environment(\.newDocument) private var newDocument

    private let registry = CommandRegistry.standard

    private static func send(_ action: String) {
        NSApp.sendAction(NSSelectorFromString(action), to: nil, from: nil)
    }

    var body: some Commands {
        let _ = DocumentOpener.shared.newDocumentAction = newDocument
        CommandGroup(replacing: .importExport) {
            items(registry.descriptors(in: .file))
        }
        // Save, rebuilt so an image handed over by Flimmer or Jämmer saves back from the
        // menu and ⌘S alike. Otherwise these are the document's own actions, sent down the
        // responder chain to it.
        CommandGroup(replacing: .saveItem) {
            // Close lives in this group too.
            Button("Close") { NSApp.keyWindow?.performClose(nil) }
                .keyboardShortcut("w")
            if let link = session?.linkedImage {
                Button("Save Back to \(link.fileName)") { session?.saveLinkedImage() }
                    .keyboardShortcut("s")
                Button("Save a Glimmer Copy…") { session?.saveGlimmerCopy() }
                    .keyboardShortcut("s", modifiers: [.command, .shift])
            } else {
                Button("Save") { Self.send("saveDocument:") }
                    .keyboardShortcut("s")
                Button("Duplicate") { Self.send("duplicateDocument:") }
                    .keyboardShortcut("s", modifiers: [.command, .shift])
                Button("Rename…") { Self.send("renameDocument:") }
                Button("Move To…") { Self.send("moveDocument:") }
                Menu("Revert To") {
                    Button("Last Saved Version") { Self.send("revertDocumentToSaved:") }
                    Button("Browse All Versions…") { Self.send("browseDocumentVersions:") }
                }
            }
        }
        // The system items read just "Undo"/"Redo"; these name the step (from the
        // document's history) and still go through the responder chain, so text
        // fields keep their own undo.
        CommandGroup(replacing: .undoRedo) {
            let editingText = NSApp.keyWindow?.firstResponder is NSText
            let document = session?.document
            let index = document?.historyIndex ?? 0, history = document?.history ?? []
            Button(editingText || index == 0 ? String(localized: "Undo")
                   : String(localized: "Undo \(String(localized: String.LocalizationValue(history[index - 1])))")) {
                NSApp.sendAction(Selector(("undo:")), to: nil, from: nil)
            }
            .keyboardShortcut("z", modifiers: .command)
            .disabled(!editingText && index == 0)
            Button(editingText || index >= history.count ? String(localized: "Redo")
                   : String(localized: "Redo \(String(localized: String.LocalizationValue(history[index])))")) {
                NSApp.sendAction(Selector(("redo:")), to: nil, from: nil)
            }
            .keyboardShortcut("z", modifiers: [.command, .shift])
            .disabled(!editingText && index >= history.count)
        }
        CommandGroup(after: .pasteboard) {
            Divider()
            items([.fillForeground, .fillBackground, .fillPattern])
            #if GLIMMER_HEAL
            items([.healSelection])
            #endif
            Divider()
            items([.copyImageText])
        }
        CommandGroup(before: .toolbar) {
            items(registry.descriptors(in: .view).filter { ![.toggleRulers, .toggleGrid, .toggleSnap, .toggleNavigator, .toggleClassicLayout, .hideInterface].contains($0.id) })
            Divider()
            toggle(.hideInterface)
            toggle(.toggleClassicLayout)
            toggle(.toggleNavigator)
            toggle(.toggleRulers)
            toggle(.toggleGrid)
            toggle(.toggleSnap)
            Divider()
        }
        CommandMenu("Image") {
            Menu("Adjustments") {
                items(AdjustmentKind.allCases.map { .newAdjustment($0) })
            }
            items([.autoEnhance, .autoColor, .autoStraighten])
            Divider()
            items([.imageSize, .canvasSize])
            Divider()
            items([.freeTransform, .crop, .suggestCrop, .straightenDocument])
            Divider()
            items([.rotateRight, .rotateLeft, .rotate180, .flipHorizontal, .flipVertical])
            Divider()
            toggle(.toggleGammaBlending)
        }
        CommandMenu("Filter") {
            items([.repeatFilter])
            Divider()
            items([.liquify])
            Divider()
            ForEach(["Blur", "Sharpen", "Noise", "Pixelate", "Stylize", "Lens"], id: \.self) { group in
                Menu(LocalizedStringKey(group)) { items(FilterKind.allCases.filter { $0.group == group }.map { .filter($0) }) }
            }
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
            items([.duplicateLayer, .layerViaCopy, .deleteLayer])
            Divider()
            items([.groupLayers, .ungroupLayers])
            Menu("Arrange") { items([.bringLayerToFront, .bringLayerForward, .sendLayerBackward, .sendLayerToBack]) }
            Divider()
            toggle(.toggleClipping)
            Menu("Layer Mask") {
                items([.addMaskRevealAll, .addMaskHideAll])
                Divider()
                toggle(.toggleMask)
                toggle(.editMask)
                items([.deleteMask])
            }
            Menu("Smart Objects") { items([.convertToSmartObject]) }
            items([.textToLayers])
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
            Button(LocalizedStringKey(command.title)) {
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
        return Toggle(LocalizedStringKey(command.title), isOn: Binding(
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
