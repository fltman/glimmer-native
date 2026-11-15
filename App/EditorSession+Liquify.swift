import AppKit
import GlimmerAI
import GlimmerCore
import GlimmerRender
import GlimmerTools
import simd

/// Liquify in progress on one layer.
final class LiquifySession {
    let engine: LiquifyEngine
    let layerID: UUID
    var last: SIMD2<Double>?
    /// Pen pressure of the current event (1 for a mouse).
    var pressure = 1.0

    init(engine: LiquifyEngine, layerID: UUID) {
        self.engine = engine
        self.layerID = layerID
    }
}

extension EditorSession {
    // MARK: Liquify

    func beginLiquify() {
        commitLiveEdit()
        guard let metal, let layer = activeLayer, layer.isRaster else { return }
        do {
            let engine = try LiquifyEngine(context: metal, tiles: layer.tiles, region: state.bounds)
            liquify = LiquifySession(engine: engine, layerID: layer.id)
            tool = .move
        } catch {
            report(error)
        }
    }

    func liquifyDrag(to point: SIMD2<Double>, start: Bool, pressure: Double = 1) {
        guard let l = liquify else { return }
        l.pressure = pressure
        let radius = liquifySize / 2
        if start || l.last == nil {
            l.last = point
            if liquifyMode != .forward { liquifyDab(at: point, delta: .zero) }
            return
        }
        let last = l.last!
        let distance = simd_distance(point, last)
        // Forward warp: dabs spaced at ~1/8 of the radius; other modes keep working in place.
        let spacing = max(radius / 8, 1)
        let steps = max(Int((distance / spacing).rounded(.up)), 1)
        var previous = last
        for i in 1...steps {
            let p = last + (point - last) * (Double(i) / Double(steps))
            liquifyDab(at: p, delta: p - previous)
            previous = p
        }
        l.last = point
        publishLiquify()
    }

    func liquifyDab(at p: SIMD2<Double>, delta: SIMD2<Double>) {
        guard let l = liquify else { return }
        l.engine.dab(liquifyMode, at: p, delta: delta, radius: liquifySize / 2, strength: liquifyPressure * l.pressure)
    }

    func liquifyMouseUp() {
        liquify?.last = nil
        publishLiquify()
    }

    func publishLiquify() {
        guard let l = liquify, let result = try? liquifyResult(l) else { return }
        overrides = LayerOverrides(pixels: [l.layerID: result])
    }

    /// The warped layer; with a selection, only the selected area changes.
    private func liquifyResult(_ l: LiquifySession) throws -> TileGrid {
        let warped = try l.engine.render()
        guard let selection = state.selection, let metal, let area = selection.bounds(in: state.bounds) else { return warped }
        // Warped pixels inside the selection over the untouched layer outside it.
        let ops = try PixelOps(context: metal)
        let coords = area.tileCoords
        let inside = try ops.run(.keepSelected, on: warped, selection: selection, coords: coords)
        var onlyInside = TileGrid()
        for c in coords { onlyInside[c] = inside[c] }
        let outside = try ops.run(.erase, on: l.engine.original, selection: selection, coords: coords)
        let both = Layer(name: layerName("Liquify"), content: .group(LayerGroup(children: [
            Layer(name: layerName("Outside"), content: .raster(outside)), Layer(name: layerName("Inside"), content: .raster(onlyInside)),
        ])))
        var extent = state.bounds
        if let t = outside.tileBounds {
            let x0 = min(extent.x, t.x), y0 = min(extent.y, t.y)
            extent = PixelRect(x: x0, y: y0, width: max(extent.maxX, t.maxX) - x0, height: max(extent.maxY, t.maxY) - y0)
        }
        return try DocumentCompositor.rasterize(both, bounds: extent, blendSpace: .linear, context: metal)
    }

    func commitLiquify() {
        guard let l = liquify else { return }
        liquify = nil
        if !l.engine.isIdentity, let result = try? liquifyResult(l) {
            edit("Liquify") { $0.updateLayer(l.layerID) { $0.tiles = result } }
        }
        overrides = .none
    }

    func restoreAllLiquify() {
        guard let l = liquify else { return }
        l.engine.reset()
        l.last = nil
        overrides = .none
    }

    func cancelLiquify() {
        liquify = nil
        overrides = .none
    }
}
