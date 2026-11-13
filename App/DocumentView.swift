import GlimmerCore
import GlimmerRender
import GlimmerTools
import SwiftUI

struct DocumentView: View {
    @State private var session: EditorSession
    @Environment(\.undoManager) private var undoManager
    @AppStorage(Preferences.showOmnibarKey) private var showOmnibar = true

    init(document: GlimmerDocument) {
        _session = State(initialValue: EditorSession(document: document))
    }

    var body: some View {
        CanvasView(session: session)
            .overlay(alignment: .leading) {
                ToolPalette(session: session)
                    .padding(.leading, 12)
            }
            .overlay(alignment: .bottomLeading) {
                StatusPill(session: session)
                    .padding(12)
            }
            .overlay(alignment: .top) {
                ToolOptionsBar(session: session)
                    .padding(.top, 10)
            }
            .overlay(alignment: .bottomTrailing) {
                if session.showNavigator {
                    NavigatorView(session: session, canvas: session.canvas).padding(12)
                }
            }
            .overlay(alignment: .bottom) {
                if showOmnibar, session.liquify == nil, session.transformSession == nil, session.cropSession == nil {
                    Omnibar(session: session).padding(.bottom, 12)
                }
            }
            .overlay(alignment: .top) {
                if session.isPaletteOpen {
                    ZStack(alignment: .top) {
                        Color.black.opacity(0.001)
                            .onTapGesture { session.isPaletteOpen = false }
                        CommandPalette(session: session).padding(.top, 70)
                    }
                }
            }
            .overlay(alignment: .topTrailing) {
                // Floating, non-modal: the canvas stays visible for the live preview.
                if let item = session.filterDialog.map(FilterDialogItem.init) {
                    FilterSheet(session: session, settings: item.settings)
                        .id(item.id)
                        .glassEffect(.regular, in: .rect(cornerRadius: 18))
                        .padding(.top, 50)
                        .padding(14)
                }
            }
            .sheet(item: Binding(get: { session.selectionDialog.map(SelectionDialogItem.init) },
                                 set: { session.selectionDialog = $0?.id })) { item in
                SelectionModifySheet(session: session, command: item.id)
            }
            .inspector(isPresented: $session.showLayersPanel) {
                VStack(spacing: 0) {
                    Picker("Panel", selection: $session.inspectorTab) {
                        ForEach(EditorSession.InspectorTab.allCases, id: \.self) { Text(LocalizedStringKey($0.rawValue)).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .padding(8)
                    switch session.inspectorTab {
                    case .layers: LayersPanel(session: session)
                    case .paths: PathsPanel(session: session)
                    case .channels: ChannelsPanel(session: session)
                    case .history: HistoryPanel(session: session)
                    case .ai: AIPanel(session: session, ai: session.ai)
                    }
                }
                .frame(maxHeight: .infinity, alignment: .top)
                .inspectorColumnWidth(min: 260, ideal: 300, max: 420)
            }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        session.showLayersPanel.toggle()
                    } label: {
                        Label("Layers", systemImage: "square.3.layers.3d")
                    }
                    .help("Show or hide the Layers panel (⌥⌘L)")
                }
            }
            .sheet(isPresented: $session.isExportSheetPresented) {
                ExportSheet(session: session)
            }
            .sheet(isPresented: $session.isLayerStylePresented) {
                LayerStyleSheet(session: session)
            }
            .alert("Glimmer", isPresented: Binding(
                get: { session.errorMessage != nil },
                set: { if !$0 { session.errorMessage = nil } }
            )) {
                Button("OK") { session.errorMessage = nil }
            } message: {
                Text(session.errorMessage ?? "")
            }
            .focusedSceneValue(\.editorSession, session)
            .onAppear { session.undoManager = undoManager }
            .onChange(of: undoManager) { _, manager in session.undoManager = manager }
    }
}

private struct StatusPill: View {
    let session: EditorSession

    var body: some View {
        content
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Document status")
    }

