#if GLIMMER_PSD   // Config/Features.xcconfig switches this
import GlimmerCore
import SwiftUI

/// The import report in the person's language. (The core has the same in English for the agent API.)
extension PSDImportReport {
    /// "RGB, 8 bits per channel" as the report keeps it, said in the person's language: it is Glimmer describing the file.
    var localizedSource: String {
        source.components(separatedBy: ", ").map { part in
            if let bits = Int(part.prefix { $0.isNumber }), part.hasSuffix("per channel") {
                return bits == 1 ? String(localized: "1 bit per channel") : String(localized: "\(bits) bits per channel")
            }
            return PersonMessage.text(part)   // the colour mode's name, or "large document format"
        }.joined(separator: ", ")
    }

    var summaryLine: String {
        if flattened { return String(localized: "Opened as one layer: the file's own flattened picture (\(localizedSource)).") }
        if notes.isEmpty { return String(localized: "Everything came through: \(layersKept) layers, \(groupsKept) of them groups (\(localizedSource)).") }
        return String(localized: "\(layersKept) of \(layersInFile) layers came through as layers (\(localizedSource)). These things did not come through as they were:")
    }

    var pictureLine: String? {
        if fileHasNoPicture == true { return String(localized: "The file carries no flattened picture of its own (it was saved with Maximize Compatibility off), so Glimmer's picture could not be compared with it.") }
        guard let matches = matchesTheFile, let mean = meanDifference, let share = shareVisiblyDifferent else { return nil }
        if matches { return String(localized: "Glimmer's picture matches the one saved in the file.") }
        let percent = (share * 100).formatted(.number.precision(.fractionLength(1))), level = mean.formatted(.number.precision(.fractionLength(1)))
        return String(localized: "Glimmer's picture differs from the one saved in the file: \(percent) % of the pixels visibly, \(level) of 255 on average.")
    }
}

extension PSDImportReport.Note {
    var localized: String {
        // The particular: an adjustment's or blend mode's name, a kind of fill, the file's colour mode. Glimmer's own
        // names for these are said in the person's language; the words of a text layer are the file's and stay as they are.
        var detail = detail ?? ""
        switch kind {
        case .adjustmentLeftOut, .fillLeftOut, .blendModeBecameNormal: detail = PersonMessage.text(detail)
        case .layersNotRead: detail = PSDImportReport(source: detail).localizedSource
        default: break
        }
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
        case .masksMerged: String(localized: "It had an outline and a painted mask. The two are now one mask, so the outline can't be edited as a path.")
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
                // The list can be longer than the sheet: the scroll bar is always shown, so a row cut at the edge reads as "there is more".
                .scrollIndicators(.visible)
                .frame(maxHeight: 320)
                // macOS shows a scroll bar only while scrolling: said in words, so a row cut at the edge is not taken for the end.
                if report.notes.count > 5 {
                    Text("\(report.notes.count) points in all. Scroll the list to read them.").font(.callout).foregroundStyle(.secondary)
                }
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
