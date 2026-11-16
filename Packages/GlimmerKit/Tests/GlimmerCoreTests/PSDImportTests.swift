import Foundation
import Testing
@testable import GlimmerCore
import PSDTestSupport

/// A Photoshop file becomes a Glimmer document, and the report says what did not survive.
@Suite struct PSDImportTests {
    static let limits = PSDFile.Limits(maxCanvasPixels: 1_000_000, maxDecodedBytes: 4_000_000)
    typealias L = PSDTestWriter.Layer
    static let unit = PSDFile.Rect(top: 0, left: 0, bottom: 2, right: 2)
    static func pixels(_ name: String, blend: String = "norm") -> L {
        L(name: name, rect: unit, blendKey: blend, planes: [(0, [1, 2, 3, 4]), (1, [1, 2, 3, 4]), (2, [1, 2, 3, 4])])
    }
    static func file(_ layers: [L]) -> Data {
        var w = PSDTestWriter()
        w.layers = layers
        w.composite = [[0, 0, 0, 0], [0, 0, 0, 0], [0, 0, 0, 0]]
        return w.data()
    }

    @Test(arguments: [8, 16])
    func layersGroupsAndMasksComeThrough(depth: Int) throws {
        let (state, report) = try PSDImport.document(from: PSDTestWriter.sample(depth: depth).data(), limits: Self.limits)
        #expect(state.width == 4 && state.height == 3 && state.blendSpace == .gamma)
        #expect(state.layers.map(\.name) == ["Background copy", "Group 1"])
        guard case .group(let group) = state.layers[1].content else { Issue.record("not a group"); return }
        #expect(group.isExpanded && group.children.map(\.name) == ["Blå himmel", "Hidden"])
        #expect(state.layers[1].blendMode == .passThrough)
        let sky = group.children[0], hidden = group.children[1]
        #expect(sky.blendMode == .multiply && abs(sky.opacity - 128.0 / 255) < 1e-9 && sky.isVisible && !sky.isClipped)
        #expect(sky.mask?.defaultValue == 1 && sky.mask?.isEnabled == true && sky.mask?.tiles.isEmpty == false)
        #expect(!hidden.isVisible && hidden.isClipped)
        if case .raster(let tiles) = sky.content { #expect(!tiles.isEmpty) } else { Issue.record("not pixels") }
        // The report: four layers in the file (the group counts, its end mark doesn't), all kept, one note about the text.
        #expect(report.layersInFile == 4 && report.layersKept == 4 && report.groupsKept == 1 && !report.flattened)
        #expect(report.notes == [.init(.wasText, layer: "Hidden")])
        #expect(state.importReport == report)   // the report travels in the document
        #expect(report.looksTheSame)
        #expect(report.lines.first == "4 of 4 layers came through as layers (RGB, \(depth) bits per channel). 1 thing did not come through as it was:")
        #expect(report.lines.last == "“Hidden”: It was text and is now pixels: the words can't be edited as text.")
    }

    @Test func nothingLostIsSaidInOneLine() throws {
        let (_, report) = try PSDImport.document(from: Self.file([Self.pixels("One"), Self.pixels("Two")]), limits: Self.limits)
        #expect(report.notes.isEmpty && report.lines == ["Everything came through: 2 layers (RGB, 8 bits per channel)."])
    }

    @Test func whatGlimmerDoesNotHaveIsNamedNeverDropped() throws {
        var levels = L(name: "Levels 1", rect: PSDFile.Rect(top: 0, left: 0, bottom: 0, right: 0))
        levels.extraBlocks = [("levl", Data([0, 2]))]
        var fill = L(name: "Color Fill 1", rect: PSDFile.Rect(top: 0, left: 0, bottom: 0, right: 0))
        fill.extraBlocks = [("SoCo", Data([0, 0, 0, 16])), ("vmsk", Data([0, 0, 0, 3]))]
        var glow = Self.pixels("Glow", blend: "lgCl")
        glow.extraBlocks = [("lfx2", Data([0, 0])), ("SoLd", Data([0, 0]))]
        let (state, report) = try PSDImport.document(from: Self.file([Self.pixels("Photo"), levels, fill, glow, Self.pixels("Speckle", blend: "diss")]), limits: Self.limits)
        #expect(state.layers.map(\.name) == ["Photo", "Glow", "Speckle"])
        #expect(state.layers.map(\.blendMode) == [.normal, .normal, .normal])
        #expect(report.layersInFile == 5 && report.layersKept == 3 && !report.looksTheSame)
        let said = report.notes.map { "\($0.layer ?? "-"): \($0.what)" }
        #expect(said == [
            "Levels 1: It was a Levels adjustment layer. Adjustment layers are not read in this version, so it was left out.",
            "Color Fill 1: It was a solid colour fill or shape layer. Those are not read in this version, so it was left out.",
            "Glow: The blend mode Lighter Color became Normal: Glimmer doesn't have it.",
            "Glow: Its layer effects (shadows, strokes, glows) were not read.",
            "Glow: It was a smart object and is now pixels. The file placed in it is not kept in this version.",
            "Speckle: The blend mode Dissolve became Normal: Glimmer doesn't have it.",
        ])
        #expect(report.lines.first == "3 of 5 layers came through as layers (RGB, 8 bits per channel). 6 things did not come through as it was:")
    }

    @Test func damagedGroupStructureKeepsTheLayersAndSaysSo() throws {
        // A group record with no end mark below it, and an end mark with no group record above it.
        let folder = L(name: "Lonely", rect: PSDFile.Rect(top: 0, left: 0, bottom: 0, right: 0), blendKey: "pass", group: 1)
        let (a, first) = try PSDImport.document(from: Self.file([Self.pixels("A"), folder]), limits: Self.limits)
        #expect(a.layers.map(\.name) == ["A", "Lonely"] && first.notes.map(\.what) == ["The group's end is missing in the file; it came in empty."])
        let end = L(name: "</Layer group>", rect: PSDFile.Rect(top: 0, left: 0, bottom: 0, right: 0), group: 3)
        let (b, second) = try PSDImport.document(from: Self.file([Self.pixels("A"), end, Self.pixels("B")]), limits: Self.limits)
        #expect(b.layers.map(\.name) == ["A", "B"] && second.notes.count == 1 && second.notes[0].layer == nil)
        // Groups nested without end: refused, not followed down.
        let deep = Array(repeating: end, count: 70) + [Self.pixels("Bottom")]
        #expect(throws: PSDFile.Problem.self) { _ = try PSDImport.document(from: Self.file(deep), limits: Self.limits) }
    }

    @Test func aLayerWithMissingPlanesComesInEmptyAndIsNamed() throws {
        let broken = L(name: "Half", rect: Self.unit, planes: [(0, [1, 2, 3, 4])])   // red only
        let (state, report) = try PSDImport.document(from: Self.file([broken]), limits: Self.limits)
        #expect(state.layers.count == 1 && report.notes.map(\.what) == ["Its pixels are incomplete in the file, so the layer came in empty."])
        #expect(!report.looksTheSame)
    }

    @Test func otherColourModesAreSaidPlainly() {
        #expect(PSDImport.describe(PSDFile.Header(isLarge: false, channels: 4, width: 1, height: 1, depth: 8, mode: .cmyk)) == "CMYK, 8 bits per channel")
        #expect(PSDImport.describe(PSDFile.Header(isLarge: true, channels: 3, width: 1, height: 1, depth: 32, mode: .rgb)) == "RGB, 32 bits per channel, large document format")
        #expect(PSDImport.describe(PSDFile.Header(isLarge: false, channels: 1, width: 1, height: 1, depth: 1, mode: .bitmap)) == "Bitmap, 1 bit per channel")
    }

    /// Whatever is done to the bytes, an import throws or gives a document with a report: no crash.
    @Test func aDamagedFileNeverCrashesTheImport() {
        let good = PSDTestWriter.sample(compression: 1).data()
        var imported = 0
        for index in good.indices {
            for value: UInt8 in [0x00, 0xFF] where good[index] != value {
                var bad = good
                bad[index] = value
                if let result = try? PSDImport.document(from: bad, limits: Self.limits) {
                    imported += 1
                    #expect(result.state.width >= 1 && result.state.height >= 1)
                }
            }
        }
        #expect(imported > 0)   // changes inside pixel data still import
    }
}

/// The report is part of the document: saved with it and read back.
@Suite struct PSDImportReportTests {
    @Test func theReportIsSavedWithTheDocumentAndReadBack() throws {
        var (state, report) = try PSDImport.document(from: PSDTestWriter.sample().data(), limits: PSDImportTests.limits)
        report.meanDifference = 0.5; report.shareVisiblyDifferent = 0.25
        state.importReport = report
        let wrapper = try GlimmerPackage.fileWrapper(for: state)
        let back = try GlimmerPackage.state(from: wrapper)
        #expect(back.importReport == report && back.importReport?.notes.first?.kind == .wasText)
        #expect(back.importReport?.matchesTheFile == false)
        // A document that was never a Photoshop file has none, and its manifest doesn't mention one.
        let plain = try GlimmerPackage.fileWrapper(for: DocumentState(width: 4, height: 4))
        #expect(try GlimmerPackage.state(from: plain).importReport == nil)
        let manifest = try #require(plain.fileWrappers?["manifest.json"]?.regularFileContents)
        #expect(!String(decoding: manifest, as: UTF8.self).contains("importReport"))
    }
}
