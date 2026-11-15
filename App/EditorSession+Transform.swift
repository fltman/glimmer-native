import AppKit
import GlimmerCore
import GlimmerRender
import GlimmerTools
import SwiftUI
import simd

// MARK: Free transform

/// The box a free transform edits: an unrotated, scaled box at (x, y), rotated about its centre.
struct TransformBox: Equatable {
    var x: Double, y: Double, scaleX: Double, scaleY: Double, rotation: Double
    let sourceSize: SIMD2<Double>

    var affine: GlimmerCore.AffineTransform {
        .make(x: x, y: y, scaleX: scaleX, scaleY: scaleY, rotation: rotation, sourceSize: sourceSize)
    }

    var size: SIMD2<Double> { SIMD2(sourceSize.x * scaleX, sourceSize.y * scaleY) }
    var centre: SIMD2<Double> { SIMD2(x, y) + size / 2 }

    func toDoc(_ local: SIMD2<Double>) -> SIMD2<Double> {
        let c = cos(rotation), s = sin(rotation)
        return centre + SIMD2(c * local.x - s * local.y, s * local.x + c * local.y)
    }

    func toLocal(_ doc: SIMD2<Double>) -> SIMD2<Double> {
        let v = doc - centre, c = cos(rotation), s = sin(rotation)
        return SIMD2(c * v.x + s * v.y, -s * v.x + c * v.y)
    }

    /// Corners (tl, tr, br, bl) and edge midpoints (t, r, b, l) in document space.
    var corners: [SIMD2<Double>] {
        let h = size / 2
        return [SIMD2(-h.x, -h.y), SIMD2(h.x, -h.y), SIMD2(h.x, h.y), SIMD2(-h.x, h.y)].map(toDoc)
    }

    var edges: [SIMD2<Double>] {
        let h = size / 2
        return [SIMD2(0, -h.y), SIMD2(h.x, 0), SIMD2(0, h.y), SIMD2(-h.x, 0)].map(toDoc)
    }

    /// Moves one side so the opposite side stays put. `sx`/`sy` are -1, 0 or 1.
    mutating func drag(sx: Double, sy: Double, to doc: SIMD2<Double>, proportional: Bool) {
        let h = size / 2
        let p = toLocal(doc)
        var newHalf = h
        var shift = SIMD2<Double>.zero
        if sx != 0 {
            let fixed = -sx * h.x
            let w = max(abs(p.x - fixed), 1)
            newHalf.x = w / 2
            shift.x = (fixed + sx * w / 2) - 0
        }
        if sy != 0 {
            let fixed = -sy * h.y
            let hh = max(abs(p.y - fixed), 1)
            newHalf.y = hh / 2
            shift.y = (fixed + sy * hh / 2) - 0
        }
        if proportional, sx != 0, sy != 0 {
            let k = max(newHalf.x / h.x, newHalf.y / h.y)
            newHalf = h * k
            shift = SIMD2(-sx * h.x + sx * newHalf.x, -sy * h.y + sy * newHalf.y)
        }
        let newCentre = toDoc(shift)
        scaleX = newHalf.x * 2 / sourceSize.x
        scaleY = newHalf.y * 2 / sourceSize.y
        x = newCentre.x - newHalf.x
        y = newCentre.y - newHalf.y
    }
}

extension EditorSession {
    enum TransformHandle: Equatable {
        case move(start: SIMD2<Double>, box: TransformBox)
        case rotate(startAngle: Double, box: TransformBox)
        case scale(sx: Double, sy: Double)
        /// Free-corner modes: which corner/edge, where the drag started, the quad then.
        case corner(Int, start: SIMD2<Double>, quad: [SIMD2<Double>])
        case edge(Int, start: SIMD2<Double>, quad: [SIMD2<Double>])
        case moveQuad(start: SIMD2<Double>, quad: [SIMD2<Double>])
    }

    enum TransformMode: String, CaseIterable {
        case scaleRotate, distort, skew, perspective
        var title: String {
            switch self {
            case .scaleRotate: "Scale & Rotate"
            case .distort: "Distort"
            case .skew: "Skew"
            case .perspective: "Perspective"
            }
        }
    }

