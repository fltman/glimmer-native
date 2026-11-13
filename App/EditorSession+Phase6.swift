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
    }

    struct TransformSession {
        var layerID: UUID
        var source: TileGrid
        var isSmart: Bool
        var box: TransformBox
        var handle: TransformHandle?
        var originalSmartTransform: GlimmerCore.AffineTransform?
    }

    func beginTransform() {
        commitLiveEdit()
        guard let metal, let layer = activeLayer else { return }
        do {
            switch layer.content {
            case .raster(let grid):
                guard let bounds = grid.tileBounds.flatMap({ contentBounds(of: grid, within: $0) }) else { return }
                let source = try TileOperations.translate(grid, by: SIMD2(-bounds.x, -bounds.y), context: metal)
                let size = SIMD2(Double(bounds.width), Double(bounds.height))
                transformSession = TransformSession(layerID: layer.id, source: source, isSmart: false,
                    box: TransformBox(x: Double(bounds.x), y: Double(bounds.y), scaleX: 1, scaleY: 1, rotation: 0, sourceSize: size))
            case .smart(let smart):
                let d = smart.transform.decompose(sourceSize: smart.sourceSize)
                transformSession = TransformSession(layerID: layer.id, source: smart.source, isSmart: true,
                    box: TransformBox(x: d.x, y: d.y, scaleX: d.scaleX, scaleY: d.scaleY, rotation: d.rotation,
                                      sourceSize: smart.sourceSize), originalSmartTransform: smart.transform)
            default:
                errorMessage = "Free Transform works on pixel layers and smart objects."
                return
            }
            updateTransformPreview()
        } catch {
            report(error)
        }
    }

    /// Tight bounds of non-transparent pixels (tile bounds refined by reading edge tiles).
    private func contentBounds(of grid: TileGrid, within tiles: PixelRect) -> PixelRect? {
        let sel = Selection(tiles: grid.mapAlphaOnly())
        return sel.bounds(in: tiles)
    }

    func updateTransformPreview() {
        guard let t = transformSession, let metal else { return }
        do {
            let smart = SmartObject(source: t.source, width: Int(t.box.sourceSize.x), height: Int(t.box.sourceSize.y),
                                    transform: t.box.affine)
            let grid = try SmartObjectRenderer(context: metal).render(smart, limit: RegionOps_public.expand(state.bounds, by: 512))
            overrides = LayerOverrides(pixels: [t.layerID: grid])
            if t.isSmart {
                // Smart objects preview through their own transform.
                overrides = LayerOverrides()
                document.state.updateLayer(t.layerID) { layer in
                    if case .smart(var s) = layer.content { s.transform = t.box.affine; layer.content = .smart(s) }
                }
            }
        } catch {
            report(error)
        }
    }

    func commitTransform() {
        guard let t = transformSession else { return }
        transformSession = nil
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
        if t.isSmart, let original = t.originalSmartTransform {
            document.state.updateLayer(t.layerID) { layer in
                if case .smart(var s) = layer.content { s.transform = original; layer.content = .smart(s) }
            }
        }
        overrides = .none
    }

    func transformMouseDown(at doc: SIMD2<Double>, viewTolerance: Double) {
        guard var t = transformSession else { return }
        let tol = viewTolerance / max(canvas.transform.scale, 0.001)
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
            } else {
                let v = doc - t.box.centre
                t.handle = .rotate(startAngle: atan2(v.y, v.x), box: t.box)
            }
        }
        transformSession = t
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
        }
        transformSession = t
        updateTransformPreview()
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

    // MARK: Crop

    struct CropSession: Equatable {
        var rect: CGRectLike
        /// width / height, nil = free.
        var aspect: Double?
        var dragging: Int?  // 0…7 handles, 8 = move, 9 = new rect
        var anchor: SIMD2<Double> = .zero
    }

    func beginCrop() {
        commitLiveEdit()
        cropSession = CropSession(rect: CGRectLike(x0: 0, y0: 0, x1: Double(state.width), y1: Double(state.height)))
    }

    func cropMouseDown(at doc: SIMD2<Double>, viewTolerance: Double) {
        guard var c = cropSession else { return }
        let tol = viewTolerance / max(canvas.transform.scale, 0.001)
        let r = c.rect
        let handles = cropHandles(r)
        if let i = handles.firstIndex(where: { simd_distance($0, doc) < tol }) {
            c.dragging = i
        } else if doc.x > r.minX, doc.x < r.maxX, doc.y > r.minY, doc.y < r.maxY {
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

    func cropDrag(to doc: SIMD2<Double>) {
        guard var c = cropSession, let handle = c.dragging else { return }
        var r = c.rect
        switch handle {
        case 8:
            let d = doc - c.anchor
            r = CGRectLike(x0: r.minX + d.x, y0: r.minY + d.y, x1: r.maxX + d.x, y1: r.maxY + d.y)
            c.anchor = doc
        case 9:
            r = CGRectLike(x0: c.anchor.x, y0: c.anchor.y, x1: doc.x, y1: doc.y)
        default:
            var x0 = r.minX, y0 = r.minY, x1 = r.maxX, y1 = r.maxY
            if [0, 6, 7].contains(handle) { x0 = doc.x }
            if [2, 3, 4].contains(handle) { x1 = doc.x }
            if [0, 1, 2].contains(handle) { y0 = doc.y }
            if [4, 5, 6].contains(handle) { y1 = doc.y }
            r = CGRectLike(x0: x0, y0: y0, x1: x1, y1: y1)
        }
        if let aspect = c.aspect, handle != 8, r.width > 0 {
            // Keep the ratio by adjusting the height around the dragged edge.
            let h = r.width / aspect
            r = [0, 1, 2].contains(handle) || (handle == 9 && doc.y < c.anchor.y)
                ? CGRectLike(x0: r.minX, y0: r.maxY - h, x1: r.maxX, y1: r.maxY)
                : CGRectLike(x0: r.minX, y0: r.minY, x1: r.maxX, y1: r.minY + h)
        }
        c.rect = r
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

    // MARK: Text

    /// Type tool click: edit the text layer under the pointer, or start a new one.
    func typeClick(at doc: SIMD2<Double>) {
        commitLiveEdit()
        if let hit = state.allLayers.reversed().first(where: { layer in
            guard layer.isVisible, case .text(let t) = layer.content else { return false }
            let b = t.bounds
            return doc.x >= Double(b.x) && doc.x <= Double(b.maxX) && doc.y >= Double(b.y) && doc.y <= Double(b.maxY)
        }) {
            setActiveLayer(hit.id)
            editingText = hit.id
            return
        }
        let text = TextLayer(string: "", fontName: textDefaults.fontName, size: textDefaults.size, color: foreground,
                             alignment: textDefaults.alignment, origin: doc - SIMD2(0, textDefaults.size * 0.9))
        let layer = Layer(name: "Text", content: .text(text))
        edit("New Text Layer") { $0.insertLayerAboveActive(layer) }
        editingText = layer.id
    }

    func commitText(_ string: String, id: UUID) {
        guard let layer = state.layer(id: id), case .text(var text) = layer.content else { return }
        if string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            edit("Delete Empty Text") { _ = $0.removeLayer(id) }
            return
        }
        guard string != text.string else { return }
        text.string = string
        let name = String(string.split(separator: "\n").first ?? "Text").prefix(32)
        edit("Edit Text") { $0.updateLayer(id) { $0.content = .text(text); $0.name = String(name) } }
    }

    /// Live change to the active text layer's style (options bar).
    func updateText(_ change: @escaping (inout TextLayer) -> Void) {
        if let layer = activeLayer, case .text = layer.content {
            liveLayer("Text Style") { layer in
                if case .text(var t) = layer.content { change(&t); layer.content = .text(t) }
            }
        }
        var d = TextLayer(string: "", fontName: textDefaults.fontName, size: textDefaults.size, color: .black,
                          alignment: textDefaults.alignment, origin: .zero)
        change(&d)
        textDefaults = (d.fontName, d.size, d.alignment)
    }

    // MARK: Pen tool and paths

    var activePath: VectorPath? { state.paths.first { $0.id == activePathID } }

    /// Click: drag an existing anchor/handle, close the open subpath, or add an anchor.
    func penMouseDown(at doc: SIMD2<Double>, viewTolerance: Double) {
        commitLiveEdit()
        let tol = viewTolerance / max(canvas.transform.scale, 0.001)
        if let path = activePath {
            for (si, sub) in path.subpaths.enumerated() {
                for (ai, a) in sub.anchors.enumerated() {
                    if simd_distance(a.handleOut, doc) < tol, a.handleOut != a.point { penDrag = (si, ai, 2); return }
                    if simd_distance(a.handleIn, doc) < tol, a.handleIn != a.point { penDrag = (si, ai, 1); return }
                    if simd_distance(a.point, doc) < tol {
                        // Clicking the first anchor of the open subpath closes it.
                        if ai == 0, si == path.subpaths.count - 1, !sub.isClosed, sub.anchors.count > 2, penOpen {
                            updatePath { $0.subpaths[si].isClosed = true }
                            penOpen = false
                            return
                        }
                        penDrag = (si, ai, 0)
                        return
                    }
                }
            }
        }
        if activePath == nil {
            let path = VectorPath(name: "Path \(state.paths.count + 1)")
            edit("New Path") { $0.paths.append(path) }
            activePathID = path.id
        }
        updatePath { path in
            if !self.penOpen || path.subpaths.isEmpty || path.subpaths.last!.isClosed {
                path.subpaths.append(Subpath())
            }
            path.subpaths[path.subpaths.count - 1].anchors.append(PathAnchor(doc))
        }
        penOpen = true
        let si = activePath!.subpaths.count - 1
        penDrag = (si, activePath!.subpaths[si].anchors.count - 1, 3)  // 3 = pull out handles
    }

    func penDragged(to doc: SIMD2<Double>, breakSymmetry: Bool) {
        guard let drag = penDrag else { return }
        let (si, ai, part) = drag
        updatePath(live: true) { path in
            var a = path.subpaths[si].anchors[ai]
            switch part {
            case 0:
                let d = doc - a.point
                a.point += d; a.handleIn += d; a.handleOut += d
            case 1:
                a.handleIn = doc
                if !breakSymmetry { a.handleOut = a.point * 2 - doc }
            case 2:
                a.handleOut = doc
                if !breakSymmetry { a.handleIn = a.point * 2 - doc }
            default:
                a.handleOut = doc
                a.handleIn = breakSymmetry ? a.point : a.point * 2 - doc
            }
            path.subpaths[si].anchors[ai] = a
        }
    }

    func penMouseUp() {
        if penDrag != nil { commitLiveEdit() }
        penDrag = nil
    }

    func finishPathSegment() {
        penOpen = false
    }

    private func updatePath(live: Bool = false, _ change: @escaping (inout VectorPath) -> Void) {
        guard let id = activePathID else { return }
        let apply: (inout DocumentState) -> Void = { state in
            if let i = state.paths.firstIndex(where: { $0.id == id }) { change(&state.paths[i]) }
        }
        if live { self.live("Edit Path", apply) } else { edit("Edit Path", apply) }
    }

    func selection(from path: VectorPath) -> Selection {
        let shapes = path.polygons().filter { $0.count > 2 }.map(Selection.polygon)
        guard var s = shapes.first else { return Selection() }
        for o in shapes.dropFirst() { s = s.combined(with: o, .add) }
        return s
    }

    func makeSelection(fromPath id: UUID) {
        guard let path = state.paths.first(where: { $0.id == id }) else { return }
        let s = selection(from: path)
        edit("Make Selection") { $0.selection = s }
    }

    func fillPath(_ id: UUID) {
        guard let metal, let layer = activeLayer, layer.isRaster,
              let path = state.paths.first(where: { $0.id == id }) else {
            errorMessage = "Select a pixel layer to fill the path on."
            return
        }
        let s = selection(from: path)
        guard let bounds = s.bounds(in: RegionOps_public.expand(state.bounds, by: 4096)) else { return }
        do {
            let filled = try PixelOps(context: metal).run(.paint, on: layer.tiles, selection: s, coords: bounds.tileCoords,
                                                         color: SIMD4(foreground.linear, 1))
            edit("Fill Path") { $0.updateLayer(layer.id) { $0.tiles = filled } }
        } catch {
            report(error)
        }
    }

    func strokePath(_ id: UUID) {
        guard let metal, let layer = activeLayer, layer.isRaster,
              let path = state.paths.first(where: { $0.id == id }) else {
            errorMessage = "Select a pixel layer to stroke the path on."
            return
        }
        do {
            var settings = brush
            settings.pressureSize = false
            let engine = try StrokeEngine(context: metal, tiles: layer.tiles, target: .pixels, erase: false,
                                          color: SIMD4(foreground.linear, 1), opacity: Float(brush.opacity), selection: nil)
            for (i, poly) in path.polygons().enumerated() where !poly.isEmpty {
                var sampler = StrokeSampler(settings: settings)
                var dabs = sampler.begin(.init(poly[0]))
                for p in poly.dropFirst() { dabs += sampler.move(to: .init(p)) }
                if path.subpaths[i].isClosed { dabs += sampler.move(to: .init(poly[0])) }
                engine.add(dabs)
            }
            engine.finish()
            let result = engine.result
            edit("Stroke Path") { $0.updateLayer(layer.id) { $0.tiles = result } }
        } catch {
            report(error)
        }
    }

    func deletePath(_ id: UUID) {
        edit("Delete Path") { $0.paths.removeAll { $0.id == id } }
        if activePathID == id { activePathID = nil }
    }

    func renamePath(_ id: UUID, to name: String) {
        edit("Rename Path") { state in
            if let i = state.paths.firstIndex(where: { $0.id == id }) { state.paths[i].name = name }
        }
    }

    // MARK: Shapes

    enum ShapeKind: String, CaseIterable {
        case rectangle, ellipse, line
        var title: String { rawValue.capitalized }
    }

    /// A shape becomes a solid colour fill layer with the shape as its mask, so
    /// it stays recolourable and editable.
    func finishShape() {
        guard let drag = shapeDrag else { return }
        shapeDrag = nil
        let r = CGRectLike(x0: drag.start.x, y0: drag.start.y, x1: drag.end.x, y1: drag.end.y)
        let mask: Selection
        switch shapeKind {
        case .rectangle:
            guard r.width >= 1, r.height >= 1 else { return }
            mask = .rectangle(r)
        case .ellipse:
            guard r.width >= 1, r.height >= 1 else { return }
            mask = .ellipse(in: r)
        case .line:
            let v = drag.end - drag.start
            guard simd_length(v) >= 1 else { return }
            let n = SIMD2(-v.y, v.x) / simd_length(v) * max(shapeLineWidth, 1) / 2
            mask = .polygon([drag.start + n, drag.end + n, drag.end - n, drag.start - n])
        }
        let layer = Layer(name: shapeKind.title, mask: mask.asMask, content: .fill(.solid(foreground)))
        edit("New \(shapeKind.title)") { $0.insertLayerAboveActive(layer) }
    }

    // MARK: Guides, grid, snapping

    func addGuide(_ axis: Guide.Axis, at position: Double) {
        edit("New Guide") { $0.aids.guides.append(Guide(axis: axis, position: position)) }
    }

    func moveGuide(_ id: UUID, to position: Double, live: Bool) {
        let apply: (inout DocumentState) -> Void = { state in
            if let i = state.aids.guides.firstIndex(where: { $0.id == id }) { state.aids.guides[i].position = position }
        }
        if live { self.live("Move Guide", apply) } else { edit("Move Guide", apply) }
    }

    func removeGuide(_ id: UUID) {
        edit("Delete Guide") { $0.aids.guides.removeAll { $0.id == id } }
    }

    /// Snaps a document point to guides, the grid and the document edges (within a few screen pixels).
    func snapped(_ p: SIMD2<Double>) -> SIMD2<Double> {
        guard state.aids.snap else { return p }
        let tol = 6 / max(canvas.transform.scale, 0.001)
        var xs = [0.0, Double(state.width)], ys = [0.0, Double(state.height)]
        for g in state.aids.guides { if g.axis == .vertical { xs.append(g.position) } else { ys.append(g.position) } }
        if state.aids.grid.isVisible {
            let s = state.aids.grid.spacing
            xs.append((p.x / s).rounded() * s)
            ys.append((p.y / s).rounded() * s)
        }
        var out = p
        if let x = xs.min(by: { abs($0 - p.x) < abs($1 - p.x) }), abs(x - p.x) < tol { out.x = x }
        if let y = ys.min(by: { abs($0 - p.y) < abs($1 - p.y) }), abs(y - p.y) < tol { out.y = y }
        return out
    }
}

/// `RegionOps` is internal to GlimmerRender; tools only need `expand`.
enum RegionOps_public {
    static func expand(_ r: PixelRect, by n: Int) -> PixelRect {
        PixelRect(x: r.x - n, y: r.y - n, width: r.width + 2 * n, height: r.height + 2 * n)
    }
}

extension TileGrid {
    /// The same tiles (alpha is what selection bounds read).
    func mapAlphaOnly() -> TileGrid { self }
}
