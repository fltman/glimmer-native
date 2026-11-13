import GlimmerCore
import GlimmerTools
import SwiftUI

/// Options for the current tool, floating above the canvas.
struct ToolOptionsBar: View {
    @Bindable var session: EditorSession

    var body: some View {
        let tool = session.tool
        if hasOptions(tool) {
            HStack(spacing: 14) {
                Text(tool.title).font(.callout.weight(.semibold))
                switch tool {
                case .brush, .eraser: brushOptions
                case .magicWand: wandOptions(showSampleAll: true)
                case .paintBucket:
                    wandOptions(showSampleAll: true)
                    slider("Opacity", $session.brush.opacity, 0...1, percent: true)
                case .gradient:
                    Picker("Style", selection: $session.gradientStyle) {
                        ForEach(GradientStyle.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 140)
                    .labelsHidden()
                    Toggle("To transparent", isOn: $session.gradientToTransparent)
                case .polygonLasso:
                    Text("Click to add points · double-click or Return to close · Esc cancels")
                        .foregroundStyle(.secondary)
                case .lasso, .rectangleMarquee, .ellipseMarquee:
                    Text("⇧ add · ⌥ subtract · ⇧⌥ intersect").foregroundStyle(.secondary)
                case .magicSelect:
                    Text("Click an object · ⌥-click to exclude · Return keeps · Esc cancels").foregroundStyle(.secondary)
                case .eyedropper:
                    Text("Click to pick the foreground · ⌥-click for the background").foregroundStyle(.secondary)
                default: EmptyView()
                }
            }
            .font(.callout)
            .controlSize(.small)
            .fixedSize()
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .glassEffect(.regular, in: .capsule)
        }
    }

    private func hasOptions(_ tool: ToolID) -> Bool {
        ![.move, .hand].contains(tool)
    }

    @ViewBuilder private var brushOptions: some View {
        Menu("Presets") {
            ForEach(BrushSettings.presets, id: \.0) { name, preset in
                Button(name) { session.brush = preset }
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        slider("Size", Binding(get: { log2(session.brush.size) }, set: { session.brush.size = pow(2, $0).rounded() }),
               0...11, display: "\(Int(session.brush.size)) px")
        slider("Hardness", $session.brush.hardness, 0...1, percent: true)
        slider("Opacity", $session.brush.opacity, 0...1, percent: true)
        slider("Flow", $session.brush.flow, 0.01...1, percent: true)
        Menu("Dynamics") {
            Toggle("Pressure → Size", isOn: $session.brush.pressureSize)
            Toggle("Pressure → Flow", isOn: $session.brush.pressureOpacity)
            Toggle("Textured", isOn: $session.brush.textured)
            Divider()
            Picker("Spacing", selection: $session.brush.spacing) {
                ForEach([0.05, 0.1, 0.25, 0.5, 1.0], id: \.self) { Text("\(Int($0 * 100)) %").tag($0) }
            }
            Picker("Roundness", selection: $session.brush.roundness) {
                ForEach([1.0, 0.75, 0.5, 0.25], id: \.self) { Text("\(Int($0 * 100)) %").tag($0) }
            }
            Picker("Scatter", selection: $session.brush.scatter) {
                ForEach([0.0, 0.25, 0.5, 1.0], id: \.self) { Text("\(Int($0 * 100)) %").tag($0) }
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        if session.activeLayer?.mask != nil {
            Toggle("Paint mask", isOn: $session.editingMask)
        }
    }

    @ViewBuilder private func wandOptions(showSampleAll: Bool) -> some View {
        slider("Tolerance", $session.wandTolerance, 0...255, display: "\(Int(session.wandTolerance))")
        Toggle("Contiguous", isOn: $session.wandContiguous)
        if showSampleAll { Toggle("Sample all layers", isOn: $session.sampleAllLayers) }
    }

    private func slider(_ label: String, _ value: Binding<Double>, _ range: ClosedRange<Double>,
                        percent: Bool = false, display: String? = nil) -> some View {
        HStack(spacing: 6) {
            Text(label).foregroundStyle(.secondary)
            Slider(value: value, in: range).frame(width: 80)
            Text(display ?? (percent ? "\(Int((value.wrappedValue * 100).rounded())) %" : String(format: "%.0f", value.wrappedValue)))
                .monospacedDigit()
                .frame(width: 48, alignment: .leading)
        }
    }
}

struct SelectionDialogItem: Identifiable {
    let id: CommandID
}

/// Feather / Expand / Contract radius prompt.
struct SelectionModifySheet: View {
    let session: EditorSession
    let command: CommandID
    @Environment(\.dismiss) private var dismiss
    @State private var radius = 10.0

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(CommandRegistry.standard.descriptor(for: command)?.title.replacingOccurrences(of: "…", with: "") ?? "")
                .font(.headline)
            HStack {
                Text(command == .featherSelection ? "Feather radius" : "By")
                TextField("Radius", value: $radius, format: .number)
                    .frame(width: 70)
                    .textFieldStyle(.roundedBorder)
                Text("pixels")
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("OK") {
                    session.modifySelection(command, radius: radius)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 320)
    }
}
