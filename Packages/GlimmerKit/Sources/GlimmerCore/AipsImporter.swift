import CoreGraphics
import CoreText
import Foundation
import UniformTypeIdentifiers

extension UTType {
    /// A project saved by Glimmer for the web.
    public static let aipsProject = UTType(importedAs: "com.brattoo.glimmer.aips", conformingTo: .json)
}

public enum AipsImportError: Error, LocalizedError {
    case notAnAipsFile
    case invalid(String)

    public var errorDescription: String? {
        switch self {
        case .notAnAipsFile: "The file is not a Glimmer for the web project (.aips)."
        case .invalid(let reason): "The .aips project is damaged: \(reason)"
        }
    }
}

/// Imports projects from Glimmer for the web (`web/src/engine/serialize.ts`):
/// a JSON file with a flat node list, PNG data URLs for pixels and base64 R8 masks.
///
/// Text layers are rasterized until Glimmer has editable text (phase 6).
public enum AipsImporter {
    public static func importProject(_ data: Data) throws -> DocumentState {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              root["magic"] as? String == "aips" else {
            throw AipsImportError.notAnAipsFile
        }
        let width = int(root["width"]), height = int(root["height"])
        let range = 1...DocumentManifest.maxDimension
        guard range.contains(width), range.contains(height) else {
            throw AipsImportError.invalid("document size \(width)×\(height)")
        }
        let nodes = (root["nodes"] as? [[String: Any]]) ?? []
        var byID: [String: [String: Any]] = [:]
        for node in nodes {
            if let id = node["id"] as? String { byID[id] = node }
        }

        var newIDs: [String: UUID] = [:]
        var visiting = Set<String>()
        func layer(_ id: String) throws -> Layer? {
            guard let node = byID[id], !visiting.contains(id) else { return nil }
            visiting.insert(id)
            defer { visiting.remove(id) }
            let uuid = UUID()
            newIDs[id] = uuid
            return try makeLayer(node, id: uuid, documentSize: SIMD2(width, height)) { childIDs in
                try childIDs.compactMap(layer)
            }
        }

        let rootOrder = (root["rootOrder"] as? [String]) ?? []
        let layers = try rootOrder.compactMap(layer)
        var state = DocumentState(width: width, height: height, layers: layers)
        if let active = root["activeLayerId"] as? String, let id = newIDs[active] {
            state.activeLayerID = id
        }
        return state
    }

    // MARK: Nodes

    private static func makeLayer(
        _ node: [String: Any], id: UUID, documentSize: SIMD2<Int>,
        children: ([String]) throws -> [Layer]
    ) throws -> Layer {
        let kind = node["kind"] as? String ?? ""
        let name = node["name"] as? String ?? "Layer"
        let x = int(node["x"]), y = int(node["y"])
        var layer = Layer(
            id: id, name: name,
            isVisible: node["visible"] as? Bool ?? true,
            opacity: min(max(double(node["opacity"], 1), 0), 1),
            blendMode: BlendMode(rawValue: node["blendMode"] as? String ?? "normal") ?? .normal,
            isClipped: node["clipping"] as? Bool ?? false,
            effects: effects(node["effects"] as? [String: Any]),
            content: .raster(TileGrid())
        )
        if layer.blendMode == .passThrough { layer.blendMode = .normal }

        switch kind {
        case "raster":
            layer.content = .raster(try pixels(node["pixels"], origin: SIMD2(x, y)))
        case "smart":
            let natural = SIMD2(Double(int(node["naturalWidth"])), Double(int(node["naturalHeight"])))
            let t = node["transform"] as? [String: Any] ?? [:]
            let source = try pixels(node["pixels"], origin: .zero)
            layer.content = .smart(SmartObject(
                source: source, width: Int(natural.x), height: Int(natural.y),
                transform: .make(x: double(t["tx"], Double(x)), y: double(t["ty"], Double(y)),
                                 scaleX: double(t["sx"], 1), scaleY: double(t["sy"], 1),
                                 rotation: double(t["rot"], 0), sourceSize: natural)))
        case "text":
            let text = node["text"] as? [String: Any] ?? [:]
            layer.content = .raster(try rasterizeText(text, origin: SIMD2(x, y)))
            layer.name = name
        case "adjustment":
            let type = AdjustmentKind(rawValue: node["adjustmentType"] as? String ?? "") ?? .brightnessContrast
            layer.content = .adjustment(adjustment(type, node["params"] as? [String: Any] ?? [:]))
        case "group":
            let kids = try children(node["childrenIds"] as? [String] ?? [])
            layer.content = .group(LayerGroup(children: kids, isExpanded: !(node["collapsed"] as? Bool ?? false)))
        default:
            throw AipsImportError.invalid("unknown layer kind “\(kind)”")
        }

        if let m = node["mask"] as? [String: Any] {
            // Pixel layers have layer-local masks; adjustment and group masks cover the document.
            let docWide = kind == "adjustment" || kind == "group"
            layer.mask = try mask(m, origin: docWide ? .zero : SIMD2(x, y))
        }
        return layer
    }

