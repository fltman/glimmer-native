import AppKit
import GlimmerCore
import GlimmerRender
import GlimmerTools
import SwiftUI
import simd

extension EditorSession {
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
        return SIMD2(p.x + (snapDelta([p.x], vertical: true) ?? 0), p.y + (snapDelta([p.y], vertical: false) ?? 0))
    }

    /// How far to shift a box so one of its edges or its centre lands on a snap line.
    func snapOffset(forBoxAt origin: SIMD2<Double>, size: SIMD2<Double>) -> SIMD2<Double> {
        guard state.aids.snap else { return .zero }
        return SIMD2(snapDelta([origin.x, origin.x + size.x / 2, origin.x + size.x], vertical: true) ?? 0,
                     snapDelta([origin.y, origin.y + size.y / 2, origin.y + size.y], vertical: false) ?? 0)
    }

    /// The smallest shift that puts one of `values` on a snap line (canvas edges and
    /// centre, guides, the grid), if any is within reach.
    private func snapDelta(_ values: [Double], vertical: Bool) -> Double? {
        let tol = 6 / max(canvas.transform.scale, 0.001)
        let extent = Double(vertical ? state.width : state.height)
        var lines = [0.0, extent, extent / 2]
        for g in state.aids.guides where (g.axis == .vertical) == vertical { lines.append(g.position) }
        var best: Double?
        for v in values {
            var candidates = lines
            if state.aids.grid.isVisible {
                // Snap to the finer lines too.
                let s = state.aids.grid.spacing / Double(max(state.aids.grid.subdivisions, 1))
                if s > 0.5 { candidates.append((v / s).rounded() * s) }
            }
            for line in candidates where abs(line - v) < min(tol, abs(best ?? .infinity)) { best = line - v }
        }
        return best
    }
}