    struct TransformSession {
        var layerID: UUID
        var source: TileGrid
        var isSmart: Bool
        var box: TransformBox
        var handle: TransformHandle?
        var originalSmartTransform: GlimmerCore.AffineTransform?
        /// Free corners (top-left, top-right, bottom-right, bottom-left) once the
        /// layer has been distorted, skewed or put in perspective.
        var quad: [SIMD2<Double>]?
        var mode = TransformMode.scaleRotate
        /// Shape layers transform their vector mask (no resampling).
        var originalVector: VectorPath?
        /// A group transforms every layer with content inside it with one box (source space
        /// = the union of their bounds, starting at `groupOrigin`).
        var members: [GroupMember] = []
        var groupOrigin = SIMD2<Double>(0, 0)

        var corners: [SIMD2<Double>] { quad ?? box.corners }
        var edges: [SIMD2<Double>] {
            let c = corners
            return (0..<4).map { (c[$0] + c[($0 + 1) % 4]) / 2 }
        }
        var transform: GlimmerCore.AffineTransform {
            quad.map { GlimmerCore.AffineTransform.quad(sourceSize: box.sourceSize, to: $0) } ?? box.affine
        }

        func contains(_ p: SIMD2<Double>) -> Bool {
            // Convex quad: same side of every edge.
            let c = corners
            var sign = 0.0
            for i in 0..<4 {
                let a = c[i], b = c[(i + 1) % 4]
                let cross = (b.x - a.x) * (p.y - a.y) - (b.y - a.y) * (p.x - a.x)
                if cross != 0 {
                    if sign == 0 { sign = cross } else if (cross > 0) != (sign > 0) { return false }
                }
            }
            return true
        }
    }

    /// A layer inside a transformed group, as it was when the transform began.
    enum GroupMember {
        /// Pixels (text rendered to pixels), translated to their own bounds' origin, which sits
        /// at `offset` in the group's source space.
        case pixels(id: UUID, source: TileGrid, size: SIMD2<Int>, offset: SIMD2<Double>)
        case smart(id: UUID, original: GlimmerCore.AffineTransform)
        case shape(id: UUID, original: VectorPath)
        /// Text keeps its layout and gets the transform, so it stays editable; only a
        /// non-affine transform (distort, perspective) would turn it into pixels.
        case text(id: UUID, original: TextLayer)
    }

    /// Free Transform on a group (all its layers with content) or on one text layer: one box
    /// around their content; every pixel, text, shape and smart object layer is transformed with
    /// it, as one undo step. Adjustment layers and plain fills have nothing to place. Pixel masks
    /// would stay where they are, so a group with one inside is refused rather than transformed wrongly.
    func beginMemberTransform(id: UUID, layers: [Layer], metal: MetalContext) throws {
        var members: [GroupMember] = []
        var lo = SIMD2(Double.infinity, Double.infinity), hi = -lo
        func extend(_ a: SIMD2<Double>, _ b: SIMD2<Double>) { lo = simd_min(lo, a); hi = simd_max(hi, b) }
        var pending: [(UUID, TileGrid, PixelRect)] = []
        for layer in layers {
            if layer.mask != nil, layer.vectorMask == nil, layers.count > 1 {
                errorMessage = String(localized: "“\(layer.name)” in this group has a layer mask, which Free Transform can't move with it yet. Transform the layers one by one, or apply the mask first.")
                return
            }
            if case .text(let text) = layer.content {
                let b = text.bounds
                extend(SIMD2(Double(b.x), Double(b.y)), SIMD2(Double(b.x + b.width), Double(b.y + b.height)))
                members.append(.text(id: layer.id, original: text))
                continue
            }
            switch layer.content {
            case .raster(let grid):
                guard let b = grid.tileBounds.flatMap({ contentBounds(of: grid, within: $0) }) else { continue }
                pending.append((layer.id, grid, b))
                extend(SIMD2(Double(b.x), Double(b.y)), SIMD2(Double(b.x + b.width), Double(b.y + b.height)))
            case .smart(let smart):
                let z = smart.sourceSize
                let corners = [SIMD2(0, 0), SIMD2(z.x, 0), z, SIMD2(0, z.y)].map(smart.transform.apply)
                extend(corners.reduce(corners[0], simd_min), corners.reduce(corners[0], simd_max))
                members.append(.smart(id: layer.id, original: smart.transform))
            case .fill where layer.vectorMask != nil:
                guard let r = layer.vectorMask!.controlBounds, r.width > 0, r.height > 0 else { continue }
                extend(SIMD2(r.minX, r.minY), SIMD2(r.maxX, r.maxY))
                members.append(.shape(id: layer.id, original: layer.vectorMask!))
            default:
                continue
            }
        }
        guard lo.x < hi.x, lo.y < hi.y else {
            errorMessage = String(localized: "This group has nothing Free Transform can move.")
            return
        }
        for (id, grid, b) in pending {
            let source = try TileOperations.translate(grid, by: SIMD2(-b.x, -b.y), context: metal)
            members.append(.pixels(id: id, source: source, size: SIMD2(b.width, b.height), offset: SIMD2(Double(b.x), Double(b.y)) - lo))
        }
        var session = TransformSession(layerID: id, source: TileGrid(), isSmart: false,
            box: TransformBox(x: lo.x, y: lo.y, scaleX: 1, scaleY: 1, rotation: 0, sourceSize: hi - lo))
        session.members = members
        session.groupOrigin = lo
        transformSession = session
        originalShapeState = state
        updateTransformPreview()
    }

