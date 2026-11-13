import GlimmerCore
import SwiftUI

/// A small bar that follows the selection: describe what to put there, remove
/// what's in it, or adjust the selection, without a trip to the menus.
struct SelectionBar: View {
    @Bindable var session: EditorSession
    let viewSize: CGSize

    @State private var prompt = ""
    @FocusState private var promptFocused: Bool

    static let showKey = "canvas.showSelectionBar"

    /// The selection's bounds in view coordinates (nil when there's nothing to show).
    private var anchor: CGRect? {
        guard let selection = session.state.selection, let b = selection.bounds(in: session.state.bounds) else { return nil }
        let t = session.canvas.transform
        let corners = [SIMD2(Double(b.x), Double(b.y)), SIMD2(Double(b.maxX), Double(b.y)),
                       SIMD2(Double(b.x), Double(b.maxY)), SIMD2(Double(b.maxX), Double(b.maxY))].map(t.viewPoint(fromDocument:))
        let xs = corners.map(\.x), ys = corners.map(\.y)
        return CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
    }

    private var isHidden: Bool {
        session.transformSession != nil || session.cropSession != nil || session.liquify != nil
            || session.filterDialog != nil || session.isPaletteOpen || session.editingText != nil
    }

    var body: some View {
        if !isHidden, let rect = anchor {
            let width = 430.0, height = 40.0
            // Below the selection when there's room, otherwise above, otherwise inside its bottom edge.
            let below = rect.maxY + 12 + height / 2
            let above = rect.minY - 12 - height / 2
            let y = below + height / 2 < viewSize.height - 56 ? below : (above - height / 2 > 56 ? above : viewSize.height - 56 - height)
            let x = min(max(rect.midX, width / 2 + 12), max(viewSize.width - width / 2 - 12, width / 2 + 12))
            bar
                .frame(width: width, height: height)
                .glassEffect(.regular, in: .capsule)
                .position(x: x, y: y)
                .transition(.opacity)
        }
    }

    private var bar: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles").foregroundStyle(.secondary)
            TextField("Describe what to add here…", text: $prompt)
                .textFieldStyle(.plain)
                .focused($promptFocused)
                .onSubmit(generate)
                .disabled(!session.ai.hasAPIKey)
            if !prompt.trimmingCharacters(in: .whitespaces).isEmpty {
                Button("Generate", action: generate).buttonStyle(.borderedProminent).controlSize(.small)
            } else {
                Button("Remove", systemImage: "eraser") {
                    session.ai.fill(mode: .remove, prompt: "", reference: nil)
                }
                .help(session.ai.hasAPIKey ? "Remove what's inside the selection" : "Add your OpenRouter key in Settings › AI")
                .disabled(!session.ai.hasAPIKey)
                Divider().frame(height: 18)
                Button("Invert", systemImage: "circle.righthalf.filled") { session.perform(.invertSelection) }
                    .help("Invert the selection")
                Button("Feather", systemImage: "circle.dotted") { session.perform(.featherSelection) }
                    .help("Feather the selection")
                Button("Deselect", systemImage: "xmark") { session.perform(.deselect) }
                    .help("Deselect (⌘D)")
            }
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .padding(.horizontal, 14)
    }

    private func generate() {
        let text = prompt.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        session.ai.fill(mode: .fill, prompt: text, reference: nil)
        prompt = ""
        promptFocused = false
    }
}
