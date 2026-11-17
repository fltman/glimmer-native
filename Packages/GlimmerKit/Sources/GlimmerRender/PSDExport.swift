#if GLIMMER_PSD   // Config/Features.xcconfig
import CoreGraphics
import Foundation
import GlimmerCore

/// What a Photoshop file written from a Glimmer document holds as it was, what it holds as
/// pixels, and what it does not hold. Made by the same call that makes the file.
public struct PSDExportReport: Sendable, Equatable {
    public enum Kind: String, Sendable {
        /// Written as a layer of pixels showing what it looks like: text, smart objects, gradient and pattern fills, layers with effects.
        case writtenAsPixels
        /// An adjustment layer of a kind the file can't carry from Glimmer: not written as a layer (the flattened picture still shows it).
        case adjustmentLeftOut
        /// A mask's feather or density is not written: the mask is written plain.
        case maskSimplified
        /// The layer reaches outside the canvas; what is outside is not written.
        case clippedToCanvas
        /// The document blends in linear light; another program blends these layers in gamma.
        case linearBlending
        /// The document's colours are Display P3; the file is written in sRGB.
        case writtenInSRGB
        /// By choice: everything merged into one layer.
        case flattenedByChoice
        /// A Curves layer made in Glimmer: written with points added along the curve, so that a program
        /// that draws curves its own way follows the same line.
        case curveDrawnDifferently
    }

    public struct Note: Sendable, Equatable {
        public var kind: Kind
        public var layer: String?
        public var detail: String?
        public var changesLook: Bool
        public init(_ kind: Kind, layer: String? = nil, detail: String? = nil, changesLook: Bool = false) {
            self.kind = kind; self.layer = layer; self.detail = detail; self.changesLook = changesLook
        }
    }

    public var layersWritten = 0
    public var notes: [Note] = []
    /// For a document that blends in linear light: how far its layers, blended in gamma as
    /// another program will, are from the document's own picture (mean on 0…255, share of
    /// pixels off by more than 8). Nil for a document that blends in gamma already.
    public var gammaDifference: (mean: Double, shareVisible: Double)?

    public static func == (a: PSDExportReport, b: PSDExportReport) -> Bool {
        a.layersWritten == b.layersWritten && a.notes == b.notes && a.gammaDifference?.mean == b.gammaDifference?.mean
    }
}

extension PSDExportReport.Note {
    /// The note in English, for the agent API and the tests. The app says it in the person's language.
    public var what: String {
        let detail = detail ?? ""
        return switch kind {
        case .writtenAsPixels: "It is \(detail) in Glimmer and is written as a layer of pixels that looks the same."
        case .adjustmentLeftOut: "It is a \(detail) adjustment layer, which Glimmer can't write as one. It is not in the file's layers; the flattened picture in the file still shows it."
        case .maskSimplified: "Its mask is written without its feather and density."
        case .clippedToCanvas: "It reaches outside the canvas, and what is outside is not written."
        case .linearBlending: "This document blends colors in linear light. Other programs blend these layers in gamma, so the layers will look different there; the flattened picture in the file is right."
        case .writtenInSRGB: "The document's colors are Display P3; the file is written in sRGB."
        case .curveDrawnDifferently: "It is written as a Curves layer with points added along the curve, so that it looks the same in programs that draw curves their own way. It has more points to edit there."
        case .flattenedByChoice: "All layers are merged into one, as chosen: the file looks right everywhere and has no layers to edit."
        }
    }
}

