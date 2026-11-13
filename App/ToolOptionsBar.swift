import AppKit
import GlimmerCore
import GlimmerRender
import GlimmerTools
import SwiftUI

/// Options for the current tool, floating above the canvas.
struct ToolOptionsBar: View {
    @Bindable var session: EditorSession

    var body: some View {
        let tool = session.tool
        if session.liquify != nil {
            bar { liquifyOptions }
        } else if hasOptions(tool) {
            bar {
                Text(LocalizedStringKey(tool.title)).font(.callout.weight(.semibold))
                switch tool {
                case .brush, .eraser: brushOptions
                case .magicWand: wandOptions(showSampleAll: true)
                case .paintBucket:
                    wandOptions(showSampleAll: true)
                    slider("Opacity", $session.brush.opacity, 0...1, percent: true)
                case .gradient:
                    Picker("Style", selection: $session.gradientStyle) {
                        ForEach(GradientStyle.allCases, id: \.self) { Text(LocalizedStringKey($0.title)).tag($0) }
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
                case .freeTransform: transformOptions
                case .crop: cropOptions
                case .type: TextOptions(session: session)
                case .pen:
                    Text("Click for corners · drag for curves · ⌥ breaks handles · click the first point to close · Return ends")
                        .foregroundStyle(.secondary)
                case .shape:
                    Picker("Shape", selection: $session.shapeKind) {
                        ForEach(EditorSession.ShapeKind.allCases, id: \.self) { Text(LocalizedStringKey($0.title)).tag($0) }
                    }
                    .labelsHidden()
                    .fixedSize()
                    if session.shapeKind == .roundedRectangle {
                        slider("Radius", $session.shapeCornerRadius, 1...400, display: "\(Int(session.shapeCornerRadius)) px")
                    }
                    if session.shapeKind == .line {
                        slider("Width", $session.shapeLineWidth, 1...100, display: "\(Int(session.shapeLineWidth)) px")
                    }
                    Text("⇧ constrains").foregroundStyle(.secondary)
                case .cloneStamp, .healingBrush:
                    retouchBrushOptions
                    Toggle("Aligned", isOn: $session.cloneAligned)
                    Text(session.cloneSource == nil ? "⌥-click to set the source" : "⌥-click sets a new source")
                        .foregroundStyle(.secondary)
                case .dodge, .burn:
                    retouchBrushOptions
                    Picker("Range", selection: $session.dodgeRange) {
                        Text("Shadows").tag(0)
                        Text("Midtones").tag(1)
                        Text("Highlights").tag(2)
                    }
                    .frame(width: 130)
                    slider("Exposure", $session.dodgeExposure, 0.01...1, percent: true)
                case .patternStamp:
                    retouchBrushOptions
                    slider("Opacity", $session.brush.opacity, 0...1, percent: true)
                    Picker("Pattern", selection: $session.patternKind) {
                        ForEach(PatternKind.allCases, id: \.self) { Text(LocalizedStringKey($0.title)).tag($0) }
                    }
                    .frame(width: 140)
                    slider("Scale", $session.patternScale, 4...256, display: "\(Int(session.patternScale)) px")
                    Text("Uses the foreground and background colours").foregroundStyle(.secondary)
                case .blur, .sharpen, .smudge:
                    retouchBrushOptions
                    slider("Strength", $session.retouchStrength, 0.01...1, percent: true)
                default: EmptyView()
                }
            }
        }
    }

    private func bar(@ViewBuilder _ content: () -> some View) -> some View {
        let row = HStack(spacing: 14) { content() }
            .font(.callout)
            .controlSize(.small)
            .fixedSize()
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
        // Long option rows scroll instead of spilling past the canvas edges.
        return ViewThatFits(in: .horizontal) {
            row.glassEffect(.regular, in: .capsule)
            ScrollView(.horizontal, showsIndicators: false) { row }
                .glassEffect(.regular, in: .capsule)
        }
        .padding(.horizontal, 12)
    }

    @ViewBuilder private var retouchBrushOptions: some View {
        slider("Size", Binding(get: { log2(session.brush.size) }, set: { session.brush.size = pow(2, $0).rounded() }),
               0...11, display: "\(Int(session.brush.size)) px")
        slider("Hardness", $session.brush.hardness, 0...1, percent: true)
        if session.tool == .cloneStamp || session.tool == .healingBrush {
            slider("Opacity", $session.brush.opacity, 0...1, percent: true)
        }
    }

    @ViewBuilder private var liquifyOptions: some View {
        Text("Liquify").font(.callout.weight(.semibold))
        Picker("Mode", selection: $session.liquifyMode) {
            ForEach(LiquifyEngine.Mode.allCases, id: \.self) { Text(LocalizedStringKey($0.title)).tag($0) }
        }
        .frame(width: 190)
        .labelsHidden()
        slider("Size", Binding(get: { log2(session.liquifySize) }, set: { session.liquifySize = pow(2, $0).rounded() }),
               3...11, display: "\(Int(session.liquifySize)) px")
        slider("Pressure", $session.liquifyPressure, 0.01...1, percent: true)
        Button("Cancel") { session.cancelLiquify() }
        Button("Apply") { session.commitLiquify() }
            .keyboardShortcut(.defaultAction)
    }

    @ViewBuilder private var transformOptions: some View {
        if let t = session.transformSession {
            Picker("Mode", selection: Binding(get: { t.mode }, set: { session.setTransformMode($0) })) {
                ForEach(EditorSession.TransformMode.allCases, id: \.self) { Text(LocalizedStringKey($0.title)).tag($0) }
            }
            .labelsHidden()
            .fixedSize()
            if t.quad == nil {
                numberField("W", t.box.scaleX * 100, suffix: "%") { session.setTransform(scaleXPercent: $0) }
                numberField("H", t.box.scaleY * 100, suffix: "%") { session.setTransform(scaleYPercent: $0) }
                numberField("∠", t.box.rotation * 180 / .pi, suffix: "°") { session.setTransform(degrees: $0) }
                Text("⇧ keeps proportions · drag outside to rotate · ⌘-drag a corner to distort").foregroundStyle(.secondary)
            } else {
                Text(t.mode == .skew ? "Drag an edge to slant it" : t.mode == .perspective
                     ? "Drag a corner; its neighbour mirrors it" : "Drag corners freely").foregroundStyle(.secondary)
            }
            Button("Cancel") { session.cancelTransform(); session.tool = .move }
            Button("Apply") { session.commitTransform(); session.tool = .move }
                .keyboardShortcut(.defaultAction)
        } else {
            Text("Select a layer to transform").foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var cropOptions: some View {
        Picker("Aspect", selection: Binding(get: { session.cropSession?.aspect ?? 0 },
                                            set: { session.setCropAspect($0 == 0 ? nil : $0) })) {
            Text("Free").tag(0.0)
            Text("Original").tag(Double(session.state.width) / Double(max(session.state.height, 1)))
            Text("1:1").tag(1.0)
            Text("4:3").tag(4.0 / 3)
            Text("3:2").tag(3.0 / 2)
            Text("16:9").tag(16.0 / 9)
            Text("4:5").tag(4.0 / 5)
            Text("9:16").tag(9.0 / 16)
        }
        .frame(width: 140)
        slider("Straighten", Binding(get: { (session.cropSession?.angle ?? 0) * 180 / .pi },
                                     set: { session.setCropAngle(degrees: $0) }), -45...45,
               display: String(format: "%.1f°", (session.cropSession?.angle ?? 0) * 180 / .pi))
        if let r = session.cropSession?.rect {
            Text("\(Int(r.width.rounded())) × \(Int(r.height.rounded())) px").monospacedDigit().foregroundStyle(.secondary)
        }
        Button("Cancel") { session.cropSession = nil; session.tool = .move }
        Button("Crop") { session.applyCrop(); session.tool = .move }
            .keyboardShortcut(.defaultAction)
    }

    private func numberField(_ label: String, _ value: Double, suffix: String, set: @escaping (Double) -> Void) -> some View {
        HStack(spacing: 3) {
            Text(LocalizedStringKey(label)).foregroundStyle(.secondary)
            TextField(label, value: Binding(get: { (value * 10).rounded() / 10 }, set: set), format: .number.precision(.fractionLength(0...1)))
                .textFieldStyle(.roundedBorder)
                .frame(width: 56)
                .labelsHidden()
            Text(suffix).foregroundStyle(.secondary)
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
            Text(LocalizedStringKey(label)).foregroundStyle(.secondary)
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

/// Font, size, alignment and colour for the Type tool. Edits the active text
/// layer when there is one, otherwise the defaults for new text.
private struct TextOptions: View {
    @Bindable var session: EditorSession

    private var current: TextLayer {
        if let layer = session.activeLayer, case .text(let t) = layer.content { return t }
        let d = session.textDefaults
        return TextLayer(string: "", fontName: d.fontName, size: d.size, color: session.foreground, alignment: d.alignment, origin: .zero)
    }

    var body: some View {
        let t = current
        let family = NSFont(name: t.fontName, size: 12)?.familyName ?? "Helvetica Neue"
        let members = NSFontManager.shared.availableMembers(ofFontFamily: family) ?? []
        Picker("Font", selection: Binding(get: { family }, set: { newFamily in
            let first = (NSFontManager.shared.availableMembers(ofFontFamily: newFamily)?.first?.first as? String) ?? newFamily
            apply { $0.fontName = first }
        })) {
            ForEach(NSFontManager.shared.availableFontFamilies, id: \.self) { Text($0).tag($0) }
        }
        .labelsHidden()
        .frame(width: 160)
        Picker("Style", selection: Binding(get: { t.fontName }, set: { name in apply { $0.fontName = name } })) {
            ForEach(members.indices, id: \.self) { i in
                let name = members[i].first as? String ?? ""
                Text(members[i].count > 1 ? (members[i][1] as? String ?? name) : name).tag(name)
            }
        }
        .labelsHidden()
        .frame(width: 110)
        HStack(spacing: 3) {
            TextField("Size", value: Binding(get: { t.size }, set: { v in apply { $0.size = max(v, 1) } }), format: .number.precision(.fractionLength(0...1)))
                .textFieldStyle(.roundedBorder)
                .frame(width: 50)
            Text("pt").foregroundStyle(.secondary)
        }
        Picker("Align", selection: Binding(get: { t.alignment }, set: { a in apply { $0.alignment = a } })) {
            Image(systemName: "text.alignleft").tag(GlimmerCore.TextAlignment.left)
            Image(systemName: "text.aligncenter").tag(GlimmerCore.TextAlignment.center)
            Image(systemName: "text.alignright").tag(GlimmerCore.TextAlignment.right)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(width: 96)
        ColorPicker("Color", selection: Binding<Color>(
            get: { Color(.sRGB, red: t.color.r, green: t.color.g, blue: t.color.b) },
            set: { c in
                guard let rgb = NSColor(c).usingColorSpace(.sRGB) else { return }
                apply { $0.color = SRGBColor(rgb.redComponent, rgb.greenComponent, rgb.blueComponent) }
            }), supportsOpacity: false)
            .labelsHidden()
            .fixedSize()
        if let layer = session.activeLayer, case .text(let text) = layer.content, text.onPath == nil {
            Button("Warp", systemImage: "textformat.size.larger") { showWarp.toggle() }
                .help("Warp Text")
                .popover(isPresented: $showWarp, arrowEdge: .bottom) { WarpTextPanel(session: session, warp: text.warp) }
        }
    }

    @State private var showWarp = false

    private func apply(_ change: @escaping (inout TextLayer) -> Void) {
        session.updateText(change)
        session.commitLiveEdit()
    }
}

/// Style, bend and distortion for the active text layer's warp envelope.
private struct WarpTextPanel: View {
    let session: EditorSession
    @State var warp: TextWarp

    init(session: EditorSession, warp: TextWarp?) {
        self.session = session
        _warp = State(initialValue: warp ?? TextWarp(style: .none, bend: 0.5))
    }

    var body: some View {
        Form {
            Picker("Style", selection: $warp.style) {
                ForEach(TextWarp.Style.allCases) { Text(LocalizedStringKey($0.title)).tag($0) }
            }
            slider("Bend", \.bend)
            slider("Horizontal Distortion", \.horizontal)
            slider("Vertical Distortion", \.vertical)
        }
        .formStyle(.grouped)
        .frame(width: 340)
        .fixedSize(horizontal: false, vertical: true)
        .onChange(of: warp.style) { push(commit: true) }
    }

    private func slider(_ label: String, _ key: WritableKeyPath<TextWarp, Double>) -> some View {
        LabeledContent(LocalizedStringKey(label)) {
            HStack {
                Slider(value: Binding(get: { warp[keyPath: key] }, set: { warp[keyPath: key] = $0; push(commit: false) }),
                       in: -1...1) { editing in if !editing { session.commitLiveEdit() } }
                Text("\(Int((warp[keyPath: key] * 100).rounded()))")
                    .monospacedDigit()
                    .frame(width: 36, alignment: .trailing)
            }
        }
        .disabled(warp.style == .none)
    }

    private func push(commit: Bool) {
        let value = warp
        session.updateTextWarp(value.style == .none ? nil : value)
        if commit { session.commitLiveEdit() }
    }
}

/// Settings for one filter with live preview on the canvas.
struct FilterSheet: View {
    let session: EditorSession
    @State var settings: FilterSettings
    @State private var preview = true

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(LocalizedStringKey(settings.kind.title)).font(.headline)
                Spacer()
                if session.isPreviewingFilter && preview { ProgressView().controlSize(.small) }
            }
            Form {
                ForEach(settings.kind.fields, id: \.key) { field in
                    if field.isToggle {
                        Toggle(LocalizedStringKey(field.label), isOn: Binding(get: { settings.flag(field.key) },
                                                          set: { settings.values[field.key] = $0 ? 1 : 0 }))
                    } else {
                        LabeledContent(LocalizedStringKey(field.label)) {
                            HStack {
                                Slider(value: Binding(get: { settings.value(field.key) }, set: { settings.values[field.key] = $0 }),
                                       in: field.range)
                                    .frame(width: 200)
                                Text(format(settings.value(field.key), field))
                                    .monospacedDigit()
                                    .frame(width: 56, alignment: .trailing)
                            }
                        }
                    }
                }
            }
            if session.state.selection != nil {
                Label("Applies to the selection", systemImage: "selection.pin.in.out")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack {
                Toggle("Preview", isOn: $preview)
                Spacer()
                Button("Reset") { settings = FilterSettings(settings.kind) }
                Button("Cancel", role: .cancel) { session.cancelFilterDialog() }
                    .keyboardShortcut(.cancelAction)
                Button("OK") { session.applyFilter(settings) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 420)
        .onChange(of: settings) { _, new in if preview { session.previewFilter(new) } }
        .onChange(of: preview) { _, on in
            if on { session.previewFilter(settings) } else { session.filterPreviewTask?.cancel(); session.overrides = .none }
        }
    }

    private func format(_ v: Double, _ field: FilterField) -> String {
        let text = field.range.upperBound <= 5 ? String(format: "%.2f", v) : String(format: "%.0f", v)
        return field.unit.isEmpty ? text : "\(text) \(field.unit)"
    }
}
