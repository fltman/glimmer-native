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
