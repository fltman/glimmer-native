#if GLIMMER_PSD   // Config/Features.xcconfig switches this
import AppKit
import GlimmerCore
import GlimmerRender
import SwiftUI
import UniformTypeIdentifiers

/// The export report in the person's language. (GlimmerRender has the same in English for the agent API.)
extension PSDExportReport.Note {
    var localized: String {
        let detail = detail ?? ""
        return switch kind {
        case .writtenAsPixels: String(localized: "It is written as a layer of pixels that looks the same (in Glimmer it is \(detail)).")
        case .adjustmentLeftOut: String(localized: "It is a \(detail) adjustment layer, which Glimmer can't write as one. It is not among the file's layers; the flattened picture in the file still shows it.")
        case .maskSimplified: String(localized: "Its mask is written without its feather and density.")
        case .clippedToCanvas: String(localized: "It reaches outside the canvas, and what is outside is not written.")
        case .linearBlending: String(localized: "This document blends colours in linear light. Other programs blend these layers in gamma, so the layers will look different there; the flattened picture in the file is right.")
        case .writtenInSRGB: String(localized: "The document's colours are Display P3; the file is written in sRGB.")
        case .curveDrawnDifferently: String(localized: "It is written as a Curves layer with points added along the curve, so that it looks the same in programs that draw curves their own way. It has more points to edit there.")
        case .flattenedByChoice: String(localized: "All layers are merged into one, as chosen: the file looks right everywhere and has no layers to edit.")
        }
    }
}

/// File › Export… › Photoshop File…: says what the file will hold before it is saved, and
/// for a document that blends in linear light offers to merge the layers instead.
struct PSDExportSheet: View {
    let session: EditorSession
    @Environment(\.dismiss) private var dismiss
    @State private var depth = 8
    @State private var flattened = false
    @State private var prepared: (data: Data, report: PSDExportReport)?
    @State private var problem: String?
    @State private var working = false

    private var isLinear: Bool { session.state.blendSpace == .linear }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Export as Photoshop File").font(.headline)
            Picker("Bit depth", selection: $depth) {
                Text("8 bits per channel").tag(8)
                Text("16 bits per channel").tag(16)
            }
            if isLinear {
                Picker("Layers", selection: $flattened) {
                    Text("As they are").tag(false)
                    Text("Merged into one layer").tag(true)
                }
            }
            if working { ProgressView().controlSize(.small).accessibilityLabel("Preparing the file") }
            if let problem { Label(problem, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red) }
            if let report = prepared?.report {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(report.notes.isEmpty
                             ? String(localized: "Every layer is written as it is: \(report.layersWritten) layers and groups.")
                             : String(localized: "\(report.layersWritten) layers and groups are written. These things are not written as they are:"))
                            .fontWeight(.medium).fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
                        ForEach(Array(report.notes.enumerated()), id: \.offset) { _, note in
                            Text(verbatim: (note.layer.map { "“\($0)”: " } ?? "") + note.localized)
                                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
                        }
                        if let difference = report.gammaDifference, !flattened {
                            let percent = (difference.shareVisible * 100).formatted(.number.precision(.fractionLength(1))), level = difference.mean.formatted(.number.precision(.fractionLength(1)))
                            Text("Measured on this document: blended as other programs do, the layers differ from what you see here on \(percent) % of the pixels visibly, \(level) of 255 on average.")
                                .font(.callout).fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                // The list can be longer than the sheet: the scroll bar is always shown, so a row cut at the edge reads as "there is more".
                .scrollIndicators(.visible)
                .frame(maxHeight: 280)
                // macOS shows a scroll bar only while scrolling: said in words, so a row cut at the edge is not taken for the end.
                if report.notes.count > 4 {
                    Text("\(report.notes.count) points in all. Scroll the list to read them.").font(.callout).foregroundStyle(.secondary)
                }
            }
            Text("Text, smart objects and effects can't be edited as such in the file. Glimmer has read its own Photoshop files back and macOS shows their picture; the layers have not been tried in Photoshop.")
                .font(.callout).foregroundStyle(.secondary)
                // Never cut short: seen as "…have not been tri…" in a small window (2026-11-16); the list above gives way instead.
                .fixedSize(horizontal: false, vertical: true).layoutPriority(1)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save…") { save() }.keyboardShortcut(.defaultAction).disabled(prepared == nil || working)
            }
        }
        .padding(20)
        .frame(width: 540)
        .task(id: "\(depth)-\(flattened)") { await prepare() }
    }

    private func prepare() async {
        guard let metal = MetalContext.shared else { problem = String(localized: "No Metal GPU available."); return }
        session.commitLiveEdit()
        let state = session.state, depth = depth, flattened = flattened
        working = true; problem = nil; prepared = nil
        defer { working = false }
        do {
            prepared = try await Task.detached(priority: .userInitiated) { try PSDExport.data(for: state, depth: depth, flattened: flattened, context: metal) }.value
        } catch {
            problem = PersonMessage.text(for: error)
        }
    }

    private func save() {
        guard let data = prepared?.data else { return }
        let panel = NSSavePanel()
        if let type = UTType("com.adobe.photoshop-image") { panel.allowedContentTypes = [type] }
        panel.nameFieldStringValue = "Untitled.psd"
        panel.canCreateDirectories = true
        let session = session
        dismiss()
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in
                do {
                    try data.write(to: url, options: .atomic)
                    session.showToast(String(localized: "Exported \(url.lastPathComponent) (\(ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file)))."))
                } catch {
                    session.report(error)
                }
            }
        }
    }
}
#endif