    /// Places every layer of a transformed group for the current box.
    private func previewGroup(_ t: TransformSession, metal: MetalContext) throws {
        let toGroup = GlimmerCore.AffineTransform(tx: -t.groupOrigin.x, ty: -t.groupOrigin.y)
        let docToDoc = t.transform.concatenating(toGroup)  // old document position → new
        var pixels: [UUID: TileGrid] = [:]
        let renderer = try SmartObjectRenderer(context: metal)
        let affine = docToDoc.isAffine
        for member in t.members {
            switch member {
            case .text(let id, let original):
                if affine {
                    var text = original
                    text.transform = docToDoc.concatenating(original.transform ?? .identity)
                    document.state.updateLayer(id) { $0.content = .text(text) }
                } else {
                    // Distort or perspective: shown as the pixels it would become.
                    document.state.updateLayer(id) { $0.content = .text(original) }
                    let b = original.bounds
                    let source = try TileOperations.translate(DocumentCompositor.rasterize(original), by: SIMD2(-b.x, -b.y), context: metal)
                    let smart = SmartObject(source: source, width: b.width, height: b.height,
                                            transform: docToDoc.concatenating(GlimmerCore.AffineTransform(tx: Double(b.x), ty: Double(b.y))))
                    pixels[id] = try renderer.render(smart, limit: RegionOps_public.expand(state.bounds, by: 512))
                }
            case .pixels(let id, let source, let size, let offset):
                let smart = SmartObject(source: source, width: size.x, height: size.y,
                                        transform: t.transform.concatenating(GlimmerCore.AffineTransform(tx: offset.x, ty: offset.y)))
                pixels[id] = try renderer.render(smart, limit: RegionOps_public.expand(state.bounds, by: 512))
            case .smart(let id, let original):
                document.state.updateLayer(id) { layer in
                    if case .smart(var s) = layer.content { s.transform = docToDoc.concatenating(original); layer.content = .smart(s) }
                }
            case .shape(let id, let original):
                let path = original.applying(docToDoc)
                document.state.updateLayer(id) { l in
                    l.vectorMask = path
                    var mask = path.asSelection.asMask
                    mask.isEnabled = l.mask?.isEnabled ?? true
                    mask.density = l.mask?.density ?? 1
                    mask.feather = l.mask?.feather ?? 0
                    l.mask = mask
                }
            }
        }
        overrides = LayerOverrides(pixels: pixels)
    }

