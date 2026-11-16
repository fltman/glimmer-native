import Foundation
import Testing
@testable import GlimmerCore
@testable import GlimmerRender
import PSDTestSupport

/// An imported file is compared with the flattened picture the file itself carries.
@Suite struct PSDAppearanceTests {
    static let limits = PSDFile.Limits(maxCanvasPixels: 1_000_000, maxDecodedBytes: 16_000_000)

    /// An 8 × 8 document: an opaque gradient, and over it a half-transparent red square in Multiply.
    /// `composite` is what the file claims the result looks like.
    static func writer(depth: Int, top: Bool, blend: String = "mul ", opacity: UInt8 = 255, composite: (Int, Int) -> (Int, Int, Int)) -> PSDTestWriter {
        var w = PSDTestWriter()
        w.depth = depth; w.width = 8; w.height = 8
        let scale: (Int) -> UInt16 = { depth == 16 ? UInt16($0) * 257 : UInt16($0) }
        let full = PSDFile.Rect(top: 0, left: 0, bottom: 8, right: 8)
        func plane(_ value: (Int, Int) -> Int) -> [UInt16] { (0..<64).map { scale(value($0 % 8, $0 / 8)) } }
        var layers = [PSDTestWriter.Layer(name: "Gradient", rect: full, planes: [(0, plane { x, _ in 40 + x * 25 }), (1, plane { _, y in 40 + y * 25 }), (2, plane { _, _ in 128 })], compression: 1)]
        if top {
            let square = PSDFile.Rect(top: 2, left: 2, bottom: 6, right: 6)
            layers.append(PSDTestWriter.Layer(name: "Red", rect: square, blendKey: blend, opacity: opacity,
                                              planes: [(-1, Array(repeating: scale(255), count: 16)), (0, Array(repeating: scale(255), count: 16)),
                                                       (1, Array(repeating: scale(128), count: 16)), (2, Array(repeating: scale(128), count: 16))], compression: 2))
        }
        w.layers = layers
        w.composite = [plane { x, y in composite(x, y).0 }, plane { x, y in composite(x, y).1 }, plane { x, y in composite(x, y).2 }]
        return w
    }

    /// What Photoshop's Multiply gives, in gamma-encoded values: base × blend / 255.
    static func expected(_ x: Int, _ y: Int, top: Bool) -> (Int, Int, Int) {
        let r = 40 + x * 25, g = 40 + y * 25, b = 128
        guard top, (2..<6).contains(x), (2..<6).contains(y) else { return (r, g, b) }
        return (r, g * 128 / 255, b * 128 / 255)
    }

    @Test(arguments: [8, 16])
    func aPlainLayerMatchesTheFilesOwnPicture(depth: Int) throws {
        let data = Self.writer(depth: depth, top: false) { x, y in Self.expected(x, y, top: false) }.data()
        let (state, _) = try PSDImport.document(from: data, limits: Self.limits)
        let difference = try #require(PSDAppearance.difference(of: state, from: data, context: try context()))
        print("PSD appearance, one layer, \(depth) bit: mean \(difference.mean), visibly different \(difference.shareVisible)")
        #expect(difference.mean < 1 && difference.shareVisible == 0)
    }

    /// Multiply in a file is gamma-encoded arithmetic; the imported document blends the same way.
    @Test(arguments: [8, 16])
    func aBlendedLayerMatchesWhatTheWritingProgramSaw(depth: Int) throws {
        let data = Self.writer(depth: depth, top: true) { x, y in Self.expected(x, y, top: true) }.data()
        let (state, report) = try PSDImport.document(from: data, limits: Self.limits)
        #expect(report.notes.isEmpty && state.blendSpace == .gamma)
        let difference = try #require(PSDAppearance.difference(of: state, from: data, context: try context()))
        print("PSD appearance, Multiply over a gradient, \(depth) bit: mean \(difference.mean), visibly different \(difference.shareVisible)")
        #expect(difference.mean < 1.5 && difference.shareVisible == 0)
    }

