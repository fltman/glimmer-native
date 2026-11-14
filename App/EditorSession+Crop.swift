import AppKit
import GlimmerCore
import GlimmerRender
import GlimmerTools
import SwiftUI
import simd

extension EditorSession {
    // MARK: Crop

    struct CropSession: Equatable {
        var rect: CGRectLike
        /// width / height, nil = free.
        var aspect: Double?
        var dragging: Int?  // 0…7 handles, 8 = move, 9 = new rect
        var anchor: SIMD2<Double> = .zero
        /// Straighten angle (radians). `rect` lives in a frame rotated by `angle` about `pivot`.
        var angle: Double = 0
        var pivot: SIMD2<Double> = .zero
        /// Box size before straightening (the auto-fit scales from this).
        var baseSize: SIMD2<Double>?
        /// width / height when the drag began (⇧ keeps it).
        var dragAspect = 1.0

        func local(_ doc: SIMD2<Double>) -> SIMD2<Double> { rotate(doc - pivot, by: -angle) + pivot }
        func world(_ local: SIMD2<Double>) -> SIMD2<Double> { rotate(local - pivot, by: angle) + pivot }
        var corners: [SIMD2<Double>] {
            [SIMD2(rect.minX, rect.minY), SIMD2(rect.maxX, rect.minY), SIMD2(rect.maxX, rect.maxY), SIMD2(rect.minX, rect.maxY)].map(world)
        }

        func rotate(_ v: SIMD2<Double>, by a: Double) -> SIMD2<Double> {
            SIMD2(cos(a) * v.x - sin(a) * v.y, sin(a) * v.x + cos(a) * v.y)
        }
    }

    /// Straighten: rotates the crop box about its centre (degrees, −45…45).
    func setCropAngle(degrees: Double) {
        guard var c = cropSession else { return }
        let centre = c.world(SIMD2((c.rect.minX + c.rect.maxX) / 2, (c.rect.minY + c.rect.maxY) / 2))
        if abs(c.angle) < 1e-9 || c.baseSize == nil { c.baseSize = SIMD2(c.rect.width, c.rect.height) }
        let base = c.baseSize!
        let a = degrees * .pi / 180
        // Largest box of the original proportions that stays inside the image at this angle.
        let ca = abs(cos(a)), sa = abs(sin(a))
        let halfW = min(centre.x, Double(state.width) - centre.x), halfH = min(centre.y, Double(state.height) - centre.y)
        let k = min(1, 2 * halfW / max(base.x * ca + base.y * sa, 1e-9), 2 * halfH / max(base.x * sa + base.y * ca, 1e-9))
        let w = base.x * max(k, 0.01), h = base.y * max(k, 0.01)
        c.pivot = centre
        c.rect = CGRectLike(x0: centre.x - w / 2, y0: centre.y - h / 2, x1: centre.x + w / 2, y1: centre.y + h / 2)
        c.angle = a
        cropSession = c
    }

    func beginCrop() {
        commitLiveEdit()
        cropSession = CropSession(rect: CGRectLike(x0: 0, y0: 0, x1: Double(state.width), y1: Double(state.height)))
    }

    func cropMouseDown(at docPoint: SIMD2<Double>, viewTolerance: Double) {
        guard var c = cropSession else { return }
        let doc = c.local(docPoint)
        let tol = viewTolerance / max(canvas.transform.scale, 0.001)
        let r = c.rect
        let handles = cropHandles(r)
        c.dragAspect = r.height > 0 ? r.width / r.height : 1
        // A crop that still covers the whole image has nothing to move: dragging inside draws a new box.
        let isWholeImage = c.angle == 0 && r.minX <= 0.5 && r.minY <= 0.5
            && r.maxX >= Double(state.width) - 0.5 && r.maxY >= Double(state.height) - 0.5
        if let i = handles.firstIndex(where: { simd_distance($0, doc) < tol }) {
            c.dragging = i
        } else if !isWholeImage, doc.x > r.minX, doc.x < r.maxX, doc.y > r.minY, doc.y < r.maxY {
            c.dragging = 8
            c.anchor = doc
        } else {
            c.dragging = 9
            c.anchor = doc
            c.rect = CGRectLike(x0: doc.x, y0: doc.y, x1: doc.x, y1: doc.y)
        }
        cropSession = c
    }

