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
                // The tool's name in small capitals, as in the web app.
                Text(LocalizedStringKey(tool.title))
                    .textCase(.uppercase)
                    .font(.caption.weight(.semibold))
                    .kerning(0.8)
                    .foregroundStyle(Theme.muted)
                switch tool {
                case .brush, .eraser: brushOptions
                case .magicWand:
                    wandOptions(showSampleAll: true)
                    featherOption
                case .paintBucket:
                    wandOptions(showSampleAll: true)
                    slider("Opacity", $session.brush.opacity, 0...1, percent: true)
                    Menu("Fill") {
                        Button(session.state.selection == nil ? "Whole Layer with Foreground" : "Selection with Foreground") {
                            session.perform(.fillForeground)
                        }
                        Button(session.state.selection == nil ? "Whole Layer with Pattern" : "Selection with Pattern") {
                            session.perform(.fillPattern)
                        }
                        Divider()
                        Picker("Pattern", selection: $session.patternKind) {
                            ForEach(PatternKind.allCases, id: \.self) { Text(LocalizedStringKey($0.title)).tag($0) }
                        }
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .help("Fill without tolerance (⌥⌫ fills with the foreground colour)")
                case .gradient:
                    Picker("Style", selection: $session.gradientStyle) {
                        ForEach(GradientStyle.allCases, id: \.self) { Text(LocalizedStringKey($0.title)).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 140)
                    .labelsHidden()
                    GradientToolOptions(session: session)
                case .polygonLasso:
                    featherOption
                    Text("Click to add points · double-click or Return to close · Esc cancels")
                        .foregroundStyle(.secondary)
                case .lasso:
                    featherOption
                    Text("⇧ add · ⌥ subtract · ⇧⌥ intersect").foregroundStyle(.secondary)
                case .rectangleMarquee, .ellipseMarquee:
                    featherOption
                    Text("⇧ add · ⌥ subtract · while dragging: ⇧ square, ⌥ from the centre").foregroundStyle(.secondary)
                case .magicSelect:
                    if session.ai.magicPoints.isEmpty {
                        Text("Click an object · ⌥-click to exclude").foregroundStyle(.secondary)
                    } else {
                        Text("\(session.ai.magicPoints.count) points").monospacedDigit().foregroundStyle(.secondary)
                        Text("Click to add · ⌥-click to exclude").foregroundStyle(.secondary)
                        Button("Clear Points") { session.ai.cancelMagicSelect() }
                            .help("Forget the points and put back the earlier selection (Esc)")
                        Button("Apply") { session.ai.resetMagicSelect() }
                            .keyboardShortcut(.defaultAction)
                    }
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
                    ColorPicker("Fill color", selection: Binding<Color>(
                        get: { let c = session.shapeFillColor ?? session.foreground; return Color(.sRGB, red: c.r, green: c.g, blue: c.b) },
                        set: { c in
                            guard let rgb = NSColor(c).usingColorSpace(.sRGB) else { return }
                            session.shapeFillColor = SRGBColor(rgb.redComponent, rgb.greenComponent, rgb.blueComponent)
                        }), supportsOpacity: false)
                        .labelsHidden()
                        .fixedSize()
                        .help("Fill colour of new shapes")
                    if session.shapeFillColor != nil {
                        Button("Use Foreground") { session.shapeFillColor = nil }
                            .help("Fill new shapes with the foreground colour again")
                    }
                    slider("Stroke", $session.shapeStrokeWidth, 0...100,
                           display: session.shapeStrokeWidth < 1 ? String(localized: "Off") : "\(Int(session.shapeStrokeWidth)) px")
                    if session.shapeStrokeWidth >= 1 {
                        ColorPicker("Stroke color", selection: Binding<Color>(
                            get: { let c = session.shapeStrokeColor; return Color(.sRGB, red: c.r, green: c.g, blue: c.b) },
                            set: { c in
                                guard let rgb = NSColor(c).usingColorSpace(.sRGB) else { return }
                                session.shapeStrokeColor = SRGBColor(rgb.redComponent, rgb.greenComponent, rgb.blueComponent)
                            }), supportsOpacity: false)
                            .labelsHidden()
                            .fixedSize()
                    }
                    Text("⇧ constrains · U next shape").foregroundStyle(.secondary)
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
            row.panelSurface(cornerRadius: 10)
            ScrollView(.horizontal, showsIndicators: false) { row }
                .panelSurface(cornerRadius: 10)
        }
        .padding(.horizontal, 12)
    }

    /// Softens selections as they are made.
    private var featherOption: some View {
        slider("Feather", $session.selectionFeather, 0...32, display: "\(Int(session.selectionFeather)) px")
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
        Button("Restore All") { session.restoreAllLiquify() }
            .help("Undo every liquify change on this layer")
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
                Text("corners keep proportions, ⇧ frees them · drag just outside a corner to rotate · click away to apply · ⌘-drag a corner to distort").foregroundStyle(.secondary)
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
        Button("Suggest", systemImage: "sparkles") { session.ai.suggestCrop() }
            .help("Frame the subject at this aspect ratio (on-device)")
        Button("Level", systemImage: "level") { session.ai.autoStraighten() }
            .help("Straighten a tilted horizon (on-device)")
        slider("Straighten", Binding(get: { (session.cropSession?.angle ?? 0) * 180 / .pi },
                                     set: { session.setCropAngle(degrees: $0) }), -45...45,
               display: String(format: "%.1f°", (session.cropSession?.angle ?? 0) * 180 / .pi))
        if let r = session.cropSession?.rect {
            Text("\(Int(r.width.rounded())) × \(Int(r.height.rounded())) px").monospacedDigit().foregroundStyle(.secondary)
        }
        Toggle("Delete cropped pixels", isOn: $session.cropDeletesPixels)
            .help("Off keeps the pixels outside the crop, so you can move them back in later")
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
        BrushPresetsMenu(session: session)
        slider("Size", Binding(get: { log2(session.brush.size) }, set: { session.brush.size = pow(2, $0).rounded() }),
               0...11, display: "\(Int(session.brush.size)) px")
        slider("Hardness", $session.brush.hardness, 0...1, percent: true)
        slider("Opacity", $session.brush.opacity, 0...1, percent: true)
        slider("Flow", $session.brush.flow, 0.01...1, percent: true)
        BrushDynamicsButton(session: session)
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
        if let layer = session.activeLayer, case .text(let text) = layer.content,
           !session.state.paths.isEmpty || text.onPath != nil {
            if text.onPath != nil, text.onPathID == nil {
                // On a path that no longer exists (or from an older document).
                Button("Take Off Path") { session.setTextPath(nil) }
            }
            if !session.state.paths.isEmpty {
                Picker("On path", selection: Binding(get: { text.onPathID }, set: { session.setTextPath($0) })) {
                    Text("No Path").tag(UUID?.none)
                    ForEach(session.state.paths) { Text($0.name).tag(UUID?.some($0.id)) }
                }
                .fixedSize()
                .help("Run this text along a path, or take it off again")
            }
        }
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

/// Built-in and saved brushes.
private struct BrushPresetsMenu: View {
    @Bindable var session: EditorSession
    @State private var store = BrushPresetStore.shared
    @State private var isNaming = false
    @State private var name = ""

    var body: some View {
        Menu("Presets") {
            ForEach(BrushSettings.presets, id: \.0) { name, preset in
                Button(LocalizedStringKey(name)) { session.brush = preset }
            }
            if !store.presets.isEmpty {
                Divider()
                ForEach(store.presets) { preset in
                    Button(preset.name) { session.brush = preset.settings }
                }
            }
            Divider()
            Button("Save Current Brush…") {
                name = ""
                isNaming = true
            }
            if !store.presets.isEmpty {
                Menu("Delete") {
                    ForEach(store.presets) { preset in
                        Button(preset.name, role: .destructive) { store.remove(preset.id) }
                    }
                }
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .popover(isPresented: $isNaming, arrowEdge: .bottom) {
            HStack {
                TextField("Brush name", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 180)
                    .onSubmit(save)
                Button("Save", action: save)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(12)
        }
    }

    private func save() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        store.save(session.brush, as: trimmed)
        isNaming = false
    }
}

/// Your own brushes, kept in the app's preferences.
@MainActor
@Observable
final class BrushPresetStore {
    struct Preset: Codable, Identifiable {
        var id = UUID()
        var name: String
        var settings: BrushSettings
    }

    static let shared = BrushPresetStore()
    private static let key = "brush.userPresets"

    private(set) var presets: [Preset] = []

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.key),
           let saved = try? JSONDecoder().decode([Preset].self, from: data) {
            presets = saved
        }
    }

    /// Saves the brush; a preset with the same name is replaced.
    func save(_ settings: BrushSettings, as name: String) {
        presets.removeAll { $0.name == name }
        presets.append(Preset(name: name, settings: settings))
        persist()
    }

    func remove(_ id: UUID) {
        presets.removeAll { $0.id == id }
        persist()
    }

    private func persist() {
        UserDefaults.standard.set(try? JSONEncoder().encode(presets), forKey: Self.key)
    }
}

/// Shape and dynamics of the brush tip, with continuous controls as in the web app.
private struct BrushDynamicsButton: View {
    @Bindable var session: EditorSession
    @State private var isShown = false

    var body: some View {
        Button("Dynamics") { isShown.toggle() }
            .popover(isPresented: $isShown, arrowEdge: .bottom) {
                Form {
                    Section("Tip") {
                        row("Spacing", $session.brush.spacing, 0.01...2) { "\(Int(($0 * 100).rounded())) %" }
                        row("Roundness", $session.brush.roundness, 0.05...1) { "\(Int(($0 * 100).rounded())) %" }
                        row("Angle", $session.brush.angle, -180...180) { "\(Int($0.rounded()))°" }
                        row("Scatter", $session.brush.scatter, 0...1) { "\(Int(($0 * 100).rounded())) %" }
                        row("Size Jitter", $session.brush.sizeJitter, 0...1) { "\(Int(($0 * 100).rounded())) %" }
                        Toggle("Textured", isOn: $session.brush.textured)
                    }
                    Section("Pen") {
                        Toggle("Pressure → Size", isOn: $session.brush.pressureSize)
                        Toggle("Pressure → Flow", isOn: $session.brush.pressureOpacity)
                        Toggle("Tilt → Angle", isOn: $session.brush.tiltAngle)
                        Toggle("Tilt → Roundness", isOn: $session.brush.tiltRoundness)
                        Toggle("Rotation → Angle", isOn: $session.brush.rotationAngle)
                    }
                }
                .formStyle(.grouped)
                .frame(width: 340)
                .fixedSize(horizontal: false, vertical: true)
            }
    }

    private func row(_ label: String, _ value: Binding<Double>, _ range: ClosedRange<Double>,
                     _ format: @escaping (Double) -> String) -> some View {
        LabeledContent(LocalizedStringKey(label)) {
            HStack {
                Slider(value: value, in: range)
                Text(format(value.wrappedValue))
                    .monospacedDigit()
                    .frame(width: 48, alignment: .trailing)
            }
        }
    }
}

/// What the Gradient tool draws: the two colours, a preset ramp or your own stops.
private struct GradientToolOptions: View {
    @Bindable var session: EditorSession
    @State private var isEditing = false

    private static let presets: [(String, [GradientStop])] = [
        ("Black to White", [GradientStop(0, SRGBColor(0, 0, 0)), GradientStop(1, SRGBColor(1, 1, 1))]),
        ("Sunset", [GradientStop(0, SRGBColor(0.16, 0.07, 0.36)), GradientStop(0.5, SRGBColor(0.91, 0.29, 0.37)),
                    GradientStop(1, SRGBColor(1, 0.8, 0.4))]),
        ("Ocean", [GradientStop(0, SRGBColor(0.02, 0.1, 0.3)), GradientStop(0.6, SRGBColor(0.05, 0.55, 0.75)),
                   GradientStop(1, SRGBColor(0.7, 0.95, 0.9))]),
        ("Spectrum", [GradientStop(0, SRGBColor(1, 0, 0)), GradientStop(0.2, SRGBColor(1, 1, 0)), GradientStop(0.4, SRGBColor(0, 1, 0)),
                      GradientStop(0.6, SRGBColor(0, 1, 1)), GradientStop(0.8, SRGBColor(0, 0, 1)), GradientStop(1, SRGBColor(1, 0, 1))]),
    ]

    var body: some View {
        Menu(title) {
            Button("Foreground to Background") { session.gradientStops = nil; session.gradientToTransparent = false }
            Button("Foreground to Transparent") { session.gradientStops = nil; session.gradientToTransparent = true }
            Divider()
            ForEach(Self.presets, id: \.0) { name, stops in
                Button(LocalizedStringKey(name)) { session.gradientStops = stops }
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        Button("Edit Stops") {
            if session.gradientStops == nil { session.gradientStops = session.currentGradientStops }
            isEditing = true
        }
        .popover(isPresented: $isEditing, arrowEdge: .bottom) {
            GradientStopsEditor(stops: session.currentGradientStops) { session.gradientStops = $0 } commit: {}
                .padding(14)
                .frame(width: 320)
        }
        Toggle("Reverse", isOn: $session.gradientReverse)
    }

    private var title: LocalizedStringKey {
        if session.gradientStops != nil { return "Custom" }
        return session.gradientToTransparent ? "Foreground to Transparent" : "Foreground to Background"
    }
}
