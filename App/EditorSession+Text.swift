import AppKit
import GlimmerCore
import GlimmerRender
import GlimmerTools
import SwiftUI
import simd

extension EditorSession {
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
        // Clicking on the active path starts text along it.
        if let path = activePath, let line = path.polygons().first, line.count > 1 {
            let tol = 8 / max(canvas.transform.scale, 0.001)
            let near = zip(line, line.dropFirst()).contains { a, b in Self.distance(doc, toSegment: a, b) < tol }
            if near {
                addTextOnPath(path.id)
                return
            }
        }
        let text = TextLayer(string: "", fontName: textDefaults.fontName, size: textDefaults.size, color: foreground,
                             alignment: textDefaults.alignment, origin: doc - SIMD2(0, textDefaults.size * 0.9))
        let layer = Layer(name: "Text", content: .text(text))
        edit("New Text Layer") { $0.insertLayerAboveActive(layer) }
        editingText = layer.id
    }

    /// A new text layer whose baseline follows the path (its first subpath).
    func addTextOnPath(_ pathID: UUID) {
        guard let path = state.paths.first(where: { $0.id == pathID }), let line = path.polygons().first, line.count > 1 else { return }
        var text = TextLayer(string: "", fontName: textDefaults.fontName, size: textDefaults.size, color: foreground,
                             alignment: textDefaults.alignment, origin: line[0] - SIMD2(0, textDefaults.size * 0.9))
        text.onPath = line
        let layer = Layer(name: "Text", content: .text(text))
        edit("New Text Layer") { $0.insertLayerAboveActive(layer) }
        tool = .type
        editingText = layer.id
    }

    static func distance(_ p: SIMD2<Double>, toSegment a: SIMD2<Double>, _ b: SIMD2<Double>) -> Double {
        let ab = b - a
        let t = simd_length_squared(ab) > 0 ? max(0, min(1, simd_dot(p - a, ab) / simd_length_squared(ab))) : 0
        return simd_distance(p, a + ab * t)
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

    /// Live-updates the active text layer's warp (nil removes it).
    func updateTextWarp(_ warp: TextWarp?) {
        guard let layer = activeLayer, case .text = layer.content else { return }
        liveLayer("Warp Text") { layer in
            if case .text(var t) = layer.content { t.warp = warp; layer.content = .text(t) }
        }
    }
}