/// A Glimmer document as a Photoshop file: layers that have a Photoshop form are written as
/// that, everything else as pixels showing what it looks like, with a flattened picture that
/// any program can show. First version: RGB, 8 or 16 bits per channel, sRGB.
public enum PSDExport {
    static let blendKeys: [BlendMode: String] = [
        .passThrough: "pass", .normal: "norm", .darkerColor: "dkCl", .lighterColor: "lgCl", .darken: "dark", .multiply: "mul ", .colorBurn: "idiv", .linearBurn: "lbrn",
        .lighten: "lite", .screen: "scrn", .colorDodge: "div ", .linearDodge: "lddg", .overlay: "over", .softLight: "sLit",
        .hardLight: "hLit", .vividLight: "vLit", .linearLight: "lLit", .pinLight: "pLit", .hardMix: "hMix", .difference: "diff",
        .exclusion: "smud", .subtract: "fsub", .divide: "fdiv", .hue: "hue ", .saturation: "sat ", .color: "colr", .luminosity: "lum ",
    ]

    /// `flattened`: write one merged layer instead of the document's layers (for a document
    /// whose layers would blend differently in another program).
    public static func data(for state: DocumentState, depth: Int = 8, flattened: Bool = false, context: MetalContext) throws -> (data: Data, report: PSDExportReport) {
        let (file, report) = try file(for: state, depth: depth, flattened: flattened, context: context)
        return (try PSDWriter.data(for: file), report)
    }

    public static func file(for state: DocumentState, depth: Int = 8, flattened: Bool = false, context: MetalContext) throws -> (file: PSDFile, report: PSDExportReport) {
        guard depth == 8 || depth == 16 else { throw PSDFile.Problem("Glimmer writes Photoshop files with 8 or 16 bits per channel.") }
        guard (1...30_000).contains(state.width), (1...30_000).contains(state.height) else {
            throw PSDFile.Problem("A Photoshop file can be at most 30,000 pixels on a side. This document is \(state.width) × \(state.height).")
        }
        var report = PSDExportReport()
        if state.colorSpace == .displayP3 { report.notes.append(.init(.writtenInSRGB)) }
        if flattened {
            // One layer holding the document's own picture, transparency kept.
            report.notes.append(.init(.flattenedByChoice))
            let merged = try Pixels(ImageExporter.flatten(state, context: context), depth: depth, overWhite: false)
            var layer = PSDFile.Layer(name: "Merged", rect: PSDFile.Rect(top: 0, left: 0, bottom: 0, right: 0), blendKey: "norm", opacity: 255, isClipped: false, isVisible: true,
                                      group: .none, mask: nil, extraKeys: [], planes: [-1: Data(), 0: Data(), 1: Data(), 2: Data()], bytesPerSample: depth / 8)
            if let box = merged.box {
                layer.rect = PSDFile.Rect(top: box.y, left: box.x, bottom: box.maxY, right: box.maxX)
                layer.planes = [-1: merged.cropped(merged.alpha, to: box), 0: merged.cropped(merged.red, to: box), 1: merged.cropped(merged.green, to: box), 2: merged.cropped(merged.blue, to: box)]
            }
            report.layersWritten = 1
            let flat = try Pixels(ImageExporter.flatten(state, context: context), depth: depth, overWhite: true)
            let header = PSDFile.Header(isLarge: false, channels: 3, width: state.width, height: state.height, depth: depth, mode: .rgb)
            return (PSDFile(header: header, layers: [layer], composite: [flat.red, flat.green, flat.blue], iccProfile: CGColorSpace(name: CGColorSpace.sRGB)?.copyICCData() as Data?), report)
        }
        if state.blendSpace == .linear {
            report.notes.append(.init(.linearBlending, changesLook: true))
            var asElsewhere = state
            asElsewhere.blendSpace = .gamma
            if let ours = try? ImageExporter.flattenedSRGB(state, context: context), let theirs = try? ImageExporter.flattenedSRGB(asElsewhere, context: context),
               let a = PSDAppearance.onWhite(ours), let b = PSDAppearance.onWhite(theirs) {
                report.gammaDifference = PSDAppearance.difference(a, b)
            }
        }
        var layers: [PSDFile.Layer] = []
        try append(state.layers, to: &layers, state: state, depth: depth, context: context, report: &report)
        // The flattened picture, over white where the document is transparent.
        let flat = try Pixels(ImageExporter.flatten(state, context: context), depth: depth, overWhite: true)
        let header = PSDFile.Header(isLarge: false, channels: 3, width: state.width, height: state.height, depth: depth, mode: .rgb)
        let srgb = CGColorSpace(name: CGColorSpace.sRGB)?.copyICCData() as Data?
        return (PSDFile(header: header, layers: layers, composite: [flat.red, flat.green, flat.blue], iccProfile: srgb), report)
    }

