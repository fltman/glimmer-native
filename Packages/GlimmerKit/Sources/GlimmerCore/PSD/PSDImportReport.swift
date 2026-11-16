import Foundation

/// What an import of a Photoshop file kept, changed and lost. It is made by the same call that
/// makes the document, so there is no way to import without one, and it is saved with the
/// document: it is the record of what the file lost.
///
/// The notes are kinds with their particulars, not sentences, so the app can say them in the
/// person's language. (This type is in every build; the import itself is behind GLIMMER_PSD.)
public struct PSDImportReport: Sendable, Equatable, Codable {
    public enum Kind: String, Sendable, Codable {
        case wasText, wasSmartObject, adjustmentLeftOut, fillLeftOut, effectsNotRead, vectorMaskNotRead
        case blendModeBecameNormal, pixelsIncomplete, groupEndMissing, groupRecordMissing, layersNotRead
    }

    public struct Note: Sendable, Equatable, Codable {
        public var kind: Kind
        /// The layer the note is about; nil for the document as a whole.
        public var layer: String?
        /// The particular: the adjustment's name, the blend mode's name, the kind of fill, the file's mode.
        public var detail: String?
        /// True when the picture may look different because of it.
        public var changesLook: Bool

        public init(_ kind: Kind, layer: String? = nil, detail: String? = nil, changesLook: Bool = false) {
            self.kind = kind; self.layer = layer; self.detail = detail; self.changesLook = changesLook
        }
    }

    /// "RGB, 8 bits per channel" and the like, as the file says.
    public var source: String
    /// How many layers and groups the file had, and how many of them came in as layers of their own.
    public var layersInFile = 0
    public var layersKept = 0
    public var groupsKept = 0
    /// True when only the file's flattened picture was used.
    public var flattened = false
    public var notes: [Note] = []
    /// How far Glimmer's picture of the layers is from the picture the file carries: the mean
    /// difference per channel on a scale of 0 to 255, and the share of pixels that differ by
    /// more than 8. Filled in by the app, which can draw; nil when it wasn't measured.
    public var meanDifference: Double?
    public var shareVisiblyDifferent: Double?

    public init(source: String) { self.source = source }

    public var looksTheSame: Bool { !notes.contains(where: \.changesLook) }
    /// Whether the measured picture matches the file's own (nil when it wasn't measured).
    public var matchesTheFile: Bool? {
        guard let mean = meanDifference, let share = shareVisiblyDifferent else { return nil }
        return share < 0.001 && mean < 1
    }
}

#if GLIMMER_PSD
extension PSDImportReport.Note {
    /// The note in English, for the agent API and the logs. The app says it in the person's language.
    public var what: String {
        let detail = detail ?? ""
        return switch kind {
        case .wasText: "It was text and is now pixels: the words can't be edited as text."
        case .wasSmartObject: "It was a smart object and is now pixels. The file placed in it is not kept in this version."
        case .adjustmentLeftOut: "It was a \(detail) adjustment layer. Adjustment layers are not read in this version, so it was left out."
        case .fillLeftOut: "It was a \(detail) fill or shape layer. Those are not read in this version, so it was left out."
        case .effectsNotRead: "Its layer effects (shadows, strokes, glows) were not read."
        case .vectorMaskNotRead: "Its vector mask was not read; the layer's pixels are shown whole."
        case .blendModeBecameNormal: "The blend mode \(detail) became Normal: Glimmer doesn't have it."
        case .pixelsIncomplete: "Its pixels are incomplete in the file, so the layer came in empty."
        case .groupEndMissing: "The group's end is missing in the file; it came in empty."
        case .groupRecordMissing: "A group in the file has no record of its own; its layers came in without the group."
        case .layersNotRead: "Glimmer reads the layers of RGB and grayscale files with 8 or 16 bits per channel. This file is \(detail). Its layers were not read; the picture is the one saved in the file."
        }
    }
}

extension PSDImportReport {
    /// The report as lines in English, the summary first.
    public var lines: [String] {
        var out: [String] = []
        if flattened {
            out.append("Opened as one layer: the file's own flattened picture (\(source)).")
        } else if notes.isEmpty {
            out.append("Everything came through: \(layersKept) \(layersKept == 1 ? "layer" : "layers")\(groupsKept > 0 ? " in \(groupsKept) \(groupsKept == 1 ? "group" : "groups")" : "") (\(source)).")
        } else {
            out.append("\(layersKept) of \(layersInFile) layers came through as layers (\(source)). \(notes.count) \(notes.count == 1 ? "thing" : "things") did not come through as it was:")
        }
        out += notes.map { ($0.layer.map { "“\($0)”: " } ?? "") + $0.what }
        if let matches = matchesTheFile, let mean = meanDifference, let share = shareVisiblyDifferent {
            out.append(matches
                ? "Glimmer's picture matches the one saved in the file."
                : String(format: "Glimmer's picture differs from the one saved in the file: %.1f %% of the pixels visibly, %.1f of 255 on average.", share * 100, mean))
        }
        return out
    }
}
#endif
