import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import GlimmerCore
@testable import GlimmerRender

/// A Glimmer document with one of everything, written as a Photoshop file and read back:
/// what a round trip keeps, field by field and picture by picture.
@Suite struct PSDRoundTripTests {
    static let limits = PSDFile.Limits(maxCanvasPixels: 4_000_000, maxDecodedBytes: 64_000_000)
    static let width = 48, height = 32

    /// An opaque or half-transparent picture as tiles at an offset, from sRGB bytes.
    static func tiles(width: Int, height: Int, at origin: SIMD2<Int> = .zero, _ pixel: (Int, Int) -> (UInt8, UInt8, UInt8, UInt8)) throws -> TileGrid {
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height { for x in 0..<width { let p = pixel(x, y); let i = (y * width + x) * 4; bytes[i] = p.0; bytes[i + 1] = p.1; bytes[i + 2] = p.2; bytes[i + 3] = p.3 } }
        let provider = CGDataProvider(data: Data(bytes) as CFData)!
        let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue), provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        return try ImageImporter.tiles(from: image, origin: origin)
    }

    /// One of everything a Photoshop file from Glimmer can carry. `extras` adds what it can't.
    static func document(blend: BlendSpace = .gamma, extras: Bool = false) throws -> DocumentState {
        var state = DocumentState(width: width, height: height)
        state.blendSpace = blend
        let photo = Layer(name: "Foto åäö", content: .raster(try tiles(width: width, height: height) { x, y in (UInt8(40 + x * 4), UInt8(60 + y * 5), 150, 255) }))
        var patch = Layer(name: "Patch", opacity: 128.0 / 255, blendMode: .multiply,
                          content: .raster(try tiles(width: 20, height: 12, at: SIMD2(10, 8)) { x, _ in (230, UInt8(120 + x * 4), 90, x < 4 ? 128 : 255) }))
        patch.mask = Selection.rasterize(bounds: PixelRect(x: 0, y: 0, width: 256, height: 256)) { x, y in x < 20 ? 1 : (y < 14 ? 0.5 : 0) }.asMask
        var hidden = Layer(name: "Hidden", isVisible: false, content: .raster(try tiles(width: 8, height: 8, at: SIMD2(30, 4)) { _, _ in (10, 200, 10, 255) }))
        hidden.mask = LayerMask(defaultValue: 0, isEnabled: false)
        let clipped = Layer(name: "Clipped", blendMode: .screen, isClipped: true, content: .raster(try tiles(width: 10, height: 10, at: SIMD2(12, 10)) { _, _ in (60, 60, 200, 255) }))
        let fill = Layer(name: "Color Fill 1", opacity: 0.25, blendMode: .overlay, content: .fill(.solid(SRGBColor(1, 128.0 / 255, 0))))
        let outline = VectorPath(name: "Rectangle 1", subpaths: [Subpath(anchors: [PathAnchor(SIMD2(30, 18)), PathAnchor(SIMD2(44, 18)), PathAnchor(SIMD2(44, 28)), PathAnchor(SIMD2(30, 28))], isClosed: true)])
        let shape = Layer(name: "Rectangle 1", mask: outline.asSelection.asMask, vectorMask: outline, content: .fill(.solid(SRGBColor(0, 0.4, 0.8))))
        var levels = Adjustment(.levels)
        levels.levels = [.rgb: LevelsChannel(inBlack: 10.0 / 255, inWhite: 240.0 / 255, gamma: 1.2), .red: LevelsChannel(outBlack: 20.0 / 255, outWhite: 235.0 / 255), .green: LevelsChannel(), .blue: LevelsChannel()]
        var curves = Adjustment(.curves)
        curves.curves = [.rgb: [CurvePoint(0, 0), CurvePoint(128.0 / 255, 160.0 / 255), CurvePoint(1, 1)], .red: [CurvePoint(0, 0), CurvePoint(1, 1)],
                         .green: [CurvePoint(0, 0), CurvePoint(1, 1)], .blue: [CurvePoint(0, 0), CurvePoint(1, 1)]]
        let group = Layer(name: "Group 1", opacity: 0.8, blendMode: .passThrough,
                          content: .group(LayerGroup(children: [patch, clipped, hidden, Layer(name: "Levels 1", content: .adjustment(levels))], isExpanded: false)))
        state.layers = [photo, group, fill, shape, Layer(name: "Curves 1", opacity: 0.5, content: .adjustment(curves)), Layer(name: "Invert 1", isVisible: false, content: .adjustment(Adjustment(.invert)))]
        if extras {
            var vibrance = Adjustment(.vibrance)
            vibrance.numbers = ["vibrance": 0.5, "saturation": 0]
            let stops = [GradientStop(0, SRGBColor(1, 0, 0)), GradientStop(1, SRGBColor(0, 0, 1))]
            state.layers += [Layer(name: "Vibrance 1", content: .adjustment(vibrance)),
                             Layer(name: "Gradient Fill 1", opacity: 0.5, content: .fill(.gradient(GradientFill(stops: stops, start: SIMD2(0, 0), end: SIMD2(Double(width), 0)))))]
        }
        return state
    }

    static func outline(_ layers: [Layer], depth: Int = 0) -> [String] {
        layers.flatMap { layer -> [String] in
            var line = String(repeating: "  ", count: depth) + "\(layer.name) | \(layer.blendMode.rawValue) | \(Int((layer.opacity * 255).rounded())) | \(layer.isVisible ? "shown" : "hidden") | \(layer.isClipped ? "clipped" : "-")"
            switch layer.content {
            case .group(let g): return [line + " | group \(g.isExpanded ? "open" : "closed")"] + outline(g.children, depth: depth + 1)
            case .raster: line += " | pixels"
            case .adjustment(let a): line += " | \(a.kind.rawValue)"
            case .fill(.solid(let c)): line += " | fill \(Int((c.r * 255).rounded())),\(Int((c.g * 255).rounded())),\(Int((c.b * 255).rounded()))\(layer.vectorMask == nil ? "" : " with outline")"
            default: line += " | other"
            }
            if let mask = layer.mask, layer.vectorMask == nil { line += " | mask default \(Int((mask.defaultValue * 255).rounded())) \(mask.isEnabled ? "on" : "off")" }
            return [line]
        }
    }

    @Test(arguments: [8, 16])
    func everyFieldComesBack(depth: Int) throws {
        let before = try Self.document()
        let (data, report) = try PSDExport.data(for: before, depth: depth, context: try context())
        // The one note: the Curves layer made in Glimmer is written with points added along its curve.
        #expect(report.notes.map(\.kind) == [.curveDrawnDifferently] && report.layersWritten == 10, "\(report.notes.map(\.what))")
        let (after, imported) = try PSDImport.document(from: data, limits: Self.limits)
        #expect(Self.outline(after.layers) == Self.outline(before.layers))
        #expect(after.width == Self.width && after.height == Self.height && after.blendSpace == .gamma)
        // What the import says about a file Glimmer wrote: only the Curves note.
        #expect(imported.notes.isEmpty && imported.layersKept == 10 && imported.layersInFile == 10)
        func find(_ name: String, in layers: [Layer]) -> Layer? {
            for l in layers { if l.name == name { return l }; if case .group(let g) = l.content, let hit = find(name, in: g.children) { return hit } }
            return nil
        }
        // The outline, to the fixed-point step.
        let a = try #require(find("Rectangle 1", in: after.layers)?.vectorMask?.subpaths.first), b = try #require(find("Rectangle 1", in: before.layers)?.vectorMask?.subpaths.first)
        #expect(a.isClosed && a.anchors.count == b.anchors.count)
        for (p, q) in zip(a.anchors, b.anchors) { #expect(abs(p.point.x - q.point.x) < 0.001 && abs(p.point.y - q.point.y) < 0.001 && abs(p.handleIn.x - q.handleIn.x) < 0.001) }
        // Levels and Curves, to the file's steps.
        func adjustment(_ name: String, _ state: DocumentState) -> Adjustment? { if case .adjustment(let x)? = find(name, in: state.layers)?.content { x } else { nil } }
        let l1 = try #require(adjustment("Levels 1", after)), l0 = try #require(adjustment("Levels 1", before))
        for channel in CurveChannel.allCases {
            let x = try #require(l1.levels[channel]), y = try #require(l0.levels[channel])
            #expect(abs(x.inBlack - y.inBlack) < 0.002 && abs(x.inWhite - y.inWhite) < 0.002 && abs(x.gamma - y.gamma) < 0.006 && abs(x.outBlack - y.outBlack) < 0.002 && abs(x.outWhite - y.outWhite) < 0.002)
        }
        // The curve comes back with more points, drawn as other programs draw it, and follows the same line.
        let c1 = try #require(adjustment("Curves 1", after)), c0 = try #require(adjustment("Curves 1", before))
        #expect(c1.usesNaturalCurve && (c1.curves[.rgb]?.count ?? 0) > 3)
        var worstCurve = 0.0
        for i in 0...255 {
            let t = Double(i) / 255
            worstCurve = max(worstCurve, abs(CurveMath.evaluate(c1.curve(.rgb), at: t, natural: true) - CurveMath.evaluate(c0.curve(.rgb), at: t)))
        }
        print("PSD round trip, a Curves layer made in Glimmer: the curve read back is at most \(worstCurve * 255) of 255 from the original")
        #expect(worstCurve * 255 < 1.5)
        // The picture: the document before, the document after, and the file's own flattened picture as macOS reads it.
        let ours = try #require(PSDAppearance.onWhite(try ImageExporter.flattenedSRGB(before, context: try context())))
        let back = try #require(PSDAppearance.onWhite(try ImageExporter.flattenedSRGB(after, context: try context())))
        let trip = PSDAppearance.difference(ours, back)
        let outside = try #require(PSDAppearance.difference(of: before, from: data, context: try context()))
        print("PSD round trip, \(depth) bit: picture before against after: mean \(trip.mean), visibly different \(trip.shareVisible); against the file's flattened picture as macOS reads it: mean \(outside.mean), visibly different \(outside.shareVisible); file \(data.count) bytes")
        #expect(trip.mean < 1 && trip.shareVisible == 0)
        #expect(outside.mean < 1 && outside.shareVisible == 0)
        // A second trip changes nothing more: what came back is what goes out.
        let (again, _) = try PSDExport.data(for: after, depth: depth, context: try context())
        let (twice, _) = try PSDImport.document(from: again, limits: Self.limits)
        #expect(Self.outline(twice.layers) == Self.outline(after.layers))
        // The written file goes through the reader's limits like any other, and ImageIO knows what it is.
        #expect(try PSDFile(data, limits: Self.limits).layers.count == 11)   // ten layers and the group's end mark
        #expect(CGImageSourceGetType(try #require(CGImageSourceCreateWithData(data as CFData, nil))) as String? == "com.adobe.photoshop-image")
    }

    @Test func whatTheFileCannotCarryIsSaidAndTheFlattenedPictureStillShowsIt() throws {
        let before = try Self.document(extras: true)
        let (data, report) = try PSDExport.data(for: before, context: try context())
        #expect(report.notes.map { "\($0.layer ?? "-"): \($0.kind.rawValue) \($0.detail ?? "")" } == ["Curves 1: curveDrawnDifferently ", "Vibrance 1: adjustmentLeftOut Vibrance", "Gradient Fill 1: writtenAsPixels a gradient fill"])
        #expect(report.layersWritten == 11)
        let (after, _) = try PSDImport.document(from: data, limits: Self.limits)
        #expect(after.layers.map(\.name).suffix(1) == ["Gradient Fill 1"] && !after.layers.contains { $0.name == "Vibrance 1" })
        // The flattened picture in the file is the document's own, Vibrance included.
        let outside = try #require(PSDAppearance.difference(of: before, from: data, context: try context()))
        #expect(outside.mean < 1 && outside.shareVisible == 0)
        // Without Vibrance the layers that came back are close to the document without it: the gradient fill as pixels looks the same.
        var without = before
        without.layers.removeAll { $0.name == "Vibrance 1" }
        let a = try #require(PSDAppearance.onWhite(try ImageExporter.flattenedSRGB(without, context: try context())))
        let b = try #require(PSDAppearance.onWhite(try ImageExporter.flattenedSRGB(after, context: try context())))
        let d = PSDAppearance.difference(a, b)
        print("PSD round trip with a gradient fill written as pixels: mean \(d.mean), visibly different \(d.shareVisible)")
        #expect(d.mean < 1 && d.shareVisible == 0)
    }

    @Test func aDocumentInLinearLightSaysHowDifferentItsLayersWillLookElsewhere() throws {
        let linear = try Self.document(blend: .linear)
        let (_, report) = try PSDExport.data(for: linear, context: try context())
        #expect(report.notes.map(\.kind) == [.linearBlending, .curveDrawnDifferently])
        let difference = try #require(report.gammaDifference)
        print("PSD export of a linear-light document: its layers blended in gamma differ by mean \(difference.mean), visibly on \(difference.shareVisible) of the pixels")
        #expect(difference.mean > 0)
        #expect(try PSDExport.data(for: try Self.document(), context: try context()).report.gammaDifference == nil)
    }

    /// The other choice for a linear-light document: one merged layer, which looks right in any program.
    @Test(arguments: [8, 16])
    func aMergedFileHoldsOneLayerThatLooksLikeTheDocument(depth: Int) throws {
        let linear = try Self.document(blend: .linear)
        let (data, report) = try PSDExport.data(for: linear, depth: depth, flattened: true, context: try context())
        #expect(report.notes.map(\.kind) == [.flattenedByChoice] && report.layersWritten == 1 && report.gammaDifference == nil)
        let (after, imported) = try PSDImport.document(from: data, limits: Self.limits)
        #expect(after.layers.map(\.name) == ["Merged"] && imported.notes.isEmpty)
        let ours = try #require(PSDAppearance.onWhite(try ImageExporter.flattenedSRGB(linear, context: try context())))
        let back = try #require(PSDAppearance.onWhite(try ImageExporter.flattenedSRGB(after, context: try context())))
        let trip = PSDAppearance.difference(ours, back)
        let outside = try #require(PSDAppearance.difference(of: linear, from: data, context: try context()))
        print("PSD merged file from a linear-light document, \(depth) bit: the document against the layer read back: mean \(trip.mean), visibly different \(trip.shareVisible); against the flattened picture as macOS reads it: mean \(outside.mean), visibly different \(outside.shareVisible)")
        #expect(trip.mean < 1 && trip.shareVisible == 0 && outside.mean < 1 && outside.shareVisible == 0)
    }

    @Test func aDocumentTooLargeForTheFormatIsRefusedWithWords() throws {
        var huge = DocumentState(width: 30_001, height: 10)
        huge.layers = []
        #expect(throws: PSDFile.Problem("A Photoshop file can be at most 30,000 pixels on a side. This document is 30001 × 10.")) { _ = try PSDExport.data(for: huge, context: try context()) }
    }
}