    /// Bottom to top, as the file stores them: a group is its end mark, its children, then its own record.
    private static func append(_ list: [Layer], to out: inout [PSDFile.Layer], state: DocumentState, depth: Int, context: MetalContext,
                               report: inout PSDExportReport, nesting: Int = 0) throws {
        guard nesting <= 60 else { throw PSDFile.Problem("This document nests its groups deeper than a Photoshop file from Glimmer can hold.") }
        for layer in list {
            var record = PSDFile.Layer(name: layer.name, rect: PSDFile.Rect(top: 0, left: 0, bottom: 0, right: 0),
                                       blendKey: blendKeys[layer.blendMode] ?? "norm", opacity: UInt8((min(max(layer.opacity, 0), 1) * 255).rounded()),
                                       isClipped: layer.isClipped, isVisible: layer.isVisible, group: .none, mask: nil, extraKeys: [], planes: [:], bytesPerSample: depth / 8)
            if record.blendKey == "pass", !layer.isGroup { record.blendKey = "norm" }
            record.mask = mask(layer, state: state, report: &report)
            switch layer.content {
            case .group(let group):
                out.append(PSDFile.Layer(name: "</Layer group>", rect: record.rect, blendKey: "norm", opacity: 255, isClipped: false, isVisible: true, group: .end,
                                         mask: nil, extraKeys: [], planes: [:], bytesPerSample: depth / 8))
                try append(group.children, to: &out, state: state, depth: depth, context: context, report: &report, nesting: nesting + 1)
                record.group = group.isExpanded ? .open : .closed
            case .adjustment(let adjustment):
                // A curve made in Glimmer runs between its points in Glimmer's own way; Photoshop draws its own curve
                // through the same points. So such a curve is written with points added along it, enough for
                // the other program's curve to follow the same line.
                if adjustment.kind == .curves, !adjustment.usesNaturalCurve, adjustment.curves.values.contains(where: { $0.count > 2 }) {
                    report.notes.append(.init(.curveDrawnDifferently, layer: layer.name))
                }
                guard let block = settings(adjustment) else {
                    report.notes.append(.init(.adjustmentLeftOut, layer: layer.name, detail: adjustment.kind.title, changesLook: layer.isVisible))
                    continue
                }
                record.blocks[block.key] = block.body
            case .fill(.solid(let color)) where !layer.effects.hasEnabled:
                record.blocks["SoCo"] = solidColor(color)
                if let path = layer.vectorMask {
                    record.blocks["vmsk"] = vectorMask(path, width: state.width, height: state.height)
                    record.mask = nil   // the outline is the mask
                }
            default:
                // Everything else as what it looks like. A pixel layer without effects is itself.
                let kind: String? = switch layer.content {
                case .raster: layer.effects.hasEnabled ? "a layer with effects" : nil
                case .text: "text"
                case .smart: "a smart object"
                case .fill(.gradient): "a gradient fill"
                case .fill(.pattern): "a pattern fill"
                default: "a layer with effects"
                }
                if let kind { report.notes.append(.init(.writtenAsPixels, layer: layer.name, detail: kind)) }
                var alone = state
                var solo = layer
                solo.isVisible = true; solo.opacity = 1; solo.blendMode = .normal; solo.mask = nil; solo.isClipped = false
                // A fill's own outline stays in its pixels; a plain layer's mask is written as a mask.
                if case .fill = layer.content, layer.vectorMask != nil { solo.mask = layer.mask; record.mask = nil }
                alone.layers = [solo]
                let pixels = try Pixels(ImageExporter.flatten(alone, context: context), depth: depth, overWhite: false)
                // Pixels are stored in tiles; a tile that lies wholly outside the canvas holds something that is not written.
                if case .raster(let grid) = layer.content, let bounds = grid.tileBounds {
                    let size = TileGeometry.size
                    let canvasTiles = PixelRect(x: 0, y: 0, width: (state.width + size - 1) / size * size, height: (state.height + size - 1) / size * size)
                    if bounds.intersection(canvasTiles) != bounds { report.notes.append(.init(.clippedToCanvas, layer: layer.name)) }
                }
                if let box = pixels.box {
                    record.rect = PSDFile.Rect(top: box.y, left: box.x, bottom: box.maxY, right: box.maxX)
                    record.planes = [-1: pixels.cropped(pixels.alpha, to: box), 0: pixels.cropped(pixels.red, to: box),
                                     1: pixels.cropped(pixels.green, to: box), 2: pixels.cropped(pixels.blue, to: box)]
                } else {
                    // Nothing visible: an empty layer still has its four planes, of no size.
                    record.planes = [-1: Data(), 0: Data(), 1: Data(), 2: Data()]
                }
            }
            out.append(record)
            report.layersWritten += 1
        }
    }