    /// A half-transparent layer is where gamma and linear blending part: the imported document
    /// is set to blend as the writing program did, and that setting is what keeps the look.
    @Test func aHalfTransparentLayerLooksAsItDidOnlyBecauseTheDocumentBlendsInGamma() throws {
        func mixed(_ x: Int, _ y: Int) -> (Int, Int, Int) {
            let (r, g, b) = Self.expected(x, y, top: false)
            guard (2..<6).contains(x), (2..<6).contains(y) else { return (r, g, b) }
            func mix(_ base: Int, _ top: Int) -> Int { base + (top - base) * 128 / 255 }
            return (mix(r, 255), mix(g, 128), mix(b, 128))
        }
        let data = Self.writer(depth: 8, top: true, blend: "norm", opacity: 128, composite: mixed).data()
        let (state, _) = try PSDImport.document(from: data, limits: Self.limits)
        let same = try #require(PSDAppearance.difference(of: state, from: data, context: try context()))
        var linear = state
        linear.blendSpace = .linear
        let other = try #require(PSDAppearance.difference(of: linear, from: data, context: try context()))
        print("PSD appearance, 50 % red over a gradient: in gamma mean \(same.mean), visibly different \(same.shareVisible); in linear light mean \(other.mean), visibly different \(other.shareVisible)")
        #expect(same.mean < 1.5 && same.shareVisible == 0)
        #expect(other.shareVisible > 0.1)
    }

    @Test func aFileWhosePictureDiffersFromItsLayersIsMeasuredAsDifferent() throws {
        // The file claims a flat grey picture; its layers say otherwise.
        let data = Self.writer(depth: 8, top: true) { _, _ in (128, 128, 128) }.data()
        let (state, _) = try PSDImport.document(from: data, limits: Self.limits)
        let difference = try #require(PSDAppearance.difference(of: state, from: data, context: try context()))
        #expect(difference.shareVisible > 0.5 && difference.mean > 10)
        var report = PSDImportReport(source: "RGB, 8 bits per channel")
        report.meanDifference = difference.mean; report.shareVisiblyDifferent = difference.shareVisible
        #expect(report.lines.last?.hasPrefix("Glimmer's picture differs from the one saved in the file:") == true)
        report.meanDifference = 0.2; report.shareVisiblyDifferent = 0
        #expect(report.lines.last == "Glimmer's picture matches the one saved in the file.")
    }
}

/// Shapes and adjustment layers drawn by Glimmer, against what the same settings give by the book.
@Suite struct PSDSettingsAppearanceTests {
    static func withSettings(_ name: String, _ blocks: [(String, Data)], composite: (Int, Int) -> (Int, Int, Int)) -> Data {
        var w = PSDAppearanceTests.writer(depth: 8, top: false, composite: composite)
        var layer = PSDTestWriter.Layer(name: name, rect: PSDFile.Rect(top: 0, left: 0, bottom: 0, right: 0))
        layer.extraBlocks = blocks
        w.layers.append(layer)
        return w.data()
    }

    @Test func aShapeLooksAsItsOutlineAndColourSay() throws {
        let corners = [(x: 0.25, y: 0.25), (x: 0.75, y: 0.25), (x: 0.75, y: 0.75), (x: 0.25, y: 0.75)]
        let data = Self.withSettings("Rectangle 1", [("SoCo", PSDTestWriter.solidColor(red: 255, green: 128, blue: 0)), ("vmsk", PSDTestWriter.vectorMask(corners))]) { x, y in
            (2..<6).contains(x) && (2..<6).contains(y) ? (255, 128, 0) : PSDAppearanceTests.expected(x, y, top: false)
        }
        let (state, report) = try PSDImport.document(from: data, limits: PSDAppearanceTests.limits)
        #expect(report.notes.isEmpty)
        let difference = try #require(PSDAppearance.difference(of: state, from: data, context: try context()))
        print("PSD appearance, a shape over a gradient: mean \(difference.mean), visibly different \(difference.shareVisible)")
        #expect(difference.mean < 1 && difference.shareVisible == 0)
    }

