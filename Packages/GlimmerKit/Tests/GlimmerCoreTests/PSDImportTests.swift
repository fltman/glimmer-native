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
        var glow = Self.pixels("Glow", blend: "diss")
        glow.extraBlocks = [("lfx2", Data([0, 0])), ("SoLd", Data([0, 0]))]
        let (state, report) = try PSDImport.document(from: Self.file([Self.pixels("Photo"), levels, fill, glow, Self.pixels("Speckle", blend: "diss"), Self.pixels("Lighter", blend: "lgCl"), Self.pixels("Darker", blend: "dkCl")]), limits: Self.limits)
        #expect(state.layers.map(\.name) == ["Photo", "Glow", "Speckle", "Lighter", "Darker"])
        // Lighter Color and Darker Color are Glimmer's own modes now; Dissolve is not.
        #expect(state.layers.map(\.blendMode) == [.normal, .normal, .normal, .lighterColor, .darkerColor])
        #expect(report.layersInFile == 7 && report.layersKept == 5 && !report.looksTheSame)
        let said = report.notes.map { "\($0.layer ?? "-"): \($0.what)" }
        #expect(said == [
            "Levels 1: It was a Levels adjustment layer. That kind is not read in this version, so it was left out.",
            "Color Fill 1: It was a solid colour fill or shape layer. That kind is not read in this version, so it was left out.",
            "Glow: The blend mode Dissolve became Normal: Glimmer doesn't have it.",
            "Glow: Its layer effects (shadows, strokes, glows) were not read.",
            "Glow: It was a smart object and is now pixels. The file placed in it is not kept in this version.",
            "Speckle: The blend mode Dissolve became Normal: Glimmer doesn't have it.",
        ])
        #expect(report.lines.first == "5 of 7 layers came through as layers (RGB, 8 bits per channel). 6 things did not come through as it was:")
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
    /// A CMYK file saved without its flattened picture would open as a blank page: refused, with what to do.
    @Test func aFileWithNeitherReadableLayersNorAPictureIsRefusedNotShownBlank() throws {
        var data = Self.file([Self.pixels("Photo")])
        data[25] = 4   // the header's colour mode: CMYK
        data.replaceSubrange(30..<34, with: [0, 0, 0, 18])   // (these files have no colour data and no resources)
        data.insert(contentsOf: Array("8BIM".utf8) + [0x04, 0x21, 0, 0, 0, 0, 0, 6, 0, 0, 0, 1, 0, 0], at: 34)
        #expect(PSDFile.hasFlattenedPicture(data) == false)
        #expect { _ = try PSDImport.document(from: data, limits: Self.limits) } throws: { error in
            ((error as? PSDFile.Problem)?.errorDescription ?? "").contains("saved without a flattened picture")
        }
    }

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

/// Fills, shapes, the adjustment layers with documented data, and a text layer's words.
@Suite struct PSDSettingsTests {
    typealias L = PSDTestWriter.Layer
    static let empty = PSDFile.Rect(top: 0, left: 0, bottom: 0, right: 0)
    static func block(_ name: String, _ blocks: [(String, Data)]) -> L { var l = L(name: name, rect: empty); l.extraBlocks = blocks; return l }