    // MARK: Settings blocks

    static func be16(_ v: UInt16) -> Data { Data([UInt8(v >> 8), UInt8(v & 0xFF)]) }
    static func be32(_ v: UInt32) -> Data { be16(UInt16(v >> 16)) + be16(UInt16(v & 0xFFFF)) }
    static func double(_ v: Double) -> Data { be32(UInt32(v.bitPattern >> 32)) + be32(UInt32(v.bitPattern & 0xFFFF_FFFF)) }
    static func id(_ key: String) -> Data { key.utf8.count == 4 ? be32(0) + Data(key.utf8) : be32(UInt32(key.utf8.count)) + Data(key.utf8) }
    static func descriptor(_ classID: String, _ items: [(String, String, Data)]) -> Data {
        var d = be32(0) + id(classID) + be32(UInt32(items.count))   // an empty name, the class, the items
        for (key, type, value) in items { d += id(key) + Data(type.utf8) + value }
        return d
    }

    /// A solid colour's block: version 16 and a descriptor with the colour as red, green and blue from 0 to 255.
    static func solidColor(_ color: SRGBColor) -> Data {
        func channel(_ v: Double) -> Data { double((min(max(v, 0), 1) * 255).rounded()) }
        let rgb = descriptor("RGBC", [("Rd  ", "doub", channel(color.r)), ("Grn ", "doub", channel(color.g)), ("Bl  ", "doub", channel(color.b))])
        return be32(16) + descriptor("null", [("Clr ", "Objc", rgb)])
    }

    /// A vector mask's block: version 3, no flags, a fill rule record, then each subpath as its
    /// length record and its knots (control before, anchor, control after; vertical first; 8.24 fixed point shares).
    static func vectorMask(_ path: VectorPath, width: Int, height: Int) -> Data {
        func fixed(_ share: Double) -> Data { be32(UInt32(bitPattern: Int32((min(max(share, -15.9), 15.9) * 16_777_216).rounded()))) }
        func point(_ p: SIMD2<Double>) -> Data { fixed(p.y / Double(height)) + fixed(p.x / Double(width)) }
        var d = be32(3) + be32(0)
        d += be16(6) + Data(count: 24)
        for sub in path.subpaths where sub.anchors.count >= 2 {
            let anchors = sub.anchors.prefix(60_000)
            d += be16(sub.isClosed ? 0 : 3) + be16(UInt16(anchors.count)) + Data(count: 22)
            for a in anchors { d += be16(sub.isClosed ? 2 : 5) + point(a.handleIn) + point(a.point) + point(a.handleOut) }
        }
        return d
    }

