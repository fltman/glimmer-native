#if GLIMMER_PSD   // Config/Features.xcconfig switches this
import CoreGraphics
import Foundation

/// Turns a Photoshop file into a Glimmer document and says what did not survive.
///
/// First version: pixel layers, groups, masks, opacity, visibility, clipping and the blend
/// modes Glimmer has, for RGB and grayscale files of 8 or 16 bits per channel. Anything else
/// in the file is named in the report: text, smart objects, effects, fill and adjustment
/// layers. Files in other colour modes or depths come in as the file's own flattened
/// picture, converted by the system.
public enum PSDImport {
    static let maxGroupDepth = 64

    static let blendModes: [String: BlendMode] = [
        "pass": .passThrough, "norm": .normal, "dark": .darken, "mul ": .multiply, "idiv": .colorBurn, "lbrn": .linearBurn,
        "dkCl": .darkerColor, "lgCl": .lighterColor,
        "lite": .lighten, "scrn": .screen, "div ": .colorDodge, "lddg": .linearDodge, "over": .overlay, "sLit": .softLight,
        "hLit": .hardLight, "vLit": .vividLight, "lLit": .linearLight, "pLit": .pinLight, "hMix": .hardMix, "diff": .difference,
        "smud": .exclusion, "fsub": .subtract, "fdiv": .divide, "hue ": .hue, "sat ": .saturation, "colr": .color, "lum ": .luminosity,
    ]
    static let blendNames: [String: String] = ["diss": "Dissolve"]

    /// The additional blocks that say a layer is more than its pixels, and what is said about each.
    static let adjustments: [String: String] = [
        "brit": "Brightness/Contrast", "levl": "Levels", "curv": "Curves", "expA": "Exposure", "hue2": "Hue/Saturation", "hue ": "Hue/Saturation",
        "vibA": "Vibrance", "blnc": "Color Balance", "blwh": "Black & White", "phfl": "Photo Filter", "mixr": "Channel Mixer",
        "nvrt": "Invert", "post": "Posterize", "thrs": "Threshold", "grdm": "Gradient Map", "selc": "Selective Color", "clrL": "Color Lookup",
    ]
    static let fills: [String: String] = ["SoCo": "solid colour", "GdFl": "gradient", "PtFl": "pattern"]

    public static func document(from data: Data, limits: PSDFile.Limits = PSDFile.Limits()) throws -> (state: DocumentState, report: PSDImportReport) {
        let header = try PSDFile.readHeader(data)
        var report = PSDImportReport(source: describe(header))
        let layered = (header.mode == .rgb || header.mode == .grayscale) && (header.depth == 8 || header.depth == 16)
        guard layered else {
            return (try flattened(data, header: header, report: &report, why: true), report)
        }
        let file = try PSDFile(data, limits: limits)
        report.layersInFile = file.layers.filter { $0.group != .end }.count
        guard !file.layers.isEmpty else {
            return (try flattened(data, header: header, report: &report, why: false), report)
        }
        let space = colorSpace(for: file)
        // The file lists layers bottom to top; a group is everything between its end mark and its own record.
        var stack: [[Layer]] = [[]]
        for source in file.layers {
            switch source.group {
            case .end:
                guard stack.count <= maxGroupDepth else { throw PSDFile.Problem("This Photoshop file nests its groups deeper than Glimmer reads.") }
                stack.append([])
            case .open, .closed:
                var children: [Layer] = []
                if stack.count > 1 {
                    children = stack.removeLast()
                } else {
                    report.notes.append(.init(.groupEndMissing, layer: source.name))
                }
                var group = Layer(name: source.name, isVisible: source.isVisible, opacity: Double(source.opacity) / 255,
                                  blendMode: blendMode(source, isGroup: true, report: &report), isClipped: source.isClipped,
                                  content: .group(LayerGroup(children: children, isExpanded: source.group == .open)))
                group.mask = mask(source)
                noteExtras(source, isGroup: true, report: &report)
                stack[stack.count - 1].append(group)
                report.groupsKept += 1
            case .none:
                if let layer = try pixelLayer(source, file: file, space: space, report: &report) {
                    stack[stack.count - 1].append(layer)
                    report.layersKept += 1
                }
            }
        }
        // Groups the file opened and never closed: their layers are kept, at the level above.
        while stack.count > 1 {
            let orphans = stack.removeLast()
            stack[stack.count - 1].append(contentsOf: orphans)
            report.notes.append(.init(.groupRecordMissing))
        }
        report.layersKept += report.groupsKept
        var state = DocumentState(width: header.width, height: header.height)
        // Photoshop blends in gamma-encoded values; the document keeps that, so the layers look as they did.
        state.blendSpace = .gamma
        state.layers = stack[0]
        state.activeLayerID = state.layers.last?.id
        state.importReport = report
        return (state, report)
    }

