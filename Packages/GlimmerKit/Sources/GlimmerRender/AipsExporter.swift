import CoreGraphics
import CoreText
import Foundation
import GlimmerCore
import ImageIO
import UniformTypeIdentifiers

/// Writes projects for Glimmer for the web (`web/src/engine/serialize.ts`), the
/// reverse of `AipsImporter`.
///
/// The web app has no fill layers, perspective transforms or smart filters, so
/// those layers are written as pixels. Everything else keeps its settings.
public enum AipsExporter {
    public static func exportProject(_ state: DocumentState, context: MetalContext) throws -> Data {
        var nodes: [[String: Any]] = []
        func add(_ layer: Layer, parent: UUID?) throws {
            var node = try self.node(for: layer, in: state, context: context)
            node["id"] = layer.id.uuidString
            node["name"] = layer.name
            node["visible"] = layer.isVisible
            node["opacity"] = layer.opacity
            // The web app has no pass-through groups.
            node["blendMode"] = layer.blendMode.webMode.rawValue
            node["parentId"] = parent.map { $0.uuidString as Any } ?? NSNull()
            if case .group(let g) = layer.content {
                node["childrenIds"] = g.children.map(\.id.uuidString)
                for child in g.children { try add(child, parent: layer.id) }
            }
            nodes.append(node)
        }
        for layer in state.layers { try add(layer, parent: nil) }

        let file: [String: Any] = [
            "magic": "aips",
            "version": 1,
            "width": state.width,
            "height": state.height,
            "activeLayerId": state.activeLayerID.map { $0.uuidString as Any } ?? NSNull(),
            "rootOrder": state.layers.map(\.id.uuidString),
            "nodes": nodes,
            "paths": state.paths.map { path in
                [
                    "id": path.id.uuidString,
                    "name": path.name,
                    "subpaths": path.subpaths.map { sub in
                        [
                            "closed": sub.isClosed,
                            "anchors": sub.anchors.map { a in
                                ["x": a.point.x, "y": a.point.y, "inX": a.handleIn.x, "inY": a.handleIn.y,
                                 "outX": a.handleOut.x, "outY": a.handleOut.y]
                            },
                        ] as [String: Any]
                    },
                ] as [String: Any]
            },
            "guides": state.aids.guides.map {
                ["id": $0.id.uuidString, "axis": $0.axis == .vertical ? "v" : "h", "pos": $0.position] as [String: Any]
            },
            "grid": ["visible": state.aids.grid.isVisible, "size": state.aids.grid.spacing,
                     "subdivisions": state.aids.grid.subdivisions] as [String: Any],
            "rulersVisible": state.aids.rulersVisible,
            "snapEnabled": state.aids.snap,
        ]
        return try JSONSerialization.data(withJSONObject: file)
    }

    // MARK: Nodes

    private static func node(for layer: Layer, in state: DocumentState, context: MetalContext) throws -> [String: Any] {
        var node: [String: Any] = ["clipping": layer.isClipped]
        // Where the layer's own box is; masks of pixel layers are stored relative to it.
        var box = state.bounds
        switch layer.content {
        case .group(let g):
            node = ["kind": "group", "collapsed": !g.isExpanded]
        case .adjustment(let a):
            node["kind"] = "adjustment"
            node["adjustmentType"] = a.kind.rawValue
            node["params"] = params(a)
        case .text(let t) where layer.mask == nil && t.transform == nil:
            // (Transformed text goes out as pixels: the web app can't rotate or skew text.)
            // (Masked text goes out as pixels: the web app sizes text boxes itself, so a mask wouldn't line up.)
            node["kind"] = "text"
            // The web app draws text with 0.25 em side and 0.1 em top padding inside its box.
            box = PixelRect(x: Int((t.origin.x - t.size * 0.25).rounded()), y: Int((t.origin.y - t.size * 0.1).rounded()),
                            width: t.bounds.width, height: t.bounds.height)
            node["text"] = text(t)
        case .smart(let s) where s.transform.isAffine && s.filters.isEmpty:
            let size = SIMD2(Double(s.width), Double(s.height))
            let d = s.transform.decompose(sourceSize: size)
            node["kind"] = "smart"
            node["naturalWidth"] = s.width
            node["naturalHeight"] = s.height
            node["transform"] = ["tx": d.x, "ty": d.y, "sx": d.scaleX, "sy": d.scaleY, "rot": d.rotation]
            node["pixels"] = try png(of: s.source, in: PixelRect(x: 0, y: 0, width: max(s.width, 1), height: max(s.height, 1)),
                                     context: context)
            box = s.bounds
        default:
            // Pixels, and everything the web app can't describe (fills, shapes, warped smart objects).
            let grid: TileGrid
            if case .raster(let tiles) = layer.content {
                grid = tiles
            } else {
                var plain = layer
                plain.mask = nil
                plain.effects = LayerEffects()
                plain.opacity = 1
                plain.blendMode = .normal
                plain.isClipped = false
                grid = try DocumentCompositor.rasterize(plain, bounds: state.bounds, blendSpace: state.blendSpace, context: context)
            }
            box = grid.tileBounds ?? PixelRect(x: 0, y: 0, width: 1, height: 1)
            node["kind"] = "raster"
            node["pixels"] = try png(of: grid, in: box, context: context)
        }
        if node["kind"] as? String != "group" {
            if node["kind"] as? String != "adjustment" {
                node["x"] = box.x
                node["y"] = box.y
                node["width"] = box.width
                node["height"] = box.height
                if let fx = effects(layer.effects) { node["effects"] = fx }
            }
        }
        if let mask = layer.mask {
            let docWide = layer.isGroup || layer.isAdjustment
            node["mask"] = try self.mask(mask, in: docWide ? state.bounds : box, context: context)
        }
        return node
    }