    private var content: some View {
        HStack(spacing: 8) {
            Text("\(session.state.width) × \(session.state.height) px")
            Text(session.canvas.zoom, format: .percent.precision(.fractionLength(0)))
                .monospacedDigit()
                .foregroundStyle(.secondary)
            if session.paintsMask {
                Label("Editing mask", systemImage: "rectangle.dashed").foregroundStyle(.secondary)
            }
            if session.isExporting {
                ProgressView().controlSize(.small)
                Text("Exporting…").foregroundStyle(.secondary)
            }
            if let job = session.ai.jobs.first(where: { $0.status == .running }) {
                ProgressView().controlSize(.small)
                Text(job.title + "…").foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .glassEffect(.regular, in: .capsule)
        .allowsHitTesting(false)
    }
}

private struct ToolPalette: View {
    @Bindable var session: EditorSession

    var body: some View {
        VStack(spacing: 6) {
            LazyVGrid(columns: [GridItem(.fixed(32), spacing: 2), GridItem(.fixed(32), spacing: 2)], spacing: 2) {
                ForEach(CanvasNSView.availableTools, id: \.self) { tool in
                    Button {
                        session.tool = tool
                    } label: {
                        Image(systemName: tool.symbolName)
                            .font(.system(size: 14, weight: .medium))
                            .frame(width: 32, height: 30)
                            .foregroundStyle(session.tool == tool ? Color.accentColor : .primary)
                            .background {
                                if session.tool == tool {
                                    RoundedRectangle(cornerRadius: 7).fill(Color.accentColor.opacity(0.15))
                                }
                            }
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .help(tool.helpText)
                    .accessibilityLabel(Text(LocalizedStringKey(tool.title)))
                    .accessibilityAddTraits(session.tool == tool ? .isSelected : [])
                }
            }
            ColorSwatches(session: session)
        }
        .padding(6)
        .fixedSize()
        .glassEffect(.regular, in: .rect(cornerRadius: 14))
    }
}

/// Foreground/background colours (X swaps, D resets).
private struct ColorSwatches: View {
    @Bindable var session: EditorSession
    @Environment(\.self) private var environment

    var body: some View {
        ZStack(alignment: .topLeading) {
            ColorPicker("Background", selection: Binding(
                get: { session.background.swiftUI },
                set: { session.background = SRGBColor($0, in: environment) }), supportsOpacity: false)
                .labelsHidden()
                .frame(width: 40, height: 24)
                .offset(x: 22, y: 18)
            ColorPicker("Foreground", selection: Binding(
                get: { session.foreground.swiftUI },
                set: { session.foreground = SRGBColor($0, in: environment) }), supportsOpacity: false)
                .labelsHidden()
                .frame(width: 40, height: 24)
        }
        .frame(width: 66, height: 44, alignment: .topLeading)
        .help("Foreground and background colours (X swaps, D resets)")
        Button {
            showSwatches.toggle()
        } label: {
            Image(systemName: "swatchpalette").frame(width: 32, height: 22)
        }
        .buttonStyle(.plain)
        .help("Swatches")
        .accessibilityLabel("Swatches")
        .popover(isPresented: $showSwatches, arrowEdge: .trailing) {
            SwatchesView(session: session)
        }
    }

    @State private var showSwatches = false
}

/// A palette of colour swatches: click sets the foreground, ⌥-click the
/// background. Saved swatches persist across documents.
private struct SwatchesView: View {
    @Bindable var session: EditorSession
    @AppStorage("swatches.saved") private var savedData = Data()

    private static let defaults: [SRGBColor] = [
        SRGBColor(0, 0, 0), SRGBColor(0.25, 0.25, 0.25), SRGBColor(0.5, 0.5, 0.5), SRGBColor(0.75, 0.75, 0.75), SRGBColor(1, 1, 1),
        SRGBColor(0.86, 0.15, 0.15), SRGBColor(0.96, 0.45, 0.1), SRGBColor(0.98, 0.8, 0.1), SRGBColor(0.35, 0.72, 0.25),
        SRGBColor(0.1, 0.6, 0.55), SRGBColor(0.15, 0.55, 0.9), SRGBColor(0.3, 0.3, 0.8), SRGBColor(0.55, 0.3, 0.75),
        SRGBColor(0.9, 0.35, 0.6), SRGBColor(0.55, 0.36, 0.2), SRGBColor(0.96, 0.87, 0.72), SRGBColor(0.75, 0.55, 0.45),
        SRGBColor(0.35, 0.45, 0.3), SRGBColor(0.2, 0.25, 0.35), SRGBColor(0.95, 0.6, 0.55),
    ]

    private var saved: [SRGBColor] { (try? JSONDecoder().decode([SRGBColor].self, from: savedData)) ?? [] }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Swatches").font(.headline)
            grid(Self.defaults, removable: false)
            HStack {
                Text("Saved").font(.subheadline).foregroundStyle(.secondary)
                Spacer()
                Button("Add Foreground", systemImage: "plus") {
                    var s = saved
                    if !s.contains(session.foreground) { s.append(session.foreground) }
                    savedData = (try? JSONEncoder().encode(s)) ?? savedData
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .help("Save the foreground colour")
            }
            if saved.isEmpty {
                Text("Click + to save the foreground colour.").font(.caption).foregroundStyle(.secondary)
            } else {
                grid(saved, removable: true)
            }
            Text("Click: foreground · ⌥-click: background").font(.caption).foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(width: 236)
    }

    private func grid(_ colors: [SRGBColor], removable: Bool) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.fixed(30), spacing: 8), count: 5), spacing: 8) {
            ForEach(Array(colors.enumerated()), id: \.offset) { _, c in
                RoundedRectangle(cornerRadius: 5)
                    .fill(c.swiftUI)
                    .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(.separator))
                    .frame(width: 30, height: 30)
                    .onTapGesture {
                        if NSEvent.modifierFlags.contains(.option) { session.background = c } else { session.foreground = c }
                    }
                    .contextMenu {
                        if removable {
                            Button("Remove") {
                                let s = saved.filter { $0 != c }
                                savedData = (try? JSONEncoder().encode(s)) ?? savedData
                            }
                        }
                    }
                    .accessibilityElement()
                    .accessibilityLabel(Text("Colour swatch"))
                    .accessibilityAddTraits(.isButton)
            }
        }
    }
}

