import GlimmerCore
import GlimmerRender
import GlimmerTools
import SwiftUI

struct DocumentView: View {
    @State private var session: EditorSession
    @Environment(\.undoManager) private var undoManager

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
            .inspector(isPresented: $session.showLayersPanel) {
                LayersPanel(session: session)
                    .inspectorColumnWidth(min: 230, ideal: 270, max: 400)
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
        HStack(spacing: 8) {
            Text("\(session.state.width) × \(session.state.height) px")
            Text(session.canvas.zoom, format: .percent.precision(.fractionLength(0)))
                .monospacedDigit()
                .foregroundStyle(.secondary)
            if session.isExporting {
                ProgressView().controlSize(.small)
                Text("Exporting…").foregroundStyle(.secondary)
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
        VStack(spacing: 4) {
            ForEach(CanvasNSView.availableTools, id: \.self) { tool in
                Button {
                    session.tool = tool
                } label: {
                    Image(systemName: tool.symbolName)
                        .font(.system(size: 15, weight: .medium))
                        .frame(width: 32, height: 32)
                        .foregroundStyle(session.tool == tool ? Color.accentColor : .primary)
                        .background {
                            if session.tool == tool {
                                RoundedRectangle(cornerRadius: 8).fill(Color.accentColor.opacity(0.15))
                            }
                        }
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .help(tool.helpText)
                .accessibilityLabel(tool.title)
            }
        }
        .padding(6)
        .glassEffect(.regular, in: .rect(cornerRadius: 14))
    }
}

extension ToolID {
    var title: String {
        switch self {
        case .move: "Move"
        case .hand: "Hand"
        default: rawValue.capitalized
        }
    }

    var symbolName: String {
        switch self {
        case .move: "arrow.up.and.down.and.arrow.left.and.right"
        case .hand: "hand.raised"
        default: "questionmark"
        }
    }

    var helpText: String {
        if let key = shortcutKey { "\(title) (\(String(key).uppercased()))" } else { title }
    }
}
