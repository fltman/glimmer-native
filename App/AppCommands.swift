import GlimmerCore
import SwiftUI

/// Builds menus from the command registry and routes them to the focused
/// window's editor session.
struct GlimmerCommands: Commands {
    @FocusedValue(\.editorSession) private var session

    private let registry = CommandRegistry.standard

    var body: some Commands {
        CommandGroup(replacing: .importExport) {
            items(registry.descriptors(in: .file))
        }
        CommandGroup(before: .toolbar) {
            items(registry.descriptors(in: .view))
            Divider()
        }
        CommandMenu("Layer") {
            items(registry.descriptors(in: .layer))
        }
    }

    @ViewBuilder
    private func items(_ commands: [CommandDescriptor]) -> some View {
        ForEach(commands) { command in
            Button(command.title) {
                session?.perform(command.id)
            }
            .keyboardShortcut(command.shortcut?.swiftUI)
            .disabled(!(session?.canPerform(command.id) ?? false))
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
