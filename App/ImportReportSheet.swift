#if GLIMMER_PSD   // Config/Features.xcconfig switches this
import GlimmerCore
import SwiftUI

/// The import report in the person's language. (The core has the same in English for the agent API.)
extension PSDImportReport {
    var summaryLine: String {
        if flattened { return String(localized: "Opened as one layer: the file's own flattened picture (\(source)).") }
        if notes.isEmpty { return String(localized: "Everything came through: \(layersKept) layers, \(groupsKept) of them groups (\(source)).") }
        return String(localized: "\(layersKept) of \(layersInFile) layers came through as layers (\(source)). These things did not come through as they were:")
    }

    var pictureLine: String? {
        guard let matches = matchesTheFile, let mean = meanDifference, let share = shareVisiblyDifferent else { return nil }
        if matches { return String(localized: "Glimmer's picture matches the one saved in the file.") }
        let percent = (share * 100).formatted(.number.precision(.fractionLength(1))), level = mean.formatted(.number.precision(.fractionLength(1)))
        return String(localized: "Glimmer's picture differs from the one saved in the file: \(percent) % of the pixels visibly, \(level) of 255 on average.")
    }
}

extension PSDImportReport.Note {
    var localized: String {
        let detail = detail ?? ""
        return switch kind {
        case .wasText: detail.isEmpty ? String(localized: "It was text and is now pixels: the words can't be edited as text.")
                                      : String(localized: "It was text (“\(detail)”) and is now pixels: the words can't be edited as text.")
        case .curvesMayDiffer: String(localized: "It is a Curves adjustment with the same points. Between the points the curve may run a little differently than in Photoshop.")
        case .wasSmartObject: String(localized: "It was a smart object and is now pixels. The file placed in it is not kept in this version.")
        case .adjustmentLeftOut: String(localized: "It was a \(detail) adjustment layer. That kind is not read in this version, so it was left out.")
        case .fillLeftOut: String(localized: "It was a fill or shape layer (\(detail)). That kind is not read in this version, so it was left out.")
        case .effectsNotRead: String(localized: "Its layer effects (shadows, strokes, glows) were not read.")
        case .vectorMaskNotRead: String(localized: "Its vector mask was not read; the layer's pixels are shown whole.")
        case .blendModeBecameNormal: String(localized: "The blend mode \(detail) became Normal: Glimmer doesn't have it.")
        case .pixelsIncomplete: String(localized: "Its pixels are incomplete in the file, so the layer came in empty.")
        case .groupEndMissing: String(localized: "The group's end is missing in the file; it came in empty.")
        case .groupRecordMissing: String(localized: "A group in the file has no record of its own; its layers came in without the group.")
        case .layersNotRead: String(localized: "Glimmer reads the layers of RGB and grayscale files with 8 or 16 bits per channel. This file is \(detail). Its layers were not read; the picture is the one saved in the file.")
        }
    }
}

/// What came through when a Photoshop file was opened, and what did not. Shown when the file
/// opens and from File › Import Report…: an import never happens silently.
struct ImportReportSheet: View {
    let session: EditorSession
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Import Report").font(.headline)
            if let report = session.importReport {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(verbatim: report.summaryLine).fontWeight(.medium).frame(maxWidth: .infinity, alignment: .leading)
                        ForEach(Array(report.notes.enumerated()), id: \.offset) { _, note in
                            Text(verbatim: (note.layer.map { "“\($0)”: " } ?? "") + note.localized)
                                .font(.callout).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                        }
                        if let picture = report.pictureLine {
                            Text(verbatim: picture).font(.callout).frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .frame(maxHeight: 320)
                Text("The Photoshop file itself is not changed. This is a new Glimmer document, and the report is saved with it: File › Import Report… shows it again.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("OK") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 520)
    }
}
#endif