    static func describe(_ header: PSDFile.Header) -> String {
        let mode: String = switch header.mode {
        case .bitmap: "Bitmap"
        case .grayscale: "Grayscale"
        case .indexed: "Indexed colour"
        case .rgb: "RGB"
        case .cmyk: "CMYK"
        case .multichannel: "Multichannel"
        case .duotone: "Duotone"
        case .lab: "Lab"
        }
        return "\(mode), \(header.depth) \(header.depth == 1 ? "bit" : "bits") per channel" + (header.isLarge ? ", large document format" : "")
    }

    /// The file's own flattened picture as one layer, converted by the system (which honours the embedded profile).
    private static func flattened(_ data: Data, header: PSDFile.Header, report: inout PSDImportReport, why: Bool) throws -> DocumentState {
        let image: CGImage
        do { image = try ImageImporter.image(from: data) } catch {
            throw PSDFile.Problem("This Photoshop file carries no flattened picture that macOS can read, and its layers are in a form Glimmer doesn't read (\(report.source)).")
        }
        report.flattened = true
        if why { report.notes.append(.init(.layersNotRead, detail: report.source)) }
        var state = DocumentState(width: image.width, height: image.height)
        let layer = Layer(name: "Background", content: .raster(try ImageImporter.tiles(from: image)))
        state.layers = [layer]
        state.activeLayerID = layer.id
        state.importReport = report
        return state
    }

    private static func colorSpace(for file: PSDFile) -> CGColorSpace {
        let wanted: CGColorSpaceModel = file.header.mode == .grayscale ? .monochrome : .rgb
        if let icc = file.iccProfile, let space = CGColorSpace(iccData: icc as CFData), space.model == wanted { return space }
        return file.header.mode == .grayscale ? CGColorSpace(name: CGColorSpace.genericGrayGamma2_2)! : CGColorSpace(name: CGColorSpace.sRGB)!
    }

    private static func blendMode(_ source: PSDFile.Layer, isGroup: Bool, report: inout PSDImportReport) -> BlendMode {
        if let mode = blendModes[source.blendKey] { return mode == .passThrough && !isGroup ? .normal : mode }
        let name = blendNames[source.blendKey] ?? "“\(source.blendKey.trimmingCharacters(in: .whitespaces))”"
        report.notes.append(.init(.blendModeBecameNormal, layer: source.name, detail: name, changesLook: true))
        return .normal
    }