    func beginTransform() {
        commitLiveEdit()
        guard let metal, let layer = activeLayer else { return }
        do {
            if layer.isGroup {
                try beginMemberTransform(id: layer.id, layers: Array(layer.subtree.dropFirst()), metal: metal)
                return
            }
            if layer.isText {
                // Text keeps its layout and gets the transform: it stays editable.
                try beginMemberTransform(id: layer.id, layers: [layer], metal: metal)
                return
            }
            switch layer.content {
            case .raster(let grid):
                guard let bounds = grid.tileBounds.flatMap({ contentBounds(of: grid, within: $0) }) else { return }
                let source = try TileOperations.translate(grid, by: SIMD2(-bounds.x, -bounds.y), context: metal)
                let size = SIMD2(Double(bounds.width), Double(bounds.height))
                transformSession = TransformSession(layerID: layer.id, source: source, isSmart: false,
                    box: TransformBox(x: Double(bounds.x), y: Double(bounds.y), scaleX: 1, scaleY: 1, rotation: 0, sourceSize: size))
            case .smart(let smart):
                let d = smart.transform.decompose(sourceSize: smart.sourceSize)
                var session = TransformSession(layerID: layer.id, source: smart.source, isSmart: true,
                    box: TransformBox(x: d.x, y: d.y, scaleX: d.scaleX, scaleY: d.scaleY, rotation: d.rotation,
                                      sourceSize: smart.sourceSize), originalSmartTransform: smart.transform)
                if !smart.transform.isAffine {
                    let z = smart.sourceSize
                    session.quad = [SIMD2(0, 0), SIMD2(z.x, 0), z, SIMD2(0, z.y)].map(smart.transform.apply)
                    session.mode = .distort
                }
                transformSession = session
            case .fill where layer.vectorMask != nil:
                let path = layer.vectorMask!
                guard let r = path.controlBounds, r.width > 0, r.height > 0 else { return }
                var session = TransformSession(layerID: layer.id, source: TileGrid(), isSmart: false,
                    box: TransformBox(x: r.minX, y: r.minY, scaleX: 1, scaleY: 1, rotation: 0, sourceSize: SIMD2(r.width, r.height)))
                session.originalVector = path
                transformSession = session
                originalShapeState = state
            default:
                errorMessage = String(localized: "Free Transform works on pixel, text and shape layers, smart objects and groups.")
                return
            }
            updateTransformPreview()
        } catch {
            report(error)
        }
    }

    /// Tight bounds of non-transparent pixels (tile bounds refined by reading edge tiles).
    func contentBounds(of grid: TileGrid, within tiles: PixelRect) -> PixelRect? {
        let sel = Selection(tiles: grid.mapAlphaOnly())
        return sel.bounds(in: tiles)
    }

    func updateTransformPreview() {
        guard let t = transformSession, let metal else { return }
        if !t.members.isEmpty {
            do { try previewGroup(t, metal: metal) } catch { report(error) }
            return
        }
        if let original = t.originalVector, let r = original.controlBounds {
            // Source space = the path's bounds at the origin.
            let toSource = GlimmerCore.AffineTransform(tx: -r.minX, ty: -r.minY)
            let path = original.applying(t.transform.concatenating(toSource))
            document.state.updateLayer(t.layerID) { l in
                l.vectorMask = path
                var mask = path.asSelection.asMask
                mask.isEnabled = l.mask?.isEnabled ?? true
                mask.density = l.mask?.density ?? 1
                mask.feather = l.mask?.feather ?? 0
                l.mask = mask
            }
            return
        }
        do {
            let smart = SmartObject(source: t.source, width: Int(t.box.sourceSize.x), height: Int(t.box.sourceSize.y),
                                    transform: t.transform)
            let grid = try SmartObjectRenderer(context: metal).render(smart, limit: RegionOps_public.expand(state.bounds, by: 512))
            overrides = LayerOverrides(pixels: [t.layerID: grid])
            if t.isSmart {
                // Smart objects preview through their own transform.
                overrides = LayerOverrides()
                document.state.updateLayer(t.layerID) { layer in
                    if case .smart(var s) = layer.content { s.transform = t.transform; layer.content = .smart(s) }
                }
            }
        } catch {
            report(error)
        }
    }

    /// Text layers a commit would turn into pixels (a distort or perspective box).
    var textLayersToRasterize: Int {
        guard let t = transformSession else { return 0 }
        let toGroup = GlimmerCore.AffineTransform(tx: -t.groupOrigin.x, ty: -t.groupOrigin.y)
        guard !t.transform.concatenating(toGroup).isAffine else { return 0 }
        return t.members.filter { if case .text = $0 { true } else { false } }.count
    }

