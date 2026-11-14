import GlimmerCore
import SwiftUI
import UniformTypeIdentifiers

/// A row in the flattened, top-down layer tree.
struct LayerRowItem: Identifiable {
    let layer: Layer
    let depth: Int
    var id: UUID { layer.id }
}

struct LayersPanel: View {
    @Bindable var session: EditorSession

    /// Top-down rows, descending into expanded groups.
    private var rows: [LayerRowItem] {
        func walk(_ layers: [Layer], depth: Int) -> [LayerRowItem] {
            layers.reversed().flatMap { layer -> [LayerRowItem] in
                var out = [LayerRowItem(layer: layer, depth: depth)]
                if case .group(let g) = layer.content, g.isExpanded {
                    out += walk(g.children, depth: depth + 1)
                }
                return out
            }
        }
        return walk(session.state.layers, depth: 0)
    }

    var body: some View {
        VStack(spacing: 0) {
            if let layer = session.activeLayer, PropertiesPanel.hasProperties(layer) {
                ScrollView {
                    PropertiesPanel(session: session, layer: layer)
                        .padding(10)
                }
                .frame(maxHeight: 340)
                .fixedSize(horizontal: false, vertical: true)
                Divider()
            }
            LayerPropertiesBar(session: session)
                .padding(10)
            Divider()
            layerList
            Divider()
            footer
        }
        .navigationTitle("Layers")
    }

    private var layerList: some View {
        let rows = rows
        return List(selection: Binding(
            get: { session.state.activeLayerID },
            set: { session.setActiveLayer($0) }
        )) {
            ForEach(rows) { row in
                LayerRow(item: row, session: session)
                    .tag(row.id)
                    .contextMenu { contextMenu(for: row.layer) }
                    .dropDestination(for: String.self) { ids, _ in
                        guard let id = ids.first.flatMap(UUID.init(uuidString:)), row.layer.isGroup else { return false }
                        session.moveLayer(id, intoGroup: row.id)
                        return true
                    }
            }
            .onMove { source, destination in
                guard let from = source.first else { return }
                let moving = rows[from].id
                // Rows are top-down: landing before row d means sitting directly above it.
                let target = destination < rows.count ? rows[destination].id : nil
                if target != moving { session.moveLayer(moving, above: target) }
            }
        }
        .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
        .overlay {
            if session.state.layers.isEmpty {
                ContentUnavailableView("No Layers", systemImage: "square.3.layers.3d.slash",
                                       description: Text("Add a layer or drop an image on the canvas."))
            }
        }
    }

    @ViewBuilder
    private func contextMenu(for layer: Layer) -> some View {
        Button("Duplicate Layer") { activate(layer); session.perform(.duplicateLayer) }
        Button(layer.isGroup ? "Merge Group" : "Rasterize Layer") { activate(layer); session.perform(.rasterizeLayer) }
            .disabled(layer.isRaster || layer.isAdjustment)
        Button("Convert to Smart Object") { activate(layer); session.perform(.convertToSmartObject) }
            .disabled(!layer.isRaster && !layer.isText)
        Divider()
        Button(layer.isClipped ? "Release Clipping Mask" : "Create Clipping Mask") {
            activate(layer); session.perform(.toggleClipping)
        }
        if layer.mask == nil {
            Button("Add Layer Mask") { activate(layer); session.perform(.addMaskRevealAll) }
        } else {
            Button(layer.mask?.isEnabled == true ? "Disable Layer Mask" : "Enable Layer Mask") {
                activate(layer); session.perform(.toggleMask)
            }
            Button("Delete Layer Mask") { activate(layer); session.perform(.deleteMask) }
        }
        Button("Layer Style…") { activate(layer); session.perform(.layerStyle) }
        Divider()
        Button("Delete Layer", role: .destructive) { activate(layer); session.perform(.deleteLayer) }
    }

    private func activate(_ layer: Layer) {
        session.setActiveLayer(layer.id)
    }