    private static func mask(_ source: PSDFile.Layer) -> LayerMask? {
        guard let mask = source.mask else { return nil }
        let outside = Float(mask.defaultColor) / 255
        guard let pixels = mask.pixels, mask.rect.width > 0, mask.rect.height > 0 else {
            // A mask with no pixels is all its default colour. White everywhere is no mask at all.
            return mask.defaultColor == 255 ? nil : LayerMask(defaultValue: outside, isEnabled: !mask.isDisabled)
        }
        let rect = PixelRect(x: mask.rect.left, y: mask.rect.top, width: mask.rect.width, height: mask.rect.height)
        // Whole tiles, so that what lies outside the mask's rectangle inside a tile gets the mask's default.
        let s = TileGeometry.size
        let x0 = PixelRect.floorDiv(rect.x, s) * s, y0 = PixelRect.floorDiv(rect.y, s) * s
        let x1 = (PixelRect.floorDiv(rect.maxX - 1, s) + 1) * s, y1 = (PixelRect.floorDiv(rect.maxY - 1, s) + 1) * s
        let covered = Selection.rasterize(bounds: PixelRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)) { x, y in
            guard x >= rect.x, x < rect.maxX, y >= rect.y, y < rect.maxY else { return outside }
            return Float(pixels[pixels.startIndex + (y - rect.y) * rect.width + (x - rect.x)]) / 255
        }
        return LayerMask(tiles: covered.tiles, defaultValue: outside, isEnabled: !mask.isDisabled)
    }

    private static func noteExtras(_ source: PSDFile.Layer, isGroup: Bool, report: inout PSDImportReport) {
        let keys = Set(source.extraKeys)
        if !keys.isDisjoint(with: ["lfx2", "lrFX", "lmfx"]) {
            report.notes.append(.init(.effectsNotRead, layer: source.name, changesLook: true))
        }
        if !isGroup, !keys.isDisjoint(with: ["vmsk", "vsms"]), keys.isDisjoint(with: Set(fills.keys)) {
            report.notes.append(.init(.vectorMaskNotRead, layer: source.name, changesLook: true))
        }
        if keys.contains("SoLd") || keys.contains("SoLE") || keys.contains("PlLd") || keys.contains("plLd") {
            report.notes.append(.init(.wasSmartObject, layer: source.name))
        }
        if keys.contains("TySh") || keys.contains("tySh") {
            report.notes.append(.init(.wasText, layer: source.name, detail: text(source)))
        }
    }

    /// A layer of pixels, or nil for a layer that has none and can't be drawn (it is named in the report).
    private static func pixelLayer(_ source: PSDFile.Layer, file: PSDFile, space: CGColorSpace, report: inout PSDImportReport) throws -> Layer? {
        let keys = Set(source.extraKeys)
        if let settings = adjustment(source, report: &report) {
            var layer = Layer(name: source.name, isVisible: source.isVisible, opacity: Double(source.opacity) / 255,
                              blendMode: blendMode(source, isGroup: false, report: &report), isClipped: source.isClipped,
                              content: .adjustment(settings))
            layer.mask = mask(source)
            return layer
        }
        if let fill = fillLayer(source, file: file, report: &report) { return fill }
        if let kind = keys.compactMap({ adjustments[$0] }).first {
            report.notes.append(.init(.adjustmentLeftOut, layer: source.name, detail: kind, changesLook: source.isVisible))
            return nil
        }
        if let kind = keys.compactMap({ fills[$0] }).first {
            report.notes.append(.init(.fillLeftOut, layer: source.name, detail: kind, changesLook: source.isVisible))
            return nil
        }
        var layer = Layer(name: source.name, isVisible: source.isVisible, opacity: Double(source.opacity) / 255,
                          blendMode: blendMode(source, isGroup: false, report: &report), isClipped: source.isClipped,
                          content: .raster(TileGrid()))
        layer.mask = mask(source)
        layer.formerText = text(source)
        noteExtras(source, isGroup: false, report: &report)
        if source.rect.width > 0, source.rect.height > 0 {
            guard let image = image(source, gray: file.header.mode == .grayscale, space: space) else {
                report.notes.append(.init(.pixelsIncomplete, layer: source.name, changesLook: source.isVisible))
                return layer
            }
            layer.content = .raster(try ImageImporter.tiles(from: image, origin: SIMD2(source.rect.left, source.rect.top)))
        }
        return layer
    }

    // MARK: Layers that are more than pixels

    /// The words of a text layer, when its type block gives them readably (nil otherwise).
    static func text(_ source: PSDFile.Layer) -> String? {
        guard let block = source.blocks["TySh"] else { return nil }
        var r = PSDBytes(block)
        // Version, the six numbers of the transform, the text version and the descriptor's version come first.
        guard (try? r.skip(2 + 48 + 2 + 4)) != nil else { return nil }
        var budget = PSDDescriptor.maxItems
        guard let data = try? PSDDescriptor.read(&r, budget: &budget) else { return nil }
        for case .string(let words) in data.all where !words.isEmpty {
            return String(words.replacingOccurrences(of: "\r", with: " ").prefix(200))
        }
        return nil
    }

    /// The adjustment layers whose data the specification lays out and whose arithmetic is the
    /// same everywhere: Invert, Levels, and Curves (with a note: its points are the same, the
    /// curve between them need not be).
    static func adjustment(_ source: PSDFile.Layer, report: inout PSDImportReport) -> Adjustment? {
        if source.extraKeys.contains("nvrt") { return Adjustment(.invert) }
        if let block = source.blocks["levl"], let perChannel = levels(block) {
            var result = Adjustment(.levels)
            result.levels = perChannel
            return result
        }
        if let block = source.blocks["curv"], let perChannel = curves(block) {
            var result = Adjustment(.curves)
            result.curves = perChannel
            result.flags[Adjustment.naturalCurveFlag] = true   // drawn between the points as Photoshop draws it
            return result
        }
        return nil
    }

    static let channels: [CurveChannel] = [.rgb, .red, .green, .blue]

    /// Levels: version 2, then record sets of five shorts (input floor and ceiling, output
    /// floor and ceiling, gamma × 100). The first is the master, the next three red, green, blue.
    static func levels(_ block: Data) -> [CurveChannel: LevelsChannel]? {
        var r = PSDBytes(block)
        guard (try? r.u16()) == 2 else { return nil }
        var result: [CurveChannel: LevelsChannel] = [:]
        for channel in channels {
            guard let inFloor = try? r.u16(), let inCeiling = try? r.u16(), let outFloor = try? r.u16(), let outCeiling = try? r.u16(), let gamma = try? r.u16(),
                  inFloor <= 253, (2...255).contains(inCeiling), inFloor < inCeiling, outFloor <= 255, outCeiling <= 255, (10...999).contains(gamma) else { return nil }
            result[channel] = LevelsChannel(inBlack: Double(inFloor) / 255, inWhite: Double(inCeiling) / 255, gamma: Double(gamma) / 100,
                                            outBlack: Double(outFloor) / 255, outWhite: Double(outCeiling) / 255)
        }
        return result
    }

    /// Curves. In files from Photoshop the block is: one byte, the version (1 or 4), then for
    /// version 1 a four-byte bit map of which curves are there, for version 4 their count; each
    /// curve is a count of 2 to 19 points, each point its output then its input, 0 to 255.
    /// (The specification's page describes the load-file form, without the leading byte and
    /// with a two-byte bit map; the layout here is what real files hold, seen 2026-11-16.)
    /// Bit 0 is the composite curve, bits 1 to 3 red, green and blue.
    static func curves(_ block: Data) -> [CurveChannel: [CurvePoint]]? {
        var r = PSDBytes(block)
        guard (try? r.skip(1)) != nil, let version = try? r.u16(), version == 1 || version == 4 else { return nil }
        let present: [Int]
        if version == 1 {
            guard let map = try? r.u32() else { return nil }
            present = (0..<32).filter { map & (1 << UInt32($0)) != 0 }
        } else {
            guard let count = try? r.u16(), count <= 19 else { return nil }
            present = Array(0..<Int(count))
        }
        var result: [CurveChannel: [CurvePoint]] = [:]
        for index in present {
            guard let count = try? r.u16(), (2...19).contains(count) else { return nil }
            var points: [CurvePoint] = []
            for _ in 0..<count {
                guard let output = try? r.u16(), let input = try? r.u16(), output <= 255, input <= 255 else { return nil }
                points.append(CurvePoint(Double(input) / 255, Double(output) / 255))
            }
            guard zip(points, points.dropFirst()).allSatisfy({ $0.x < $1.x }) else { return nil }
            guard index < channels.count else { return nil }   // a curve for a channel Glimmer has no curve for: not guessed at
            result[channels[index]] = points
        }
        return result.isEmpty ? nil : result
    }

    /// A solid colour fill, with its vector mask when it is a shape: a real fill layer, editable.
    static func fillLayer(_ source: PSDFile.Layer, file: PSDFile, report: inout PSDImportReport) -> Layer? {
        guard let block = source.blocks["SoCo"] else { return nil }
        var r = PSDBytes(block)
        guard (try? r.skip(4)) != nil else { return nil }   // the version
        var budget = PSDDescriptor.maxItems
        guard let settings = try? PSDDescriptor.read(&r, budget: &budget), let fillColor = color(in: settings) else { return nil }
        var layer = Layer(name: source.name, isVisible: source.isVisible, opacity: Double(source.opacity) / 255,
                          blendMode: blendMode(source, isGroup: false, report: &report), isClipped: source.isClipped,
                          content: .fill(.solid(fillColor)))
        layer.mask = mask(source)
        if let vector = source.blocks["vmsk"] ?? source.blocks["vsms"] {
            var v = PSDBytes(vector)
            // Version, then flags. The specification numbers the flags "bit 1 = invert, bit 2 = not
            // link, bit 3 = disable"; read here as the three lowest bits in that order.
            guard (try? v.skip(4)) != nil, let flags = try? v.u32() else { return nil }
            let subpaths = PSDPath.subpaths(v.rest, width: file.header.width, height: file.header.height)
            guard !subpaths.isEmpty, flags & 1 == 0 else {
                // No outline that could be read, or an inverted one, which Glimmer's shapes don't have:
                // the layer is left out, and the caller says so.
                return nil
            }
            let path = VectorPath(name: source.name, subpaths: subpaths)
            var shape = path.asSelection.asMask
            shape.isEnabled = flags & 4 == 0
            layer.mask = shape
            layer.vectorMask = path
        }
        if !Set(source.extraKeys).isDisjoint(with: ["lfx2", "lrFX", "lmfx"]) {
            report.notes.append(.init(.effectsNotRead, layer: source.name, changesLook: true))
        }
        return layer
    }

    /// The colour in a fill's settings: an object holding red, green and blue from 0 to 255.
    /// The specification does not name the keys; red, green and blue are taken by the keys
    /// other files use ("Rd  ", "Grn ", "Bl  ") when present, and otherwise in that order.
    static func color(in settings: PSDValue) -> SRGBColor? {
        for case .object(_, let items) in settings.all {
            let numbers = items.compactMap { item in item.value.number.map { (item.key, $0) } }
            guard numbers.count == 3, numbers.count == items.count, numbers.allSatisfy({ (0...255).contains($0.1) }) else { continue }
            let named = Dictionary(numbers, uniquingKeysWith: { a, _ in a })
            if let red = named["Rd  "], let green = named["Grn "], let blue = named["Bl  "] { return SRGBColor(red / 255, green / 255, blue / 255) }
            return SRGBColor(numbers[0].1 / 255, numbers[1].1 / 255, numbers[2].1 / 255)
        }
        return nil
    }

    /// The layer's planes as one picture: colour (or gray) with its transparency, not premultiplied.
    static func image(_ source: PSDFile.Layer, gray: Bool, space: CGColorSpace) -> CGImage? {
        let width = source.rect.width, height = source.rect.height, bytes = source.bytesPerSample
        let colorIDs = gray ? [0] : [0, 1, 2]
        let count = width * height * bytes
        var planes: [Data] = []
        for id in colorIDs {
            guard let plane = source.planes[id], plane.count == count else { return nil }
            planes.append(plane)
        }
        if let alpha = source.planes[-1] {
            guard alpha.count == count else { return nil }
            planes.append(alpha)
        } else {
            planes.append(Data(repeating: 0xFF, count: count))   // no transparency channel: opaque
        }
        let channels = planes.count, pixelBytes = channels * bytes
        var interleaved = Data(count: width * height * pixelBytes)
        interleaved.withUnsafeMutableBytes { (out: UnsafeMutableRawBufferPointer) in
            let o = out.bindMemory(to: UInt8.self)
            for (c, plane) in planes.enumerated() {
                plane.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                    let p = raw.bindMemory(to: UInt8.self)
                    for i in 0..<(width * height) {
                        for b in 0..<bytes { o[i * pixelBytes + c * bytes + b] = p[i * bytes + b] }
                    }
                }
            }
        }
        guard let provider = CGDataProvider(data: interleaved as CFData) else { return nil }
        var info = CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue)
        if bytes == 2 { info.insert(.byteOrder16Big) }
        return CGImage(width: width, height: height, bitsPerComponent: bytes * 8, bitsPerPixel: pixelBytes * 8, bytesPerRow: width * pixelBytes,
                       space: space, bitmapInfo: info, provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}
#endif