    private static func pixels(_ value: Any?, origin: SIMD2<Int>) throws -> TileGrid {
        guard let url = value as? String, !url.isEmpty else { return TileGrid() }
        guard let comma = url.firstIndex(of: ","),
              let data = Data(base64Encoded: String(url[url.index(after: comma)...]), options: .ignoreUnknownCharacters) else {
            throw AipsImportError.invalid("unreadable pixels")
        }
        return try ImageImporter.tiles(from: ImageImporter.image(from: data), origin: origin)
    }

    /// R8 mask bytes (255 = visible) placed at `origin`; everything else reveals.
    private static func mask(_ m: [String: Any], origin: SIMD2<Int>) throws -> LayerMask {
        let w = int(m["width"]), h = int(m["height"])
        guard let b64 = m["data"] as? String, let bytes = Data(base64Encoded: b64, options: .ignoreUnknownCharacters),
              bytes.count >= w * h, w > 0, h > 0 else {
            return LayerMask(isEnabled: m["enabled"] as? Bool ?? true)
        }
        let rect = PixelRect(x: origin.x, y: origin.y, width: w, height: h)
        let s = TileGeometry.size
        var grid = TileGrid()
        var buffer = [Float16](repeating: 1, count: s * s * 4)
        bytes.withUnsafeBytes { raw in
            let src = raw.bindMemory(to: UInt8.self)
            for coord in rect.tileCoords {
                for i in buffer.indices { buffer[i] = 1 }
                let part = coord.rect.intersection(rect)
                for py in part.y..<part.maxY {
                    for px in part.x..<part.maxX {
                        let v = Float16(Float(src[(py - origin.y) * w + (px - origin.x)]) / 255)
                        let o = ((py - coord.rect.y) * s + (px - coord.rect.x)) * 4
                        buffer[o] = v; buffer[o + 1] = v; buffer[o + 2] = v; buffer[o + 3] = v
                    }
                }
                buffer.withUnsafeBytes {
                    if let tile = Tile.make(pixels: $0.baseAddress!, bytesPerRow: TileGeometry.bytesPerRow) {
                        // A fully revealing tile is the default; don't store it.
                        if case .solid(let c) = tile, c == SIMD4(1, 1, 1, 1) { return }
                        grid[coord] = tile
                    } else {
                        grid[coord] = .solid(.zero)  // fully hidden
                    }
                }
            }
        }
        return LayerMask(tiles: grid, defaultValue: 1, isEnabled: m["enabled"] as? Bool ?? true)
    }

    // MARK: Adjustments and effects

    static func adjustment(_ kind: AdjustmentKind, _ p: [String: Any]) -> Adjustment {
        var a = Adjustment(kind)
        for (key, value) in p {
            guard let n = value as? NSNumber else { continue }
            if CFGetTypeID(n) == CFBooleanGetTypeID() {
                a.flags[key] = n.boolValue
            } else {
                a.numbers[key] = n.doubleValue
            }
        }
        switch kind {
        case .colorBalance:
            for tone in ["shadows", "midtones", "highlights"] {
                if let v = p[tone] as? [Any], v.count >= 3 {
                    for (i, ch) in ["R", "G", "B"].enumerated() { a.numbers[tone + ch] = double(v[i], 0) }
                }
            }
        case .photoFilter:
            if let c = p["color"] as? [String: Any] { a.colors["color"] = color(c) }
        case .curves:
            for (key, channel) in [("rgb", CurveChannel.rgb), ("r", .red), ("g", .green), ("b", .blue)] {
                if let pts = p[key] as? [[String: Any]] {
                    a.curves[channel] = pts.map { CurvePoint(double($0["x"], 0), double($0["y"], 0)) }
                }
            }
        case .levels:
            a.levels[.rgb] = LevelsChannel(inBlack: double(p["inBlack"], 0), inWhite: double(p["inWhite"], 1),
                                           gamma: double(p["gamma"], 1), outBlack: double(p["outBlack"], 0),
                                           outWhite: double(p["outWhite"], 1))
        case .gradientMap:
            if let stops = p["stops"] as? [[String: Any]], stops.count >= 2 {
                a.gradient = stops.map {
                    let c = $0["color"] as? [String: Any] ?? [:]
                    return GradientStop(double($0["pos"], 0), color(c), opacity: double(c["a"], 1))
                }
            }
        default:
            break
        }
        return a
    }