    @Test func levelsAndInvertLookAsTheirArithmeticSays() throws {
        func level(_ v: Int) -> Int { Int((pow(min(max(Double(v - 10) / 230, 0), 1), 1 / 1.2) * 255).rounded()) }
        let levels = Self.withSettings("Levels 1", [("levl", PSDTestWriter.levels([(10, 240, 0, 255, 120)]))]) { x, y in
            let (r, g, b) = PSDAppearanceTests.expected(x, y, top: false)
            return (level(r), level(g), level(b))
        }
        let (a, _) = try PSDImport.document(from: levels, limits: PSDAppearanceTests.limits)
        let first = try #require(PSDAppearance.difference(of: a, from: levels, context: try context()))
        print("PSD appearance, Levels (10, 240, gamma 1.2): mean \(first.mean), visibly different \(first.shareVisible)")
        #expect(first.mean < 1.5 && first.shareVisible == 0)

        let invert = Self.withSettings("Invert 1", [("nvrt", Data())]) { x, y in
            let (r, g, b) = PSDAppearanceTests.expected(x, y, top: false)
            return (255 - r, 255 - g, 255 - b)
        }
        let (b, _) = try PSDImport.document(from: invert, limits: PSDAppearanceTests.limits)
        let second = try #require(PSDAppearance.difference(of: b, from: invert, context: try context()))
        print("PSD appearance, Invert: mean \(second.mean), visibly different \(second.shareVisible)")
        #expect(second.mean < 1.5 && second.shareVisible == 0)
    }
}

/// Writes sample Photoshop files for trying the import in the running app: GLIMMER_PSD_OUT=<folder>.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["GLIMMER_PSD_OUT"] != nil))
struct PSDSampleFiles {
    @Test func write() throws {
        let folder = URL(fileURLWithPath: ProcessInfo.processInfo.environment["GLIMMER_PSD_OUT"]!)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // Everything comes through: a gradient with a half-transparent red square over it.
        let clean = PSDAppearanceTests.writer(depth: 8, top: true, blend: "norm", opacity: 128) { x, y in
            let (r, g, b) = PSDAppearanceTests.expected(x, y, top: false)
            guard (2..<6).contains(x), (2..<6).contains(y) else { return (r, g, b) }
            return (r + (255 - r) * 128 / 255, g + (128 - g) * 128 / 255, b)
        }
        try clean.data().write(to: folder.appending(path: "clean.psd"))
        // Things that do not come through: text, an adjustment layer, a blend mode Glimmer lacks, in a group.
        try PSDTestWriter.mixed().data().write(to: folder.appending(path: "mixed.psd"))
    }
}

/// Files written by other programs (fetched with Anders's yes, kept outside the repository):
/// GLIMMER_PSD_SAMPLES=<folder>. Each is imported, its report printed, and its layers measured
/// against the flattened picture the file carries.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["GLIMMER_PSD_SAMPLES"] != nil), .serialized)
struct PSDRealFiles {
    @Test func everyFileImportsWithATrueReport() throws {
        let folder = URL(fileURLWithPath: ProcessInfo.processInfo.environment["GLIMMER_PSD_SAMPLES"]!)
        let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil).filter { ["psd", "psb"].contains($0.pathExtension.lowercased()) }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        #expect(!files.isEmpty)
        for url in files {
            let data = try Data(contentsOf: url)
            let start = Date()
            do {
                let header = try PSDFile.readHeader(data)
                let raw = try? PSDFile(data)
                let keys = Set((raw?.layers ?? []).flatMap(\.extraKeys)).sorted().joined(separator: " ")
                let blends = (raw?.layers ?? []).map { $0.blendKey.trimmingCharacters(in: .whitespaces) }.joined(separator: ",")
                var (state, report) = try PSDImport.document(from: data)
                if !report.flattened, let d = PSDAppearance.difference(of: state, from: data, context: try context()) {
                    report.meanDifference = d.mean; report.shareVisiblyDifferent = d.shareVisible
                }
                state.importReport = report
                print("PSDREAL \(url.lastPathComponent) | \(header.width)×\(header.height) \(report.source) | \(String(format: "%.2f", Date().timeIntervalSince(start))) s | layers \(report.layersKept)/\(report.layersInFile) | blends \(blends) | blocks \(keys)")
                for line in report.lines { print("PSDREAL    \(line)") }
            } catch {
                print("PSDREAL \(url.lastPathComponent) | REFUSED: \((error as? LocalizedError)?.errorDescription ?? "\(error)")")
            }
        }
    }
}
