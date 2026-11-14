import AppKit
import GlimmerCore
import GlimmerRender
import GlimmerTools
import SwiftUI
import simd

extension DocumentState {
    /// Text bound to a path follows it: refresh the baseline of every text layer on `id`.
    mutating func syncText(toPath id: UUID) {
        guard let line = paths.first(where: { $0.id == id })?.polygons().first, line.count > 1 else { return }
        for layer in allLayers {
            guard case .text(let t) = layer.content, t.onPathID == id, t.onPath != line else { continue }
            updateLayer(layer.id) { l in
                var bound = t
                bound.onPath = line
                l.content = .text(bound)
            }
        }
    }
}

extension EditorSession {
    // MARK: Pen tool and paths

    var activePath: VectorPath? {
        if let p = state.paths.first(where: { $0.id == activePathID }) { return p }
        if let layer = shapeLayerForActivePath { return layer.vectorMask }
        return nil
    }

    /// The shape layer whose vector mask is being edited, if any.
    var shapeLayerForActivePath: Layer? {
        guard let id = activePathID else { return nil }
        return state.allLayers.first { $0.vectorMask?.id == id }
    }

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

    /// Esc while drawing: the unfinished subpath goes (and the path, if that was all of it).
    func discardUnfinishedPath() {
        guard penOpen, let path = activePath, let last = path.subpaths.last, !last.isClosed else {
            finishPathSegment()
            return
        }
        penOpen = false
        let id = path.id
        edit("Discard Path") { state in
            guard let i = state.paths.firstIndex(where: { $0.id == id }) else { return }
            state.paths[i].subpaths.removeLast()
            if state.paths[i].subpaths.isEmpty { state.paths.remove(at: i) }
        }
        if !state.paths.contains(where: { $0.id == id }) { activePathID = nil }
    }

    func updatePath(live: Bool = false, _ change: @escaping (inout VectorPath) -> Void) {
        guard let id = activePathID else { return }
        let apply: (inout DocumentState) -> Void = { state in
            if let i = state.paths.firstIndex(where: { $0.id == id }) {
                change(&state.paths[i])
                state.syncText(toPath: id)
            } else if let layer = state.allLayers.first(where: { $0.vectorMask?.id == id }) {
                // Shape layer: edit the vector mask and re-rasterize the mask from it.
                state.updateLayer(layer.id) { l in
                    guard var path = l.vectorMask else { return }
                    change(&path)
                    l.vectorMask = path
                    var mask = path.asSelection.asMask
                    mask.isEnabled = l.mask?.isEnabled ?? true
                    mask.density = l.mask?.density ?? 1
                    mask.feather = l.mask?.feather ?? 0
                    l.mask = mask
                }
            }
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
        edit("Delete Path") { state in
            state.paths.removeAll { $0.id == id }
            // Text on the deleted path keeps its shape but is no longer bound to anything.
            for layer in state.allLayers {
                guard case .text(var t) = layer.content, t.onPathID == id else { continue }
                t.onPathID = nil
                state.updateLayer(layer.id) { $0.content = .text(t) }
            }
        }
        if activePathID == id { activePathID = nil }
    }

    func renamePath(_ id: UUID, to name: String) {
        edit("Rename Path") { state in
            if let i = state.paths.firstIndex(where: { $0.id == id }) { state.paths[i].name = name }
        }
    }
}