    func cropHandles(_ r: CGRectLike) -> [SIMD2<Double>] {
        let mx = (r.minX + r.maxX) / 2, my = (r.minY + r.maxY) / 2
        return [SIMD2(r.minX, r.minY), SIMD2(mx, r.minY), SIMD2(r.maxX, r.minY), SIMD2(r.maxX, my),
                SIMD2(r.maxX, r.maxY), SIMD2(mx, r.maxY), SIMD2(r.minX, r.maxY), SIMD2(r.minX, my)]
    }

    /// Ends a crop drag. A click or a tiny new box puts the crop back on the whole image.
    func cropMouseUp() {
        guard var c = cropSession else { return }
        let tiny = 8 / max(canvas.transform.scale, 0.001)
        if c.dragging == 9, c.rect.width < tiny || c.rect.height < tiny {
            c.rect = CGRectLike(x0: 0, y0: 0, x1: Double(state.width), y1: Double(state.height))
            c.angle = 0
            c.baseSize = nil
        }
        c.dragging = nil
        cropSession = c
    }

    func cropDrag(to docPoint: SIMD2<Double>, fromCentre: Bool = false, constrain: Bool = false) {
        guard var c = cropSession, let handle = c.dragging else { return }
        let doc = c.local(docPoint)
        var r = c.rect
        switch handle {
        case 8:
            let d = doc - c.anchor
            r = CGRectLike(x0: r.minX + d.x, y0: r.minY + d.y, x1: r.maxX + d.x, y1: r.maxY + d.y)
            c.anchor = doc
        case 9:
            r = fromCentre
                ? CGRectLike(x0: 2 * c.anchor.x - doc.x, y0: 2 * c.anchor.y - doc.y, x1: doc.x, y1: doc.y)
                : CGRectLike(x0: c.anchor.x, y0: c.anchor.y, x1: doc.x, y1: doc.y)
        default:
            var x0 = r.minX, y0 = r.minY, x1 = r.maxX, y1 = r.maxY
            if [0, 6, 7].contains(handle) { x0 = doc.x }
            if [2, 3, 4].contains(handle) { x1 = doc.x }
            if [0, 1, 2].contains(handle) { y0 = doc.y }
            if [4, 5, 6].contains(handle) { y1 = doc.y }
            if fromCentre {
                // ⌥: the opposite edge mirrors the dragged one around the centre.
                let cx = (r.minX + r.maxX) / 2, cy = (r.minY + r.maxY) / 2
                if [0, 6, 7].contains(handle) { x1 = 2 * cx - x0 }
                if [2, 3, 4].contains(handle) { x0 = 2 * cx - x1 }
                if [0, 1, 2].contains(handle) { y1 = 2 * cy - y0 }
                if [4, 5, 6].contains(handle) { y0 = 2 * cy - y1 }
            }
            r = CGRectLike(x0: x0, y0: y0, x1: x1, y1: y1)
        }
        // ⇧: a square for a new box, the starting proportions when resizing.
        if let aspect = c.aspect ?? (constrain ? (handle == 9 ? 1 : c.dragAspect) : nil), handle != 8, r.width > 0 {
            // Keep the ratio by adjusting the height around the dragged edge.
            let h = r.width / aspect
            r = [0, 1, 2].contains(handle) || (handle == 9 && doc.y < c.anchor.y)
                ? CGRectLike(x0: r.minX, y0: r.maxY - h, x1: r.maxX, y1: r.maxY)
                : CGRectLike(x0: r.minX, y0: r.minY, x1: r.maxX, y1: r.minY + h)
        }
        c.rect = r
        c.baseSize = nil
        cropSession = c
    }

