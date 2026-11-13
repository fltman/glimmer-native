import GlimmerCore
import SwiftUI

/// Builds the View menu from the command registry and routes it to the
/// focused window's canvas.
struct ViewMenuCommands: Commands {
    @FocusedValue(\.canvasController) private var canvas

    var body: some Commands {
        CommandGroup(before: .toolbar) {
            ForEach(CommandRegistry.standard.descriptors(in: .view)) { command in
                Button(command.title) {
                    canvas?.perform(command.id)
                }
                .keyboardShortcut(command.shortcut?.swiftUI)
                .disabled(!(canvas?.canPerform(command.id) ?? false))
            }
            Divider()
        }
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