    /// Invert, Levels and Curves have a form in the file; the other kinds don't from Glimmer.
    static func settings(_ adjustment: Adjustment) -> (key: String, body: Data)? {
        let channels: [CurveChannel] = [.rgb, .red, .green, .blue]
        func byte(_ v: Double) -> UInt16 { UInt16((min(max(v, 0), 1) * 255).rounded()) }
        switch adjustment.kind {
        case .invert:
            return ("nvrt", Data())
        case .levels:
            var d = be16(2)
            for i in 0..<29 {
                let l = i < channels.count ? adjustment.levels[channels[i]] ?? LevelsChannel() : LevelsChannel()
                // The file's ranges: floor 0…253, ceiling 2…255 above the floor, gamma 0.10…9.99.
                let floor = min(byte(l.inBlack), 253), ceiling = max(min(byte(l.inWhite), 255), floor + 2 > 255 ? 255 : max(floor + 1, 2))
                d += be16(floor) + be16(ceiling) + be16(byte(l.outBlack)) + be16(byte(l.outWhite)) + be16(UInt16((min(max(l.gamma, 0.1), 9.99) * 100).rounded()))
            }
            return ("levl", d)
        case .curves:
            // As files from Photoshop hold it: one byte, version 1, a four-byte bit map of the curves that follow.
            var d = Data([0]) + be16(1) + be32(0b1111)
            for channel in channels {
                var source = (adjustment.curves[channel] ?? []).sorted { $0.x < $1.x }
                if !adjustment.usesNaturalCurve, source.count > 2 {
                    // Glimmer's curve sampled at its own points and at even steps between: up to 19 points in all.
                    var xs = Set(source.map { byte($0.x) })
                    for i in 0...16 where xs.count < 19 { xs.insert(UInt16((Double(i) * 255 / 16).rounded())) }
                    let lo = byte(source.first!.x), hi = byte(source.last!.x)
                    source = xs.filter { $0 >= lo && $0 <= hi }.sorted().map { CurvePoint(Double($0) / 255, CurveMath.evaluate(source, at: Double($0) / 255)) }
                }
                var points = source.map { (byte($0.x), byte($0.y)) }
                // Inputs must rise; points that land on the same input after rounding are dropped. A curve needs 2 to 19 points.
                points = points.reduce(into: []) { kept, p in if kept.last.map({ $0.0 < p.0 }) ?? true { kept.append(p) } }
                if points.count < 2 { points = [(0, 0), (255, 255)] }
                points = Array(points.prefix(19))
                d += be16(UInt16(points.count))
                for (input, output) in points { d += be16(output) + be16(input) }
            }
            return ("curv", d)
        default:
            return nil
        }
    }

    // MARK: Masks

    /// The layer's mask as the file stores one: a byte per pixel over the part of the canvas its tiles cover.
    private static func mask(_ layer: Layer, state: DocumentState, report: inout PSDExportReport) -> PSDFile.Mask? {
        guard let mask = layer.mask else { return nil }
        if mask.feather > 0 || mask.density < 1 { report.notes.append(.init(.maskSimplified, layer: layer.name, changesLook: true)) }
        let outside = UInt8((min(max(mask.defaultValue, 0), 1) * 255).rounded())
        guard let box = mask.tiles.tileBounds?.intersection(state.bounds), !box.isEmpty else {
            return PSDFile.Mask(rect: PSDFile.Rect(top: 0, left: 0, bottom: 0, right: 0), defaultColor: outside, isDisabled: !mask.isEnabled, pixels: nil)
        }
        var pixels = Data(repeating: outside, count: box.width * box.height)
        let s = TileGeometry.size
        for coord in box.tileCoords {
            guard let tile = mask.tiles[coord] else { continue }
            let values = tile.pixels()
            let part = coord.rect.intersection(box)
            for y in part.y..<part.maxY {
                for x in part.x..<part.maxX {
                    let v = Float(values[((y - coord.rect.y) * s + (x - coord.rect.x)) * 4])
                    pixels[(y - box.y) * box.width + (x - box.x)] = UInt8((min(max(v, 0), 1) * 255).rounded())
                }
            }
        }
        return PSDFile.Mask(rect: PSDFile.Rect(top: box.y, left: box.x, bottom: box.maxY, right: box.maxX), defaultColor: outside, isDisabled: !mask.isEnabled, pixels: pixels)
    }