    func setCropAspect(_ aspect: Double?) {
        guard var c = cropSession else { return }
        c.aspect = aspect
        if let aspect {
            let r = c.rect
            let h = r.width / aspect
            c.rect = CGRectLike(x0: r.minX, y0: (r.minY + r.maxY) / 2 - h / 2, x1: r.maxX, y1: (r.minY + r.maxY) / 2 + h / 2)
        }
        cropSession = c
    }

    /// Resizes the canvas to the crop rectangle. Pixels outside are kept (move a
    /// layer to bring them back); every layer, mask, path and guide shifts.
    func applyCrop() {
        guard let c = cropSession, let metal else { return }
        if abs(c.angle) > 1e-6 {
            applyRotatedCrop(c, metal: metal)
            return
        }
        cropSession = nil
        let x = Int(c.rect.minX.rounded()), y = Int(c.rect.minY.rounded())
        let w = Int(c.rect.width.rounded()), h = Int(c.rect.height.rounded())
        guard w >= 1, h >= 1 else { return }
        do {
            let offset = SIMD2(-x, -y)
            let layers = try state.layers.map { try TileOperations.translate($0, by: offset, context: metal) }
            let d = SIMD2(Double(-x), Double(-y))
            edit("Crop") { state in
                state.layers = layers
                state.width = w
                state.height = h
                state.selection = nil
                state.paths = state.paths.map { path in
                    var p = path
                    p.subpaths = p.subpaths.map { sub in
                        var s = sub
                        s.anchors = s.anchors.map { a in
                            PathAnchor(a.point + d, handleIn: a.handleIn + d, handleOut: a.handleOut + d)
                        }
                        return s
                    }
                    return p
                }
                state.aids.guides = state.aids.guides.map { g in
                    var g = g
                    g.position += g.axis == .vertical ? d.x : d.y
                    return g
                }
            }
            canvas.perform(.fitToWindow)
        } catch {
            report(error)
        }
    }

    /// Straightened crop: every layer is resampled into the rotated box. Pixels
    /// outside the box are dropped (they'd no longer line up with the canvas).
    /// Text layers are rasterized; smart objects and gradients keep their parameters.
    func applyRotatedCrop(_ c: CropSession, metal: MetalContext) {
        cropSession = nil
        let w = Int(c.rect.width.rounded()), h = Int(c.rect.height.rounded())
        guard w >= 1, h >= 1 else { return }
        let centre = c.world(SIMD2((c.rect.minX + c.rect.maxX) / 2, (c.rect.minY + c.rect.maxY) / 2))
        // p' = R(−angle)(p − centre) + size / 2
        let phi = -c.angle
        let cs = cos(phi), sn = sin(phi)
        let t = SIMD2(Double(w) / 2, Double(h) / 2) - SIMD2(cs * centre.x - sn * centre.y, sn * centre.x + cs * centre.y)
        let rot = GlimmerCore.AffineTransform(a: cs, b: sn, c: -sn, d: cs, tx: t.x, ty: t.y)
        transformCanvas(rot, width: w, height: h, actionName: "Crop", metal: metal)
    }

    enum CanvasFlip { case horizontal, vertical, rotateRight, rotateLeft, rotate180 }

    /// Flips or rotates the whole image (all layers, masks, paths).
    func flipCanvas(_ kind: CanvasFlip) {
        guard let metal else { return }
        commitLiveEdit()
        let w = Double(state.width), h = Double(state.height)
        let (t, nw, nh, name): (GlimmerCore.AffineTransform, Int, Int, String) = switch kind {
        case .horizontal: (.init(a: -1, d: 1, tx: w), state.width, state.height, "Flip Horizontal")
        case .vertical: (.init(a: 1, d: -1, ty: h), state.width, state.height, "Flip Vertical")
        // (x, y) → (h − y, x): a quarter turn clockwise on screen (y down).
        case .rotateRight: (.init(a: 0, b: 1, c: -1, d: 0, tx: h), state.height, state.width, "Rotate 90° Clockwise")
        case .rotateLeft: (.init(a: 0, b: -1, c: 1, d: 0, ty: w), state.height, state.width, "Rotate 90° Counterclockwise")
        case .rotate180: (.init(a: -1, d: -1, tx: w, ty: h), state.width, state.height, "Rotate 180°")
        }
        transformCanvas(t, width: nw, height: nh, actionName: name, metal: metal)
    }

