import AppKit
import GlimmerCore
import GlimmerRender
import GlimmerTools
import SwiftUI
import simd

/// The open text editor, as the options bar sees it.
@MainActor protocol TextStyler: AnyObject {
    /// Restyles the selected letters, or (selectionOnly false) the whole text in the editor.
    /// nil leaves a property as it is.
    func style(selectionOnly: Bool, fontName: String?, size: Double?, color: SRGBColor?)
}

extension EditorSession {
    // MARK: Text

    /// The topmost visible text layer under a document point.
    func textLayer(at doc: SIMD2<Double>) -> Layer? {
        state.allLayers.reversed().first { layer in
            guard layer.isVisible, case .text(let t) = layer.content else { return false }
            let b = t.bounds
            return doc.x >= Double(b.x) && doc.x <= Double(b.maxX) && doc.y >= Double(b.y) && doc.y <= Double(b.maxY)
        }
    }

    /// Type tool click: edit the text layer under the pointer, or start a new one.
    func typeClick(at doc: SIMD2<Double>) {
        commitLiveEdit()
        if let hit = textLayer(at: doc) {
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
        let layer = Layer(name: layerName("Text"), content: .text(text))
        edit("New Text Layer") { $0.insertLayerAboveActive(layer) }
        editingText = layer.id
    }

    /// A new text layer whose baseline follows the path (its first subpath).
    func addTextOnPath(_ pathID: UUID) {
        guard let path = state.paths.first(where: { $0.id == pathID }), let line = path.polygons().first, line.count > 1 else { return }
        var text = TextLayer(string: "", fontName: textDefaults.fontName, size: textDefaults.size, color: foreground,
                             alignment: textDefaults.alignment, origin: line[0] - SIMD2(0, textDefaults.size * 0.9))
        text.onPath = line
        text.onPathID = pathID
        let layer = Layer(name: layerName("Text"), content: .text(text))
        edit("New Text Layer") { $0.insertLayerAboveActive(layer) }
        tool = .type
        editingText = layer.id
    }

    static func distance(_ p: SIMD2<Double>, toSegment a: SIMD2<Double>, _ b: SIMD2<Double>) -> Double {
        let ab = b - a
        let t = simd_length_squared(ab) > 0 ? max(0, min(1, simd_dot(p - a, ab) / simd_length_squared(ab))) : 0
        return simd_distance(p, a + ab * t)
    }

    /// Stores what the text editor holds when it closes: the text and the style of each stretch.
    func commitText(_ string: String, runs: [(range: NSRange, style: TextStyle)], id: UUID) {
        guard let layer = state.layer(id: id), case .text(var text) = layer.content else { return }
        if string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            edit("Delete Empty Text") { _ = $0.removeLayer(id) }
            return
        }
        let before = text
        text.setStyledText(string, runs: runs)
        guard text != before else { return }
        let name = String(string.split(separator: "\n").first ?? "Text").prefix(32)
        let action = text.string == before.string ? "Style Text" : "Edit Text"
        edit(action) { $0.updateLayer(id) { $0.content = .text(text); $0.name = String(name) } }
    }

    /// Live change to the active text layer's style (options bar). While text is being edited
    /// with letters selected, font, size and colour change only those letters; otherwise the
    /// whole layer (and the per-word values of that property give way).
    func updateText(_ change: @escaping (inout TextLayer) -> Void) {
        if let layer = activeLayer, case .text(let t) = layer.content, let styler = textStyler {
            if textSelectionIsRange, let selected = textSelectionStyle {
                var probe = t
                probe.fontName = selected.fontName
                probe.size = selected.size
                probe.color = selected.color
                change(&probe)
                styler.style(selectionOnly: true,
                             fontName: probe.fontName != selected.fontName ? probe.fontName : nil,
                             size: probe.size != selected.size ? probe.size : nil,
                             color: probe.color != selected.color ? probe.color : nil)
                // Alignment, tracking and line height belong to the whole layer.
                var rest = t
                change(&rest)
                rest.fontName = t.fontName
                rest.size = t.size
                rest.color = t.color
                if rest != t { liveLayer("Text Style") { $0.content = .text(rest) } }
                return
            }
            var changed = t
            change(&changed)
            styler.style(selectionOnly: false,
                         fontName: changed.fontName != t.fontName ? changed.fontName : nil,
                         size: changed.size != t.size ? changed.size : nil,
                         color: changed.color != t.color ? changed.color : nil)
        }
        if let layer = activeLayer, case .text = layer.content {
            liveLayer("Text Style") { layer in
                if case .text(var t) = layer.content {
                    let old = t
                    change(&t)
                    t.dropStyles(changedFrom: old)
                    layer.content = .text(t)
                }
            }
        }
        var d = TextLayer(string: "", fontName: textDefaults.fontName, size: textDefaults.size, color: .black,
                          alignment: textDefaults.alignment, origin: .zero)
        change(&d)
        textDefaults = (d.fontName, d.size, d.alignment)
    }

    /// Puts the active text layer on a path (its first subpath), or back on a straight line.
    func setTextPath(_ pathID: UUID?) {
        guard let layer = activeLayer, case .text(var t) = layer.content else { return }
        if let pathID {
            guard let line = state.paths.first(where: { $0.id == pathID })?.polygons().first, line.count > 1 else { return }
            t.onPath = line
            t.onPathID = pathID
        } else {
            // Stay where the text was: its box starts at the beginning of the old baseline.
            if let first = t.onPath?.first { t.origin = first - SIMD2(0, t.size * 0.9) }
            t.onPath = nil
            t.onPathID = nil
        }
        let id = layer.id
        edit(pathID == nil ? "Remove Text from Path" : "Text on Path") { $0.updateLayer(id) { $0.content = .text(t) } }
    }

    /// Live-updates the active text layer's warp (nil removes it).
    func updateTextWarp(_ warp: TextWarp?) {
        guard let layer = activeLayer, case .text = layer.content else { return }
        liveLayer("Warp Text") { layer in
            if case .text(var t) = layer.content { t.warp = warp; layer.content = .text(t) }
        }
    }
}
