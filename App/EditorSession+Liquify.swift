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

    func liquifyDrag(to point: SIMD2<Double>, start: Bool) {
        guard let l = liquify else { return }
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
        l.engine.dab(liquifyMode, at: p, delta: delta, radius: liquifySize / 2, strength: liquifyPressure)
    }

    func liquifyMouseUp() {
        liquify?.last = nil
        publishLiquify()
    }

    func publishLiquify() {
        guard let l = liquify, let result = try? l.engine.render() else { return }
        overrides = LayerOverrides(pixels: [l.layerID: result])
    }

    func commitLiquify() {
        guard let l = liquify else { return }
        liquify = nil
        if !l.engine.isIdentity, let result = try? l.engine.render() {
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