    @Test func aDescriptorIsReadAsTheSpecificationLaysItOut() throws {
        let inner = PSDTestWriter.descriptor("RGBC", [("Rd  ", "doub", PSDTestWriter.double(255)), ("name with length", "TEXT", PSDTestWriter.unicode("Blå"))])
        let list = PSDTestWriter.be32(2) + Data("long".utf8) + PSDTestWriter.be32(7) + Data("bool".utf8) + Data([1])
        let unit = Data("#Pxl".utf8) + PSDTestWriter.double(12.5)
        let enumerated = PSDTestWriter.id("Ornt") + PSDTestWriter.id("Hrzn")
        let data = PSDTestWriter.descriptor("null", [("Clr ", "Objc", inner), ("List", "VlLs", list), ("Sz  ", "UntF", unit), ("Ornt", "enum", enumerated)])
        let value = try PSDDescriptor.read(data)
        #expect(value["Clr "]?["Rd  "] == .double(255) && value["Clr "]?["name with length"] == .string("Blå"))
        #expect(value["List"] == .list([.integer(7), .boolean(true)]))
        #expect(value["Sz  "] == .unitFloat(unit: "#Pxl", value: 12.5) && value["Ornt"] == .enumerated(type: "Ornt", value: "Hrzn"))
        // Cut anywhere, or with a type nobody knows: an error, never a crash.
        for length in 0..<data.count { #expect(throws: PSDFile.Problem.self) { _ = try PSDDescriptor.read(data.prefix(length)) } }
        #expect(throws: PSDFile.Problem.self) { _ = try PSDDescriptor.read(PSDTestWriter.descriptor("null", [("x   ", "wxyz", Data([0, 0, 0, 0]))])) }
        // A descriptor nested without end is refused by its depth.
        var deep = PSDTestWriter.descriptor("leaf", [])
        for _ in 0..<40 { deep = PSDTestWriter.descriptor("node", [("next", "Objc", deep)]) }
        #expect(throws: PSDFile.Problem.self) { _ = try PSDDescriptor.read(deep) }
    }

    @Test func aShapeComesInAsARealFillLayerWithItsOutline() throws {
        let corners = [(x: 0.25, y: 0.25), (x: 0.75, y: 0.25), (x: 0.75, y: 0.75), (x: 0.25, y: 0.75)]
        let shape = Self.block("Rectangle 1", [("SoCo", PSDTestWriter.solidColor(red: 255, green: 128, blue: 0)), ("vmsk", PSDTestWriter.vectorMask(corners))])
        let plain = Self.block("Color Fill 1", [("SoCo", PSDTestWriter.solidColor(red: 0, green: 0, blue: 255))])
        var w = PSDTestWriter()
        w.width = 8; w.height = 8
        w.layers = [PSDImportTests.pixels("Photo"), plain, shape]
        w.composite = Array(repeating: Array(repeating: 0, count: 64), count: 3)
        let (state, report) = try PSDImport.document(from: w.data(), limits: PSDImportTests.limits)
        #expect(state.layers.map(\.name) == ["Photo", "Color Fill 1", "Rectangle 1"] && report.notes.isEmpty && report.layersKept == 3)
        #expect(state.layers[1].content.theFill == .solid(SRGBColor(0, 0, 1)) && state.layers[1].vectorMask == nil)
        let rectangle = state.layers[2]
        #expect(rectangle.content.theFill == .solid(SRGBColor(1, 128.0 / 255, 0)))
        let anchors = try #require(rectangle.vectorMask?.subpaths.first).anchors.map(\.point)
        #expect(anchors == [SIMD2(2, 2), SIMD2(6, 2), SIMD2(6, 6), SIMD2(2, 6)] && rectangle.vectorMask?.subpaths.first?.isClosed == true)
        #expect(rectangle.mask?.tiles.isEmpty == false && rectangle.mask?.isEnabled == true)
        // An outline and a painted mask on one shape (found in a file from Photoshop: the painted
        // mask used to be dropped silently). They become one mask, and the report says so.
        var both = Self.block("Masked shape", [("SoCo", PSDTestWriter.solidColor(red: 255, green: 0, blue: 0)), ("vmsk", PSDTestWriter.vectorMask(corners))])
        // The painted mask hides the left half of the canvas (0) and shows the right half (255).
        both.mask = (rect: PSDFile.Rect(top: 0, left: 0, bottom: 8, right: 8), color: 0, pixels: (0..<64).map { $0 % 8 < 4 ? 0 : 255 })
        w.layers = [PSDImportTests.pixels("Photo"), both]
        let (merged, mergedReport) = try PSDImport.document(from: w.data(), limits: PSDImportTests.limits)
        #expect(mergedReport.notes.map(\.kind) == [.masksMerged] && mergedReport.looksTheSame)
        let one = try #require(merged.layers.last?.mask)
        #expect(merged.layers.last?.vectorMask == nil)
        let values = one.tiles[TileCoord(0, 0)]?.pixels() ?? []
        func shown(_ x: Int, _ y: Int) -> Float { values.isEmpty ? -1 : Float(values[(y * TileGeometry.size + x) * 4 + 3]) }
        // Inside the outline (2…6) and in the shown half: there. Inside the outline but hidden by the paint: not. Outside the outline: not.
        #expect(shown(5, 4) == 1 && shown(3, 4) == 0 && shown(7, 7) == 0)
        // An inverted outline is something Glimmer's shapes don't have: left out, and said.
        let inverted = Self.block("Hole", [("SoCo", PSDTestWriter.solidColor(red: 1, green: 2, blue: 3)), ("vmsk", PSDTestWriter.vectorMask(corners, flags: 1))])
        w.layers = [PSDImportTests.pixels("Photo"), inverted]
        let (other, second) = try PSDImport.document(from: w.data(), limits: PSDImportTests.limits)
        #expect(other.layers.map(\.name) == ["Photo"] && second.notes.map(\.kind) == [.fillLeftOut])
    }

    @Test func invertLevelsAndCurvesComeInAsAdjustmentLayers() throws {
        let levels = Self.block("Levels 1", [("levl", PSDTestWriter.levels([(10, 240, 0, 255, 120), (0, 255, 20, 235, 100)]))])
        let curves = Self.block("Curves 1", [("curv", PSDTestWriter.curves([[(0, 0), (128, 160), (255, 255)]]))])
        let invert = Self.block("Invert 1", [("nvrt", Data())])
        let vibrance = Self.block("Vibrance 1", [("vibA", Data([0, 0, 0, 16]))])
        let (state, report) = try PSDImport.document(from: PSDImportTests.file([PSDImportTests.pixels("Photo"), levels, curves, invert, vibrance]), limits: PSDImportTests.limits)
        #expect(state.layers.map(\.name) == ["Photo", "Levels 1", "Curves 1", "Invert 1"])
        let l = try #require(state.layers[1].content.theAdjustment)
        #expect(l.kind == .levels && l.levels[.rgb] == LevelsChannel(inBlack: 10.0 / 255, inWhite: 240.0 / 255, gamma: 1.2, outBlack: 0, outWhite: 1))
        #expect(l.levels[.red] == LevelsChannel(inBlack: 0, inWhite: 1, gamma: 1, outBlack: 20.0 / 255, outWhite: 235.0 / 255) && l.levels[.blue] == LevelsChannel())
        let c = try #require(state.layers[2].content.theAdjustment)
        #expect(c.kind == .curves && c.curves[.rgb] == [CurvePoint(0, 0), CurvePoint(128.0 / 255, 160.0 / 255), CurvePoint(1, 1)])
        #expect(state.layers[3].content.theAdjustment?.kind == .invert)
        #expect(c.usesNaturalCurve)   // drawn between its points as Photoshop draws it
        #expect(report.notes.map(\.kind) == [.adjustmentLeftOut] && report.notes[0].detail == "Vibrance")
        // Settings outside what the specification allows are not guessed at: the layer is left out and named.
        let bad = Self.block("Levels 2", [("levl", PSDTestWriter.levels([(250, 10, 0, 255, 100)]))])
        let (_, second) = try PSDImport.document(from: PSDImportTests.file([PSDImportTests.pixels("Photo"), bad]), limits: PSDImportTests.limits)
        #expect(second.notes.map(\.kind) == [.adjustmentLeftOut])
    }

    @Test func aTextLayersWordsAreInTheReport() throws {
        var title = PSDImportTests.pixels("Title")
        title.extraBlocks = [("TySh", PSDTestWriter.typeTool("Hello world"))]
        let (state, report) = try PSDImport.document(from: PSDImportTests.file([title]), limits: PSDImportTests.limits)
        #expect(report.notes == [.init(.wasText, layer: "Title", detail: "Hello world")])
        // The words stay on the layer, and are saved with it.
        #expect(state.layers.first?.formerText == "Hello world")
        #expect(try GlimmerPackage.state(from: GlimmerPackage.fileWrapper(for: state)).layers.first?.formerText == "Hello world")
        #expect(report.notes[0].what == "It was text (“Hello world”) and is now pixels: the words can't be edited as text.")
    }
}

private extension LayerContent {
    var theFill: Fill? { if case .fill(let f) = self { f } else { nil } }
    var theAdjustment: Adjustment? { if case .adjustment(let a) = self { a } else { nil } }
}

@Suite struct PSDTimeLimitTests {
    @Test func aFileThatTakesTooLongIsGivenUpOn() {
        var limits = PSDImportTests.limits
        limits.seconds = -1   // the time is already up
        #expect(throws: PSDFile.tookTooLong) { _ = try PSDFile(PSDTestWriter.sample().data(), limits: limits) }
        #expect(PSDFile.tookTooLong.message == "This Photoshop file takes too long to read, so Glimmer gave up on it.")
    }
}