    /// Resamples every layer through `rot` into a canvas of `w` × `h`. Pixels
    /// outside it are dropped; text layers are rasterized.
    func transformCanvas(_ rot: GlimmerCore.AffineTransform, width w: Int, height h: Int, actionName: String,
                                 metal: MetalContext) {
        let limit = PixelRect(x: 0, y: 0, width: w, height: h)
        let docBounds = state.bounds
        do {
            let renderer = try SmartObjectRenderer(context: metal)
            func resample(_ grid: TileGrid, fillTo: Float? = nil) throws -> TileGrid {
                var grid = grid
                if let v = fillTo {  // materialize a mask's default inside the old canvas
                    for coord in docBounds.tileCoords where grid[coord] == nil { grid[coord] = .solid(SIMD4(repeating: v)) }
                }
                guard let b = grid.tileBounds else { return TileGrid() }
                let source = try TileOperations.translate(grid, by: SIMD2(-b.x, -b.y), context: metal)
                let m = Self.concat(rot, GlimmerCore.AffineTransform(tx: Double(b.x), ty: Double(b.y)))
                return try renderer.render(SmartObject(source: source, width: b.width, height: b.height, transform: m), limit: limit)
            }
            func rotateLayer(_ layer: Layer) throws -> Layer {
                var l = layer
                if let path = layer.vectorMask {
                    let p = path.applying(rot)
                    l.vectorMask = p
                    var m = p.asSelection.asMask
                    m.isEnabled = layer.mask?.isEnabled ?? true
                    m.density = layer.mask?.density ?? 1
                    m.feather = layer.mask?.feather ?? 0
                    l.mask = m
                } else if let mask = layer.mask {
                    l.mask?.tiles = try resample(mask.tiles, fillTo: mask.defaultValue > 0 ? mask.defaultValue : nil)
                }
                switch layer.content {
                case .raster(let grid):
                    l.content = .raster(try resample(grid))
                case .text:
                    let raster = try DocumentCompositor.rasterize(layer, bounds: docBounds, blendSpace: state.blendSpace, context: metal)
                    l.content = .raster(try resample(raster))
                case .smart(var smart):
                    smart.transform = Self.concat(rot, smart.transform)
                    l.content = .smart(smart)
                case .fill(.gradient(var g)):
                    g.start = rot.apply(g.start)
                    g.end = rot.apply(g.end)
                    l.content = .fill(.gradient(g))
                case .group(var group):
                    group.children = try group.children.map(rotateLayer)
                    l.content = .group(group)
                case .fill, .adjustment:
                    break
                }
                return l
            }
            let layers = try state.layers.map(rotateLayer)
            edit(actionName) { state in
                state.layers = layers
                state.width = w
                state.height = h
                state.selection = nil
                state.aids.guides = []
                state.paths = state.paths.map { path in
                    var p = path
                    p.subpaths = p.subpaths.map { sub in
                        var s = sub
                        s.anchors = s.anchors.map { a in
                            PathAnchor(rot.apply(a.point), handleIn: rot.apply(a.handleIn), handleOut: rot.apply(a.handleOut))
                        }
                        return s
                    }
                    return p
                }
            }
            canvas.perform(.fitToWindow)
        } catch {
            report(error)
        }
    }

    /// `outer ∘ inner` (inner applied first).
    static func concat(_ outer: GlimmerCore.AffineTransform, _ inner: GlimmerCore.AffineTransform) -> GlimmerCore.AffineTransform {
        outer.concatenating(inner)
    }
}