    /// `confirmed`: the user agreed to text becoming pixels (asked first, see DocumentView).
    func commitTransform(confirmed: Bool = false) {
        guard let t = transformSession else { return }
        if !confirmed, textLayersToRasterize > 0 {
            rasterizeTextConfirmation = textLayersToRasterize  // asks; the box stays until then
            return
        }
        transformSession = nil
        if !t.members.isEmpty, let before = originalShapeState {
            // Smart objects, shapes and editable text are already placed; pixels come from the preview.
            originalShapeState = nil
            for (id, grid) in overrides.pixels {
                document.state.updateLayer(id) { $0.content = .raster(grid) }
            }
            overrides = .none
            document.commitInteractiveEdit("Free Transform", undoManager: undoManager, before: before)
            return
        }
        if t.originalVector != nil, let before = originalShapeState {
            originalShapeState = nil
            document.commitInteractiveEdit("Free Transform", undoManager: undoManager, before: before)
            return
        }
        if t.isSmart {
            // Already applied live; record a single undo step from the original transform.
            let current = state
            var before = state
            before.updateLayer(t.layerID) { layer in
                if case .smart(var s) = layer.content, let original = t.originalSmartTransform {
                    s.transform = original
                    layer.content = .smart(s)
                }
            }
            document.state = current
            document.commitInteractiveEdit("Free Transform", undoManager: undoManager, before: before)
        } else if let grid = overrides.pixels[t.layerID] {
            edit("Free Transform") { $0.updateLayer(t.layerID) { $0.tiles = grid } }
        }
        overrides = .none
    }

    func cancelTransform() {
        guard let t = transformSession else { return }
        transformSession = nil
        if !t.members.isEmpty, let before = originalShapeState {
            originalShapeState = nil
            document.state = before
            overrides = .none
            return
        }
        if t.originalVector != nil, let before = originalShapeState {
            originalShapeState = nil
            document.state = before
            return
        }
        if t.isSmart, let original = t.originalSmartTransform {
            document.state.updateLayer(t.layerID) { layer in
                if case .smart(var s) = layer.content { s.transform = original; layer.content = .smart(s) }
            }
        }
        overrides = .none
    }

    func transformMouseDown(at doc: SIMD2<Double>, viewTolerance: Double, command: Bool = false) {
        guard var t = transformSession else { return }
        let tol = viewTolerance / max(canvas.transform.scale, 0.001)
        // ⌘ on a corner distorts, like Photoshop, from any mode.
        let mode = command && t.mode == .scaleRotate ? TransformMode.distort : t.mode
        if mode != .scaleRotate || t.quad != nil {
            let quad = t.corners
            if let i = quad.firstIndex(where: { simd_distance($0, doc) < tol }) {
                t.quad = quad
                t.handle = mode == .skew ? .edge(i, start: doc, quad: quad) : .corner(i, start: doc, quad: quad)
                if mode == .skew {
                    // Skewing from a corner moves its top/bottom edge.
                    t.handle = .edge(i < 2 ? 0 : 2, start: doc, quad: quad)
                }
                t.mode = mode
            } else if let i = t.edges.firstIndex(where: { simd_distance($0, doc) < tol }) {
                t.quad = quad
                t.handle = .edge(i, start: doc, quad: quad)
                t.mode = mode
            } else if t.contains(doc) {
                t.quad = t.quad ?? (mode == .scaleRotate ? nil : quad)
                t.handle = t.quad == nil ? .move(start: doc, box: t.box) : .moveQuad(start: doc, quad: quad)
            } else if t.quad == nil, nearCorner(doc, t.corners) {
                let v = doc - t.box.centre
                t.handle = .rotate(startAngle: atan2(v.y, v.x), box: t.box)
            } else {
                applyTransformFromClick()
                return
            }
            transformSession = t
            return
        }
        let signs: [(Double, Double)] = [(-1, -1), (1, -1), (1, 1), (-1, 1)]
        let edgeSigns: [(Double, Double)] = [(0, -1), (1, 0), (0, 1), (-1, 0)]
        if let i = t.box.corners.firstIndex(where: { simd_distance($0, doc) < tol }) {
            t.handle = .scale(sx: signs[i].0, sy: signs[i].1)
        } else if let i = t.box.edges.firstIndex(where: { simd_distance($0, doc) < tol }) {
            t.handle = .scale(sx: edgeSigns[i].0, sy: edgeSigns[i].1)
        } else {
            let local = t.box.toLocal(doc), h = t.box.size / 2
            if abs(local.x) <= h.x, abs(local.y) <= h.y {
                t.handle = .move(start: doc, box: t.box)
            } else if nearCorner(doc, t.box.corners) {
                let v = doc - t.box.centre
                t.handle = .rotate(startAngle: atan2(v.y, v.x), box: t.box)
            } else {
                applyTransformFromClick()
                return
            }
        }
        transformSession = t
    }

