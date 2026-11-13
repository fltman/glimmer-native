import GlimmerCore
import SwiftUI

/// Edits the active layer's styles with live preview. Cancel restores the
/// layer; OK keeps the changes as one undo step.
struct LayerStyleSheet: View {
    let session: EditorSession
    @Environment(\.dismiss) private var dismiss
    @State private var original: DocumentState?

    private var effects: LayerEffects { session.activeLayer?.effects ?? LayerEffects() }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                shadowSection("Drop Shadow", \.dropShadow)
                shadowSection("Inner Shadow", \.innerShadow)
                glowSection
                strokeSection
                overlaySection
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) {
                    if let original { session.revertLiveEdit(to: original) }
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                Button("OK") {
                    session.commitLiveEdit()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding([.horizontal, .bottom], 20)
        }
        .frame(width: 440, height: 620)
        .navigationTitle("Layer Style")
        .onAppear {
            session.commitLiveEdit()
            original = session.state
        }
    }

    private func change(_ edit: @escaping (inout LayerEffects) -> Void) {
        session.liveLayer("Layer Style") { edit(&$0.effects) }
    }

    private func enabledToggle<T>(_ title: String, _ path: WritableKeyPath<LayerEffects, T?>,
                                  make: @escaping () -> T, isEnabled: KeyPath<T, Bool>,
                                  setEnabled: @escaping (inout T, Bool) -> Void) -> some View {
        Toggle(LocalizedStringKey(title), isOn: Binding(
            get: { effects[keyPath: path].map { $0[keyPath: isEnabled] } ?? false },
            set: { on in
                change { e in
                    var value = e[keyPath: path] ?? make()
                    setEnabled(&value, on)
                    e[keyPath: path] = value
                }
            }))
            .font(.headline)
    }

    private func slider(_ label: String, _ value: Double, _ range: ClosedRange<Double>, step: Double = 1,
                        suffix: String = " px", _ set: @escaping (Double) -> Void) -> some View {
        ParameterSlider(label: label, value: value, range: range, step: step,
                        format: { step < 1 ? String(format: "%.0f%%", $0 * 100) : "\(Int($0))\(suffix)" },
                        set: set, commit: {})
    }

    private func modePicker(_ mode: GlimmerCore.BlendMode, _ set: @escaping (GlimmerCore.BlendMode) -> Void) -> some View {
        Picker("Blend Mode", selection: Binding(get: { mode }, set: set)) {
            ForEach(GlimmerCore.BlendMode.pixelModes, id: \.self) { Text(LocalizedStringKey($0.title)).tag($0) }
        }
    }

    @ViewBuilder
    private func shadowSection(_ title: String, _ path: WritableKeyPath<LayerEffects, ShadowEffect?>) -> some View {
        Section {
            enabledToggle(title, path, make: {
                var s = ShadowEffect()
                if path == \LayerEffects.innerShadow { s.distance = 5; s.size = 5 }
                return s
            }, isEnabled: \.isEnabled, setEnabled: { $0.isEnabled = $1 })
            if let s = effects[keyPath: path], s.isEnabled {
                ColorWell(label: "Color", color: s.color) { c in change { $0[keyPath: path]?.color = c } }
                modePicker(s.blendMode) { m in change { $0[keyPath: path]?.blendMode = m } }
                slider("Opacity", s.opacity, 0...1, step: 0.01) { v in change { $0[keyPath: path]?.opacity = v } }
                slider("Angle", s.angle, -180...180, suffix: "°") { v in change { $0[keyPath: path]?.angle = v } }
                slider("Distance", s.distance, 0...250) { v in change { $0[keyPath: path]?.distance = v } }
                slider("Spread", s.spread, 0...1, step: 0.01) { v in change { $0[keyPath: path]?.spread = v } }
                slider("Size", s.size, 0...250) { v in change { $0[keyPath: path]?.size = v } }
            }
        }
    }

    private var glowSection: some View {
        Section {
            enabledToggle("Outer Glow", \.outerGlow, make: GlowEffect.init, isEnabled: \.isEnabled,
                          setEnabled: { $0.isEnabled = $1 })
            if let g = effects.outerGlow, g.isEnabled {
                ColorWell(label: "Color", color: g.color) { c in change { $0.outerGlow?.color = c } }
                modePicker(g.blendMode) { m in change { $0.outerGlow?.blendMode = m } }
                slider("Opacity", g.opacity, 0...1, step: 0.01) { v in change { $0.outerGlow?.opacity = v } }
                slider("Spread", g.spread, 0...1, step: 0.01) { v in change { $0.outerGlow?.spread = v } }
                slider("Size", g.size, 0...250) { v in change { $0.outerGlow?.size = v } }
            }
        }
    }

    private var strokeSection: some View {
        Section {
            enabledToggle("Stroke", \.stroke, make: StrokeEffect.init, isEnabled: \.isEnabled,
                          setEnabled: { $0.isEnabled = $1 })
            if let s = effects.stroke, s.isEnabled {
                ColorWell(label: "Color", color: s.color) { c in change { $0.stroke?.color = c } }
                Picker("Position", selection: Binding(get: { s.position }, set: { p in change { $0.stroke?.position = p } })) {
                    ForEach(StrokeEffect.Position.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
                }
                .pickerStyle(.segmented)
                slider("Size", s.width, 1...100) { v in change { $0.stroke?.width = v } }
                slider("Opacity", s.opacity, 0...1, step: 0.01) { v in change { $0.stroke?.opacity = v } }
            }
        }
    }

    private var overlaySection: some View {
        Section {
            enabledToggle("Color Overlay", \.colorOverlay, make: ColorOverlayEffect.init, isEnabled: \.isEnabled,
                          setEnabled: { $0.isEnabled = $1 })
            if let o = effects.colorOverlay, o.isEnabled {
                ColorWell(label: "Color", color: o.color) { c in change { $0.colorOverlay?.color = c } }
                modePicker(o.blendMode) { m in change { $0.colorOverlay?.blendMode = m } }
                slider("Opacity", o.opacity, 0...1, step: 0.01) { v in change { $0.colorOverlay?.opacity = v } }
            }
        }
    }
}