    // MARK: Pixels

    /// A flattened picture from Glimmer (linear light, premultiplied, half floats) as the planes
    /// a Photoshop file holds: sRGB-encoded, straight (not premultiplied), 8 or 16 bits, big-endian.
    struct Pixels {
        let width: Int, height: Int, bytes: Int
        var red: Data, green: Data, blue: Data, alpha: Data
        /// The box around everything that isn't fully transparent, nil when nothing is.
        var box: PixelRect?
        var reachesEdge = false

        init(_ image: CGImage, depth: Int, overWhite: Bool) throws {
            width = image.width; height = image.height; bytes = depth / 8
            guard image.bitsPerComponent == 16, image.bitsPerPixel == 64, let source = image.dataProvider?.data as Data? else {
                throw PSDFile.Problem("Glimmer couldn't read its own picture of the document.")
            }
            let count = width * height
            red = Data(count: count * bytes); green = Data(count: count * bytes); blue = Data(count: count * bytes); alpha = Data(count: count * bytes)
            var minX = width, minY = height, maxX = -1, maxY = -1
            let rowBytes = image.bytesPerRow
            let top = depth == 16 ? 65_535.0 : 255.0
            func encode(_ v: Double) -> Double {
                let c = min(max(v, 0), 1)
                return c <= 0.0031308 ? c * 12.92 : 1.055 * pow(c, 1 / 2.4) - 0.055
            }
            source.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                func store(_ plane: inout Data, _ i: Int, _ value: Double) {
                    let v = UInt16((min(max(value, 0), 1) * top).rounded())
                    if bytes == 2 { plane[i * 2] = UInt8(v >> 8); plane[i * 2 + 1] = UInt8(v & 0xFF) } else { plane[i] = UInt8(v) }
                }
                for y in 0..<height {
                    let row = raw.baseAddress!.advanced(by: y * rowBytes).assumingMemoryBound(to: Float16.self)
                    for x in 0..<width {
                        let a = Double(row[x * 4 + 3])
                        var r = Double(row[x * 4]), g = Double(row[x * 4 + 1]), b = Double(row[x * 4 + 2])
                        let i = y * width + x
                        if overWhite {
                            // Over white in linear light, where the picture is premultiplied.
                            let clear = 1 - min(max(a, 0), 1)
                            r += clear; g += clear; b += clear
                            store(&alpha, i, 1)
                        } else {
                            if a > 0 { r /= a; g /= a; b /= a } else { r = 0; g = 0; b = 0 }
                            store(&alpha, i, a)
                            if a > 0.5 / top { minX = min(minX, x); minY = min(minY, y); maxX = max(maxX, x); maxY = max(maxY, y) }
                        }
                        store(&red, i, encode(r)); store(&green, i, encode(g)); store(&blue, i, encode(b))
                    }
                }
            }
            if maxX >= minX, maxY >= minY {
                box = PixelRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
                reachesEdge = minX == 0 || minY == 0 || maxX == width - 1 || maxY == height - 1
            }
        }

        func cropped(_ plane: Data, to box: PixelRect) -> Data {
            var out = Data(capacity: box.width * box.height * bytes)
            for y in box.y..<box.maxY { out += plane.subdata(in: ((y * width + box.x) * bytes)..<((y * width + box.maxX) * bytes)) }
            return out
        }
    }
}
#endif
