import GlimmerCore
import SwiftUI

struct LayersPanel: View {
    @Bindable var session: EditorSession

    private var layersTopDown: [Layer] { session.state.layers.reversed() }

    var body: some View {
        VStack(spacing: 0) {
            LayerPropertiesBar(session: session)
                .padding(10)
            Divider()
            List(selection: Binding(
                get: { session.state.activeLayerID },
                set: { session.setActiveLayer($0) }
            )) {
                ForEach(layersTopDown) { layer in
                    LayerRow(layer: layer, thumbnail: session.thumbnails[layer.id], session: session)
                        .tag(layer.id)
                        .contextMenu {
                            Button("Duplicate Layer") {
                                session.setActiveLayer(layer.id)
                                session.perform(.duplicateLayer)
                            }
                            Button("Delete Layer", role: .destructive) {
                                session.setActiveLayer(layer.id)
                                session.perform(.deleteLayer)
                            }
                        }
                }
                .onMove { session.moveLayers(fromDisplayed: $0, toDisplayed: $1) }
            }
            .listStyle(.sidebar)
            .overlay {
                if session.state.layers.isEmpty {
                    ContentUnavailableView("No Layers", systemImage: "square.3.layers.3d.slash",
                                           description: Text("Add a layer or drop an image on the canvas."))
                }
            }
            Divider()
            footer
        }
        .navigationTitle("Layers")
    }

    private var footer: some View {
        HStack(spacing: 2) {
            footerButton("plus", "New Layer", .newLayer)
            footerButton("plus.square.on.square", "Duplicate Layer", .duplicateLayer)
            Spacer()
            footerButton("chevron.up", "Bring Forward", .bringLayerForward)
            footerButton("chevron.down", "Send Backward", .sendLayerBackward)
            footerButton("trash", "Delete Layer", .deleteLayer)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }

    private func footerButton(_ symbol: String, _ title: String, _ id: CommandID) -> some View {
        Button {
            session.perform(id)
        } label: {
            Image(systemName: symbol).frame(width: 26, height: 22)
        }
        .buttonStyle(.borderless)
        .disabled(!session.canPerform(id))
        .help(title)
        .accessibilityLabel(title)
    }
}

/// Blend mode and opacity of the active layer.
private struct LayerPropertiesBar: View {
    @Bindable var session: EditorSession

    var body: some View {
        let layer = session.state.activeLayer
        VStack(alignment: .leading, spacing: 8) {
            Picker("Blend Mode", selection: Binding(
                get: { layer?.blendMode ?? .normal },
                set: { session.setBlendMode($0) }
            )) {
                ForEach(Array(GlimmerCore.BlendMode.menuGroups.enumerated()), id: \.offset) { index, group in
                    if index > 0 { Divider() }
                    ForEach(group, id: \.self) { mode in Text(mode.title).tag(mode) }
                }
            }
            .labelsHidden()

            HStack {
                Text("Opacity")
                    .foregroundStyle(.secondary)
                Slider(
                    value: Binding(
                        get: { (layer?.opacity ?? 1) * 100 },
                        set: { session.setOpacity($0 / 100, editing: true) }
                    ),
                    in: 0...100,
                    onEditingChanged: { editing in
                        if !editing { session.endOpacityEdit() }
                    }
                )
                Text("\(Int(((layer?.opacity ?? 1) * 100).rounded())) %")
                    .monospacedDigit()
                    .frame(width: 44, alignment: .trailing)
            }
            .font(.callout)
        }
        .disabled(layer == nil)
    }
}

private struct LayerRow: View {
    let layer: Layer
    let thumbnail: CGImage?
    let session: EditorSession

    @State private var isRenaming = false
    @State private var draftName = ""
    @FocusState private var nameFocused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Button {
                session.setVisibility(layer.id, !layer.isVisible)
            } label: {
                Image(systemName: layer.isVisible ? "eye" : "eye.slash")
                    .foregroundStyle(layer.isVisible ? .primary : .tertiary)
                    .frame(width: 18)
            }
            .buttonStyle(.plain)
            .help(layer.isVisible ? "Hide layer" : "Show layer")
            .accessibilityLabel(layer.isVisible ? "Hide \(layer.name)" : "Show \(layer.name)")

            Thumbnail(image: thumbnail)

            VStack(alignment: .leading, spacing: 1) {
                if isRenaming {
                    TextField("Name", text: $draftName)
                        .textFieldStyle(.roundedBorder)
                        .focused($nameFocused)
                        .onSubmit(finishRename)
                        .onExitCommand { isRenaming = false }
                        .onChange(of: nameFocused) { _, focused in if !focused { finishRename() } }
                } else {
                    Text(layer.name)
                        .lineLimit(1)
                        .onTapGesture(count: 2, perform: startRename)
                }
                if layer.blendMode != .normal || layer.opacity < 1 {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .opacity(layer.isVisible ? 1 : 0.5)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
        .contextMenu {
            Button("Rename…", action: startRename)
        }
    }

    private var detail: String {
        var parts: [String] = []
        if layer.blendMode != .normal { parts.append(layer.blendMode.title) }
        if layer.opacity < 1 { parts.append("\(Int((layer.opacity * 100).rounded())) %") }
        return parts.joined(separator: " · ")
    }

    private func startRename() {
        draftName = layer.name
        isRenaming = true
        nameFocused = true
    }

    private func finishRename() {
        guard isRenaming else { return }
        isRenaming = false
        session.rename(layer.id, to: draftName)
    }
}

private struct Thumbnail: View {
    let image: CGImage?

    var body: some View {
        ZStack {
            Checkerboard()
            if let image {
                Image(decorative: image, scale: 2)
                    .resizable()
                    .interpolation(.medium)
                    .aspectRatio(contentMode: .fit)
            }
        }
        .frame(width: 40, height: 30)
        .clipShape(.rect(cornerRadius: 3))
        .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(.separator))
    }
}

private struct Checkerboard: View {
    var body: some View {
        Canvas { context, size in
            let s: CGFloat = 5
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.white))
            for row in 0..<Int(ceil(size.height / s)) {
                for col in 0..<Int(ceil(size.width / s)) where (row + col) % 2 == 1 {
                    context.fill(Path(CGRect(x: CGFloat(col) * s, y: CGFloat(row) * s, width: s, height: s)),
                                 with: .color(Color(white: 0.8)))
                }
            }
        }
    }
}