    /// Rotation starts just outside a corner (about 32 points); a click farther away applies the transform.
    private func nearCorner(_ doc: SIMD2<Double>, _ corners: [SIMD2<Double>]) -> Bool {
        let reach = 32 / max(canvas.transform.scale, 0.001)
        return corners.contains { simd_distance($0, doc) < reach }
    }

    private func applyTransformFromClick() {
        commitTransform()
        tool = .move
    }

    func transformDrag(to doc: SIMD2<Double>, shift: Bool) {
        guard var t = transformSession, let handle = t.handle else { return }
        switch handle {
        case .move(let start, let box):
            t.box = box
            t.box.x += (doc - start).x
            t.box.y += (doc - start).y
        case .rotate(let startAngle, let box):
            let v = doc - box.centre
            var angle = box.rotation + atan2(v.y, v.x) - startAngle
            if shift { angle = (angle / (.pi / 12)).rounded() * (.pi / 12) }
            let centre = box.centre
            t.box = box
            t.box.rotation = angle
            t.box.x = centre.x - t.box.size.x / 2
            t.box.y = centre.y - t.box.size.y / 2
        case .scale(let sx, let sy):
            // Corners scale proportionally unless Shift is held (Photoshop's default).
            t.box.drag(sx: sx, sy: sy, to: doc, proportional: sx != 0 && sy != 0 && !shift)
        case .moveQuad(let start, let quad):
            t.quad = quad.map { $0 + doc - start }
        case .corner(let i, let start, let quad):
            var q = quad
            let delta = doc - start
            q[i] = quad[i] + delta
            if t.mode == .perspective {
                // The corner sharing the top/bottom edge mirrors the move along that edge.
                let partner = i ^ 1
                let edge = simd_normalize(quad[partner] - quad[i])
                q[partner] = quad[partner] - edge * simd_dot(delta, edge)
            }
            if Self.isConvex(q) { t.quad = q }
        case .edge(let i, let start, let quad):
            // Skew: slide the edge's two corners along the edge direction.
            var q = quad
            let a = i, b = (i + 1) % 4
            let dir = simd_normalize(quad[b] - quad[a])
            let delta = t.mode == .skew ? dir * simd_dot(doc - start, dir) : doc - start
            q[a] = quad[a] + delta
            q[b] = quad[b] + delta
            if Self.isConvex(q) { t.quad = q }
        }
        transformSession = t
        updateTransformPreview()
    }

    static func isConvex(_ q: [SIMD2<Double>]) -> Bool {
        var sign = 0.0
        for i in 0..<4 {
            let a = q[i], b = q[(i + 1) % 4], c = q[(i + 2) % 4]
            let cross = (b.x - a.x) * (c.y - b.y) - (b.y - a.y) * (c.x - b.x)
            if abs(cross) < 1e-9 { return false }
            if sign == 0 { sign = cross } else if (cross > 0) != (sign > 0) { return false }
        }
        return true
    }

    func setTransformMode(_ mode: TransformMode) {
        guard var t = transformSession else { return }
        t.mode = mode
        if mode != .scaleRotate, t.quad == nil { t.quad = t.box.corners }
        transformSession = t
    }

    func transformMouseUp() {
        transformSession?.handle = nil
    }

    /// Numeric edits from the options bar.
    func setTransform(scaleXPercent: Double? = nil, scaleYPercent: Double? = nil, degrees: Double? = nil) {
        guard var t = transformSession else { return }
        let centre = t.box.centre
        if let s = scaleXPercent { t.box.scaleX = max(s, 0.1) / 100 }
        if let s = scaleYPercent { t.box.scaleY = max(s, 0.1) / 100 }
        if let d = degrees { t.box.rotation = d * .pi / 180 }
        t.box.x = centre.x - t.box.size.x / 2
        t.box.y = centre.y - t.box.size.y / 2
        transformSession = t
        updateTransformPreview()
    }
}
