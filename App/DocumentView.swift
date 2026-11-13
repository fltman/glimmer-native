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
        default: rawValue.capitalized
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
        default: "questionmark"
        }
    }

    var helpText: String {
        if let key = shortcutKey { "\(title) (\(String(key).uppercased()))" } else { title }
    }
}