    static func effects(_ fx: [String: Any]?) -> LayerEffects {
        var e = LayerEffects()
        guard let fx else { return e }
        func shadow(_ d: [String: Any]?) -> ShadowEffect? {
            guard let d else { return nil }
            var s = ShadowEffect()
            s.isEnabled = d["enabled"] as? Bool ?? true
            s.color = color(d["color"] as? [String: Any] ?? [:])
            s.opacity = double(d["opacity"], 0.75)
            s.angle = double(d["angle"], 120)
            s.distance = double(d["distance"], 10)
            s.size = double(d["size"], 10)
            s.spread = double(d["spread"], 0)
            s.blendMode = .normal  // the web app composites effects with normal "over"
            return s
        }
        e.dropShadow = shadow(fx["dropShadow"] as? [String: Any])
        e.innerShadow = shadow(fx["innerShadow"] as? [String: Any])
        if let d = fx["outerGlow"] as? [String: Any] {
            var g = GlowEffect()
            g.isEnabled = d["enabled"] as? Bool ?? true
            g.color = color(d["color"] as? [String: Any] ?? [:])
            g.opacity = double(d["opacity"], 0.75)
            g.size = double(d["size"], 10)
            g.blendMode = .normal
            e.outerGlow = g
        }
        if let d = fx["stroke"] as? [String: Any] {
            var s = StrokeEffect()
            s.isEnabled = d["enabled"] as? Bool ?? true
            s.color = color(d["color"] as? [String: Any] ?? [:])
            s.width = double(d["width"], 3)
            s.position = StrokeEffect.Position(rawValue: d["position"] as? String ?? "outside") ?? .outside
            e.stroke = s
        }
        if let d = fx["colorOverlay"] as? [String: Any] {
            var o = ColorOverlayEffect()
            o.isEnabled = d["enabled"] as? Bool ?? true
            o.color = color(d["color"] as? [String: Any] ?? [:])
            o.opacity = double(d["opacity"], 1)
            o.blendMode = BlendMode(rawValue: d["blendMode"] as? String ?? "normal") ?? .normal
            e.colorOverlay = o
        }
        return e
    }

    // MARK: Text (rasterized for now)

    private static func rasterizeText(_ t: [String: Any], origin: SIMD2<Int>) throws -> TileGrid {
        let string = t["text"] as? String ?? ""
        guard !string.isEmpty else { return TileGrid() }
        let size = max(1, double(t["fontSize"], 48))
        let lineHeight = size * max(0.1, double(t["lineHeight"], 1.2))
        let family = (t["fontFamily"] as? String ?? "")
            .split(separator: ",").first.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " \"'")) } ?? ""
        var font = CTFontCreateWithName((family.isEmpty ? "Helvetica" : family) as CFString, size, nil)
        var traits: CTFontSymbolicTraits = []
        if t["bold"] as? Bool == true { traits.insert(.traitBold) }
        if t["italic"] as? Bool == true { traits.insert(.traitItalic) }
        if !traits.isEmpty, let styled = CTFontCreateCopyWithSymbolicTraits(font, size, nil, traits, traits) {
            font = styled
        }
        let c = t["color"] as? [String: Any] ?? [:]
        let cgColor = CGColor(srgbRed: double(c["r"], 0), green: double(c["g"], 0), blue: double(c["b"], 0), alpha: double(c["a"], 1))
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): cgColor,
        ]
        let lines = string.components(separatedBy: "\n").map {
            CTLineCreateWithAttributedString(NSAttributedString(string: $0, attributes: attributes))
        }
        let widths = lines.map { CTLineGetTypographicBounds($0, nil, nil, nil) }
        // Match the web layout: 0.25 em side padding, 0.3 em top/bottom, ascent ≈ 0.8 em.
        let padX = size * 0.25, padY = size * 0.3
        let w = Int(((widths.max() ?? 0) + 2 * padX).rounded(.up))
        let h = Int((Double(lines.count) * lineHeight + 2 * padY).rounded(.up))
        guard w > 0, h > 0, let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                               space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                               bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return TileGrid()
        }
        let align = t["align"] as? String ?? "left"
        for (i, line) in lines.enumerated() {
            let lw = widths[i]
            let x = align == "center" ? (Double(w) - lw) / 2 : (align == "right" ? Double(w) - padX - lw : padX)
            let baseline = padY + size * 0.8 + Double(i) * lineHeight
            ctx.textPosition = CGPoint(x: x, y: Double(h) - baseline)
            CTLineDraw(line, ctx)
        }
        guard let image = ctx.makeImage() else { return TileGrid() }
        return try ImageImporter.tiles(from: image, origin: origin)
    }

    // MARK: Helpers

    private static func color(_ c: [String: Any]) -> SRGBColor {
        SRGBColor(double(c["r"], 0), double(c["g"], 0), double(c["b"], 0))
    }

    private static func double(_ v: Any?, _ fallback: Double) -> Double {
        (v as? NSNumber)?.doubleValue ?? fallback
    }

    private static func int(_ v: Any?) -> Int {
        Int(((v as? NSNumber)?.doubleValue ?? 0).rounded())
    }
}
