import GlimmerCore
import GlimmerRender
import SwiftUI

struct ExportSheet: View {
    @Bindable var session: EditorSession
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let format = session.exportOptions.format
        VStack(alignment: .leading, spacing: 0) {
            Form {
                Picker("Format", selection: $session.exportOptions.format) {
                    ForEach(ExportOptions.Format.allCases) { Text(LocalizedStringKey($0.title)).tag($0) }
                }
                if format.bitDepths.count > 1 {
                    Picker("Bit depth", selection: Binding(get: { session.exportOptions.effectiveBitDepth },
                                                           set: { session.exportOptions.bitDepth = $0 })) {
                        ForEach(format.bitDepths) { Text(LocalizedStringKey($0.title)).tag($0) }
                    }
                }
                if format == .webp {
                    Text("WebP is saved lossless.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                if format.isLossy {
                    LabeledContent("Quality") {
                        HStack {
                            Slider(value: $session.exportOptions.quality, in: 0.1...1)
                            Text(session.exportOptions.quality, format: .percent.precision(.fractionLength(0)))
                                .monospacedDigit()
                                .frame(width: 44, alignment: .trailing)
                        }
                    }
                }
                Picker("Color profile", selection: $session.exportOptions.colorSpace) {
                    Text("sRGB").tag(WorkingColorSpace.sRGB)
                    Text("Display P3").tag(WorkingColorSpace.displayP3)
                }
                if !format.supportsAlpha {
                    Text("Transparent areas are flattened onto white.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                LabeledContent("Size", value: "\(session.state.width) × \(session.state.height) px")
            }
            .formStyle(.grouped)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Export…") {
                    let options = session.exportOptions
                    dismiss()
                    session.export(options: options)
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding([.horizontal, .bottom], 20)
        }
        .frame(width: 420)
        .navigationTitle("Export")
    }
}