extension ToolID {
    var title: String {
        switch self {
        case .move: "Move"
        case .hand: "Hand"
        case .rectangleMarquee: "Rectangular Marquee"
        case .ellipseMarquee: "Elliptical Marquee"
        case .lasso: "Lasso"
        case .polygonLasso: "Polygonal Lasso"
        case .magicWand: "Magic Wand"
        case .magicSelect: "Magic Select"
        case .brush: "Brush"
        case .eraser: "Eraser"
        case .paintBucket: "Paint Bucket"
        case .gradient: "Gradient"
        case .eyedropper: "Eyedropper"
        case .crop: "Crop"
        case .cloneStamp: "Clone Stamp"
        case .patternStamp: "Pattern Stamp"
        case .healingBrush: "Healing Brush"
        case .dodge: "Dodge"
        case .burn: "Burn"
        case .blur: "Blur"
        case .sharpen: "Sharpen"
        case .smudge: "Smudge"
        case .freeTransform: "Free Transform"
        case .type: "Type"
        case .pen: "Pen"
        case .shape: "Shape"
        }
    }

    var symbolName: String {
        switch self {
        case .move: "arrow.up.and.down.and.arrow.left.and.right"
        case .hand: "hand.raised"
        case .rectangleMarquee: "rectangle.dashed"
        case .ellipseMarquee: "circle.dashed"
        case .lasso: "lasso"
        case .polygonLasso: "skew"
        case .magicWand: "wand.and.stars"
        case .magicSelect: "wand.and.sparkles"
        case .brush: "paintbrush.pointed"
        case .eraser: "eraser"
        case .paintBucket: "drop.halffull"
        case .gradient: "square.bottomhalf.filled"
        case .eyedropper: "eyedropper"
        case .crop: "crop"
        case .cloneStamp: "seal"
        case .patternStamp: "square.grid.3x3.square"
        case .healingBrush: "bandage"
        case .dodge: "circle.lefthalf.filled"
        case .burn: "flame"
        case .blur: "drop.halffull"
        case .sharpen: "triangle"
        case .smudge: "hand.point.up"
        case .freeTransform: "arrow.up.left.and.down.right.and.arrow.up.right.and.down.left"
        case .type: "textformat"
        case .pen: "pencil.tip.crop.circle"
        case .shape: "square.on.circle"
        }
    }

    var helpText: String {
        if let key = shortcutKey { "\(title) (\(String(key).uppercased()))" } else { title }
    }
}
