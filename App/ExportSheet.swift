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
                if format.hasQuality {
                    LabeledContent("Quality") {
                        HStack {
                            Slider(value: $session.exportOptions.quality, in: 0.1...1)
                            Text(session.exportOptions.quality, format: .percent.precision(.fractionLength(0)))
                                .monospacedDigit()
                                .frame(width: 44, alignment: .trailing)
                        }
                    }
                }
                ExportLimitsFields(options: $session.exportOptions)
                if format == .webp {
                    Text("WebP is lossless at 100 % and lossy below.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
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
                LabeledContent("Size", value: Self.outputSize(session.state.width, session.state.height, session.exportOptions.maxPixelSide))
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

extension ExportSheet {
    static func outputSize(_ w: Int, _ h: Int, _ maxSide: Int?) -> String {
        guard let side = maxSide, side > 0, max(w, h) > side else { return "\(w) × \(h) px" }
        let k = Double(side) / Double(max(w, h))
        return "\(Int((Double(w) * k).rounded())) × \(Int((Double(h) * k).rounded())) px"
    }
}

/// Longest side and file-size limit, shared by Export and Batch Process.
struct ExportLimitsFields: View {
    @Binding var options: ExportOptions

    var body: some View {
        Toggle("Limit longest side", isOn: Binding(get: { options.maxPixelSide != nil },
                                                   set: { options.maxPixelSide = $0 ? 2048 : nil }))
        if let side = options.maxPixelSide {
            LabeledContent("Longest side") {
                HStack(spacing: 4) {
                    TextField("", value: Binding(get: { side }, set: { options.maxPixelSide = max(16, $0) }), format: .number)
                        .multilineTextAlignment(.trailing).frame(width: 80)
                    Text("px").foregroundStyle(.secondary)
                }
            }
        }
        if options.format.hasQuality {
            Toggle("Limit file size", isOn: Binding(get: { options.maxBytes != nil },
                                                    set: { options.maxBytes = $0 ? 500_000 : nil }))
            if let bytes = options.maxBytes {
                LabeledContent("At most") {
                    HStack(spacing: 4) {
                        TextField("", value: Binding(get: { bytes / 1000 }, set: { options.maxBytes = max(5, $0) * 1000 }),
                                  format: .number)
                            .multilineTextAlignment(.trailing).frame(width: 80)
                        Text("kB").foregroundStyle(.secondary)
                    }
                }
                Text("Glimmer finds the best quality that fits, and scales the image down only if it must.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
    }
}