    /// The grid's pixels inside `rect` as a PNG data URL.
    private static func png(of grid: TileGrid, in rect: PixelRect, context: MetalContext) throws -> String {
        let image = try self.image(of: grid, in: rect, context: context)
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            throw RenderError.resourceCreationFailed("PNG")
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { throw RenderError.resourceCreationFailed("PNG") }
        return "data:image/png;base64," + (data as Data).base64EncodedString()
    }

    private static func image(of grid: TileGrid, in rect: PixelRect, context: MetalContext) throws -> CGImage {
        let moved = rect.x == 0 && rect.y == 0 ? grid : try TileOperations.translate(grid, by: SIMD2(-rect.x, -rect.y), context: context)
        let single = DocumentState(width: rect.width, height: rect.height, layers: [Layer(name: "pixels", content: .raster(moved))])
        return try ImageExporter.flattenedSRGB(single, context: context)
    }

    /// One byte per pixel, 255 = visible, base64 encoded.
    private static func mask(_ mask: LayerMask, in rect: PixelRect, context: MetalContext) throws -> [String: Any] {
        // The mask value is in every channel of its tiles, so alpha carries it exactly.
        var grid = mask.tiles
        if mask.defaultValue >= 0.5 {
            for coord in rect.tileCoords where grid[coord] == nil { grid[coord] = .solid(SIMD4(1, 1, 1, 1)) }
        }
        let image = try self.image(of: grid, in: rect, context: context)
        let w = rect.width, h = rect.height
        var rgba = [UInt8](repeating: 0, count: w * h * 4)
        rgba.withUnsafeMutableBytes { buffer in
            let ctx = CGContext(data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            ctx?.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        var bytes = Data(count: w * h)
        bytes.withUnsafeMutableBytes { out in
            let o = out.bindMemory(to: UInt8.self)
            for i in 0..<(w * h) { o[i] = rgba[i * 4 + 3] }
        }
        return ["width": w, "height": h, "enabled": mask.isEnabled, "data": bytes.base64EncodedString()]
    }

    // MARK: Settings

    private static func color(_ c: SRGBColor, alpha: Double = 1) -> [String: Any] {
        ["r": c.r, "g": c.g, "b": c.b, "a": alpha]
    }

    private static func text(_ t: TextLayer) -> [String: Any] {
        let font = t.font
        let traits = CTFontGetSymbolicTraits(font)
        var out: [String: Any] = [
            "text": t.string,
            "fontFamily": CTFontCopyFamilyName(font) as String,
            "fontSize": t.size,
            "color": color(t.color),
            "align": t.alignment.rawValue,
            "bold": traits.contains(.traitBold),
            "italic": traits.contains(.traitItalic),
            "lineHeight": t.lineHeight,
            "pathId": t.onPathID.map { $0.uuidString as Any } ?? NSNull(),
        ]
        if let w = t.warp {
            out["warp"] = ["style": w.style.rawValue, "bend": w.bend, "horizontal": w.horizontal, "vertical": w.vertical]
        }
        return out
    }

    /// The reverse of `AipsImporter.adjustment`.
    private static func params(_ a: Adjustment) -> [String: Any] {
        var p: [String: Any] = [:]
        for (k, v) in a.numbers { p[k] = v }
        for (k, v) in a.flags { p[k] = v }
        switch a.kind {
        case .colorBalance:
            for tone in ["shadows", "midtones", "highlights"] {
                p[tone] = ["R", "G", "B"].map { a.numbers[tone + $0] ?? 0 }
                for ch in ["R", "G", "B"] { p[tone + ch] = nil }
            }
        case .photoFilter:
            if let c = a.colors["color"] { p["color"] = color(c) }
        case .curves:
            for (key, channel) in [("rgb", CurveChannel.rgb), ("r", .red), ("g", .green), ("b", .blue)] {
                if let points = a.curves[channel] { p[key] = points.map { ["x": $0.x, "y": $0.y] } }
            }
        case .levels:
            if let l = a.levels[.rgb] {
                p["inBlack"] = l.inBlack
                p["inWhite"] = l.inWhite
                p["gamma"] = l.gamma
                p["outBlack"] = l.outBlack
                p["outWhite"] = l.outWhite
            }
        case .gradientMap:
            p["stops"] = a.gradient.map { ["pos": $0.position, "color": color($0.color, alpha: $0.opacity)] as [String: Any] }
        default:
            break
        }
        return p
    }

    private static func effects(_ e: LayerEffects) -> [String: Any]? {
        var fx: [String: Any] = [:]
        func shadow(_ s: ShadowEffect) -> [String: Any] {
            ["enabled": s.isEnabled, "color": color(s.color), "opacity": s.opacity, "angle": s.angle,
             "distance": s.distance, "size": s.size, "spread": s.spread]
        }
        if let s = e.dropShadow { fx["dropShadow"] = shadow(s) }
        if let s = e.innerShadow { fx["innerShadow"] = shadow(s) }
        if let g = e.outerGlow {
            fx["outerGlow"] = ["enabled": g.isEnabled, "color": color(g.color), "opacity": g.opacity, "size": g.size] as [String: Any]
        }
        if let s = e.stroke {
            fx["stroke"] = ["enabled": s.isEnabled, "color": color(s.color), "opacity": s.opacity, "width": s.width,
                            "position": s.position.rawValue] as [String: Any]
        }
        if let o = e.colorOverlay {
            fx["colorOverlay"] = ["enabled": o.isEnabled, "color": color(o.color), "opacity": o.opacity,
                                  "blendMode": o.blendMode.webMode.rawValue] as [String: Any]
        }
        return fx.isEmpty ? nil : fx
    }
}