    /// Labelled buttons, as in the web app's layer panel.
    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                textButton("+ Layer", .newLayer, prominent: true)
                textButton("Duplicate", .duplicateLayer)
                footerButton("arrow.up", "Bring Forward", .bringLayerForward)
                footerButton("arrow.down", "Send Backward", .sendLayerBackward)
                textButton("Group", .groupLayers)
            }
            HStack(spacing: 6) {
                textButton("+ Group", .newGroup)
                textButton("+ Mask", .addMaskRevealAll)
                Menu {
                    ForEach(AdjustmentKind.allCases, id: \.self) { kind in
                        Button(LocalizedStringKey(kind.title), systemImage: kind.symbolName) { session.perform(.newAdjustment(kind)) }
                    }
                    Divider()
                    Button("Solid Color Fill") { session.perform(.newSolidFill) }
                    Button("Gradient Fill") { session.perform(.newGradientFill) }
                    Button("Pattern Fill") { session.perform(.newPatternFill) }
                } label: {
                    Image(systemName: "circle.lefthalf.filled")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .frame(width: 30, height: 26)
                .background(Theme.raised, in: .rect(cornerRadius: 6))
                .help("New Adjustment or Fill Layer")
                footerButton("fx", "Layer Style", .layerStyle)
                Spacer()
                textButton("Delete", .deleteLayer)
            }
        }
        .padding(10)
    }

    private func textButton(_ title: String, _ id: CommandID, prominent: Bool = false) -> some View {
        Button {
            session.perform(id)
        } label: {
            Text(LocalizedStringKey(title))
                .font(.callout)
                .padding(.horizontal, 9)
                .frame(height: 26)
                .background(prominent ? Theme.accent : Theme.raised, in: .rect(cornerRadius: 6))
                .foregroundStyle(prominent ? Color.white : Theme.ink)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(!session.canPerform(id))
        .opacity(session.canPerform(id) ? 1 : 0.45)
    }

    private func footerButton(_ symbol: String, _ title: String, _ id: CommandID) -> some View {
        Button {
            session.perform(id)
        } label: {
            Image(systemName: symbol)
                .frame(width: 30, height: 26)
                .background(Theme.raised, in: .rect(cornerRadius: 6))
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .opacity(session.canPerform(id) ? 1 : 0.45)
        .disabled(!session.canPerform(id))
        .help(Text(LocalizedStringKey(title)))
        .accessibilityLabel(Text(LocalizedStringKey(title)))
    }
}

/// Blend mode and opacity of the active layer.
private struct LayerPropertiesBar: View {
    @Bindable var session: EditorSession

    var body: some View {
        let layer = session.activeLayer
        VStack(alignment: .leading, spacing: 8) {
            Picker("Blend Mode", selection: Binding(
                get: { layer?.blendMode ?? .normal },
                set: { session.setBlendMode($0) }
            )) {
                if layer?.isGroup == true {
                    Text(LocalizedStringKey(GlimmerCore.BlendMode.passThrough.title)).tag(GlimmerCore.BlendMode.passThrough)
                    Divider()
                }
                ForEach(Array(GlimmerCore.BlendMode.menuGroups.enumerated()), id: \.offset) { index, group in
                    if index > 0 { Divider() }
                    ForEach(group, id: \.self) { mode in Text(LocalizedStringKey(mode.title)).tag(mode) }
                }
            }
            .labelsHidden()

            HStack {
                Text("Opacity")
                    .foregroundStyle(.secondary)
                Slider(
                    value: Binding(
                        get: { (layer?.opacity ?? 1) * 100 },
                        set: { session.setOpacity($0 / 100) }
                    ),
                    in: 0...100,
                    onEditingChanged: { editing in
                        if !editing { session.commitLiveEdit() }
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
    let item: LayerRowItem
    let session: EditorSession

    @State private var isRenaming = false
    @State private var draftName = ""
    @FocusState private var nameFocused: Bool

    private var layer: Layer { item.layer }

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            mainRow
            if case .smart(let smart) = layer.content, !smart.filters.isEmpty {
                smartFilterList(smart.filters)
            }
        }
    }

    @ViewBuilder private func smartFilterList(_ filters: [SmartFilter]) -> some View {
        Text("Smart Filters").font(.caption).foregroundStyle(.secondary).padding(.leading, 64)
        ForEach(Array(filters.enumerated()), id: \.element.id) { i, f in
            HStack(spacing: 6) {
                Button {
                    session.setSmartFilterEnabled(layerID: layer.id, index: i, !f.isEnabled)
                } label: {
                    Image(systemName: f.isEnabled ? "eye" : "eye.slash").font(.caption)
                        .foregroundStyle(f.isEnabled ? .secondary : .tertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(f.isEnabled ? "Hide" : "Show"))
                Text(LocalizedStringKey(f.settings.kind.title))
                    .font(.callout)
                    .foregroundStyle(f.isEnabled ? .primary : .tertiary)
                Spacer()
                Button {
                    session.editSmartFilter(layerID: layer.id, index: i)
                } label: {
                    Image(systemName: "slider.horizontal.3").font(.caption)
                }
                .buttonStyle(.plain)
                .help("Edit the filter settings")
            }
            .padding(.leading, 64)
            .contentShape(.rect)
            .onTapGesture(count: 2) { session.editSmartFilter(layerID: layer.id, index: i) }
            .contextMenu {
                Button("Edit…") { session.editSmartFilter(layerID: layer.id, index: i) }
                Button("Delete Smart Filter", role: .destructive) { session.deleteSmartFilter(layerID: layer.id, index: i) }
            }
        }
    }

    private var mainRow: some View {
        HStack(spacing: 6) {
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

            Color.clear.frame(width: CGFloat(item.depth) * 14, height: 1)

            if case .group(let g) = layer.content {
                Button {
                    session.setExpanded(layer.id, !g.isExpanded)
                } label: {
                    Image(systemName: "chevron.right")
                        .rotationEffect(.degrees(g.isExpanded ? 90 : 0))
                        .font(.caption.weight(.semibold))
                        .frame(width: 12)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(g.isExpanded ? "Collapse \(layer.name)" : "Expand \(layer.name)")
            }
            if layer.isClipped {
                Image(systemName: "arrow.turn.left.down")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help("Clipped to the layer below")
            }

            let isActive = session.state.activeLayerID == layer.id
            LayerIcon(layer: layer, thumbnail: session.thumbnails[layer.id])
                .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(Color.accentColor, lineWidth: 2)
                    .opacity(isActive && layer.mask != nil && !session.editingMask ? 1 : 0))
                .onTapGesture {
                    session.setActiveLayer(layer.id)
                    session.editingMask = false
                }
            if let mask = layer.mask {
                Thumbnail(image: session.maskThumbnails[layer.id], checker: false)
                    .opacity(mask.isEnabled ? 1 : 0.35)
                    .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(Color.accentColor, lineWidth: 2)
                        .opacity(isActive && session.editingMask ? 1 : 0))
                    .onTapGesture {
                        session.setActiveLayer(layer.id)
                        session.editingMask = true
                    }
                    .overlay {
                        if !mask.isEnabled {
                            Image(systemName: "xmark").foregroundStyle(.red).font(.caption.bold())
                        }
                    }
                    .help(mask.isEnabled ? "Layer mask" : "Layer mask (disabled)")
            }

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
                if !detail.isEmpty {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .opacity(layer.isVisible ? 1 : 0.5)
            Spacer(minLength: 0)
            if layer.effects.hasEnabled {
                Text("fx").font(.caption.italic().bold()).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
        .draggable(layer.id.uuidString)
        .contextMenu {
            Button("Rename…", action: startRename)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityDescription)
        .accessibilityAddTraits(session.state.activeLayerID == layer.id ? .isSelected : [])
        .accessibilityAction(named: layer.isVisible ? "Hide" : "Show") { session.setVisibility(layer.id, !layer.isVisible) }
        .accessibilityAction(named: "Rename", startRename)
        .accessibilityAction(named: "Select") { session.setActiveLayer(layer.id) }
    }

    private var accessibilityDescription: String {
        var parts = [layer.name]
        if !detail.isEmpty { parts.append(detail) }
        if !layer.isVisible { parts.append(String(localized: "hidden")) }
        if layer.mask != nil { parts.append(String(localized: "has mask")) }
        if layer.isClipped { parts.append(String(localized: "clipped")) }
        if layer.effects.hasEnabled { parts.append(String(localized: "has layer style")) }
        return parts.joined(separator: ", ")
    }

    private var detail: String {
        var parts: [String] = []
        if layer.blendMode != .normal && layer.blendMode != .passThrough { parts.append(layer.blendMode.title) }
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

/// Thumbnail for pixel layers, a symbol for everything else.
private struct LayerIcon: View {
    let layer: Layer
    let thumbnail: CGImage?

    var body: some View {
        switch layer.content {
        case .raster:
            Thumbnail(image: thumbnail)
        case .smart:
            Thumbnail(image: thumbnail)
                .overlay(alignment: .bottomTrailing) {
                    Image(systemName: "doc.badge.gearshape")
                        .font(.system(size: 9))
                        .padding(1)
                        .background(.background, in: .rect(cornerRadius: 2))
                }
                .help("Smart object")
        case .group:
            symbol("folder")
        case .adjustment(let a):
            symbol(a.kind.symbolName)
        case .fill(let fill):
            switch fill {
            case .solid(let c):
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color(.sRGB, red: c.r, green: c.g, blue: c.b))
                    .frame(width: 40, height: 30)
                    .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(.separator))
            case .gradient(let g):
                RoundedRectangle(cornerRadius: 3)
                    .fill(LinearGradient(stops: g.stops.map {
                        .init(color: Color(.sRGB, red: $0.color.r, green: $0.color.g, blue: $0.color.b, opacity: $0.opacity),
                              location: $0.position)
                    }, startPoint: .leading, endPoint: .trailing))
                    .frame(width: 40, height: 30)
                    .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(.separator))
            case .pattern:
                symbol("square.grid.3x3")
            }
        case .text:
            symbol("textformat")
        }
    }

    private func symbol(_ name: String) -> some View {
        Image(systemName: name)
            .font(.system(size: 15))
            .foregroundStyle(.secondary)
            .frame(width: 40, height: 30)
    }
}

struct Thumbnail: View {
    let image: CGImage?
    var checker = true

    var body: some View {
        ZStack {
            if checker { Checkerboard() } else { Color.black }
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
