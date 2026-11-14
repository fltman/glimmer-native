import AppKit
import GlimmerAI
import GlimmerCore
import GlimmerRender
import GlimmerTools
import SwiftUI
import UniformTypeIdentifiers
import simd

/// Painting, selection tools and pixel commands.
extension EditorSession {
    // MARK: Colors

    func swapColors() {
        swap(&foreground, &background)
    }

    func resetColors() {
        foreground = SRGBColor(0, 0, 0)
        background = SRGBColor(1, 1, 1)
    }

    private func luminance(_ c: SRGBColor) -> Float {
        let l = c.linear
        return 0.2126 * l.x + 0.7152 * l.y + 0.0722 * l.z
    }

    // MARK: Brush and eraser

    /// True when the brush would paint the active layer's mask.
    var paintsMask: Bool { editingMask && activeLayer?.mask != nil }

    func beginStroke(at point: SIMD2<Double>, pressure: Double, tilt: SIMD2<Double> = .zero, rotation: Double = 0,
                     erase: Bool, straightLine: Bool) {
        commitLiveEdit()
        if Self.retouchTools.contains(tool) {
            beginRetouch(at: point, pressure: pressure)
            return
        }
        guard let metal, let layer = activeLayer else { return }
        let maskTarget = paintsMask
        guard maskTarget || layer.isRaster else {
            errorMessage = layer.isGroup || layer.isAdjustment
                ? "Select a pixel layer, or click a layer mask to paint it."
                : "This layer can't be painted directly. Rasterize it first (Layer › Rasterize Layer)."
            return
        }
        do {
            let tiles = maskTarget ? (layer.mask?.tiles ?? TileGrid()) : layer.tiles
            let target: StrokeEngine.Target = maskTarget ? .mask(defaultValue: layer.mask?.defaultValue ?? 1) : .pixels
            let value = luminance(erase ? background : foreground)
            let engine = try StrokeEngine(context: metal, tiles: tiles, target: target, erase: erase,
                                          color: SIMD4(foreground.linear, 1), opacity: Float(brush.opacity),
                                          maskTarget: value, selection: state.selection)
            var sampler = StrokeSampler(settings: brush)
            var dabs = sampler.begin(.init(point, pressure: pressure, tilt: tilt, rotation: rotation))
            if straightLine, let from = lastStrokePoint {
                // Shift-click continues with a straight line from the last stroke.
                _ = sampler.begin(.init(from, pressure: pressure))
                dabs = sampler.move(to: .init(point, pressure: pressure, tilt: tilt, rotation: rotation))
            }
            engine.add(dabs)
            stroke = (engine, sampler, layer.id, maskTarget)
            publishStroke()
        } catch {
            report(error)
        }
    }

    func continueStroke(to point: SIMD2<Double>, pressure: Double, tilt: SIMD2<Double> = .zero, rotation: Double = 0) {
        if smudge != nil {
            continueSmudge(to: point, pressure: pressure)
            return
        }
        guard var s = stroke else { return }
        let dabs = s.sampler.move(to: .init(point, pressure: pressure, tilt: tilt, rotation: rotation))
        stroke = s
        if !dabs.isEmpty {
            s.engine.add(dabs)
            publishStroke()
        }
        lastStrokePoint = point
    }

    private func publishStroke() {
        guard let s = stroke else { return }
        if s.mask {
            overrides = LayerOverrides(masks: [s.layer: s.engine.result])
        } else {
            overrides = LayerOverrides(pixels: [s.layer: s.engine.result])
        }
    }

    func endStroke(at point: SIMD2<Double>?) {
        if smudge != nil {
            endSmudge()
            return
        }
        guard let s = stroke else { return }
        stroke = nil
        s.engine.finish()
        let result = s.engine.result
        let erase = tool == .eraser
        let name = Self.retouchTools.contains(tool) ? retouchActionName : (s.mask ? "Paint Mask" : (erase ? "Eraser" : "Brush Stroke"))
        edit(name) { state in
            state.updateLayer(s.layer) { layer in
                if s.mask { layer.mask?.tiles = result } else { layer.tiles = result }
            }
        }
        overrides = .none
        if let point { lastStrokePoint = point }
    }

    func adjustBrushSize(by factor: Double) {
        brush.size = min(max((brush.size * factor).rounded(), 1), 2000)
    }

    // MARK: Lasso

    func beginLasso(at point: SIMD2<Double>, modifiers: NSEvent.ModifierFlags) {
        commitLiveEdit()
        lassoOperation = Self.operation(for: modifiers)
        lasso = [point]
    }

    func extendLasso(to point: SIMD2<Double>) {
        guard var points = lasso, let last = points.last else { return }
        if simd_distance(last, point) > 1 / max(canvas.transform.scale, 0.01) {
            points.append(point)
            lasso = points
        }
    }

    /// Polygon lasso: adds a vertex, or closes when clicking near the start.
    func polygonClick(at point: SIMD2<Double>, modifiers: NSEvent.ModifierFlags, doubleClick: Bool) {
        guard var points = lasso else {
            beginLasso(at: point, modifiers: modifiers)
            return
        }
        let closeDistance = 8 / max(canvas.transform.scale, 0.01)
        if doubleClick || (points.count > 2 && simd_distance(points[0], point) < closeDistance) {
            finishLasso()
            return
        }
        points.append(point)
        lasso = points
    }

    func finishLasso() {
        guard let points = lasso else { return }
        lasso = nil
        guard points.count > 2 else {
            if lassoOperation == .replace, state.selection != nil { edit("Deselect") { $0.selection = nil } }
            return
        }
        let shape = Selection.polygon(points)
        applySelection(shape, operation: lassoOperation, name: "Lasso")
    }

    func cancelLasso() {
        lasso = nil
    }

    static func operation(for modifiers: NSEvent.ModifierFlags) -> Selection.Operation {
        switch (modifiers.contains(.shift), modifiers.contains(.option)) {
        case (true, true): .intersect
        case (true, false): .add
        case (false, true): .subtract
        default: .replace
        }
    }

    func applySelection(_ shape: Selection, operation: Selection.Operation, name: String) {
        var shape = shape
        if selectionFeather > 0, let metal,
           let soft = try? SelectionOps.apply(.feather(selectionFeather), to: shape, limit: state.bounds, context: metal) {
            shape = soft
        }
        edit(name) { state in
            if let current = state.selection, operation != .replace {
                state.selection = current.combined(with: shape, operation)
            } else {
                state.selection = operation == .subtract ? nil : shape
            }
        }
    }

    // MARK: Magic wand and paint bucket

    /// Straight sRGB pixels the wand/bucket sample (document or active layer).
    private func samplePixels() throws -> RGBAImage {
        guard let metal else { throw RenderError.noMetalDevice }
        if sampleAllLayers || activeLayer == nil {
            return RGBAImage(try ImageExporter.flattenedSRGB(state, context: metal))
        }
        return RGBAImage(try ImageExporter.layerImageSRGB(activeLayer!, in: state, context: metal))
    }

    private func regionMask(at point: SIMD2<Double>) throws -> Selection? {
        let seed = SIMD2(Int(point.x.rounded(.down)), Int(point.y.rounded(.down)))
        guard seed.x >= 0, seed.y >= 0, seed.x < state.width, seed.y < state.height else { return nil }
        let image = try samplePixels()
        let mask = FloodFill.mask(pixels: image.pixels, width: image.width, height: image.height, seed: seed,
                                  tolerance: Float(wandTolerance), contiguous: wandContiguous)
        return Selection.from(mask: mask, rect: state.bounds)
    }

    func magicWand(at point: SIMD2<Double>, modifiers: NSEvent.ModifierFlags) {
        commitLiveEdit()
        do {
            guard let region = try regionMask(at: point) else { return }
            applySelection(region, operation: Self.operation(for: modifiers), name: "Magic Wand")
        } catch {
            report(error)
        }
    }

    func paintBucket(at point: SIMD2<Double>) {
        commitLiveEdit()
        guard let metal, let layer = activeLayer, layer.isRaster else {
            errorMessage = "Select a pixel layer to fill."
            return
        }
        do {
            guard var region = try regionMask(at: point) else { return }
            if let selection = state.selection { region = region.combined(with: selection, .intersect) }
            guard let bounds = region.bounds(in: state.bounds) else { return }
            let ops = try PixelOps(context: metal)
            let coords = bounds.tileCoords
            let filled = try ops.run(.paint, on: layer.tiles, selection: nil, coords: coords,
                                     coverage: ops.coverage(from: region, coords: coords), fullCoverage: false,
                                     color: SIMD4(foreground.linear, 1), opacity: Float(brush.opacity))
            let id = layer.id
            edit("Paint Bucket") { $0.updateLayer(id) { $0.tiles = filled } }
        } catch {
            report(error)
        }
    }

    /// Fills the selection (or the whole layer) with a colour, no tolerance involved.
    func fill(with color: SRGBColor, name: String) {
        commitLiveEdit()
        guard let metal, let layer = activeLayer, layer.isRaster else {
            errorMessage = "Select a pixel layer to fill."
            return
        }
        do {
            let area = state.selection.flatMap { $0.bounds(in: state.bounds) } ?? state.bounds
            let filled = try PixelOps(context: metal).run(.paint, on: layer.tiles, selection: state.selection,
                                                          coords: area.tileCoords, color: SIMD4(color.linear, 1),
                                                          opacity: Float(brush.opacity))
            let id = layer.id
            edit(name) { $0.updateLayer(id) { $0.tiles = filled } }
        } catch {
            report(error)
        }
    }

    /// Paints the current pattern into the selection (or the whole layer).
    func fillWithPattern() {
        commitLiveEdit()
        guard let metal, let layer = activeLayer, layer.isRaster else {
            errorMessage = "Select a pixel layer to fill."
            return
        }
        do {
            let pattern = Layer(name: "Pattern", mask: state.selection?.asMask,
                                content: .fill(.pattern(PatternFill(kind: patternKind, scale: patternScale,
                                                                    foreground: foreground, background: background))))
            let pixels = Layer(name: "Pixels", content: .raster(layer.tiles))
            let both = Layer(name: "Fill", content: .group(LayerGroup(children: [pixels, pattern])))
            // Keep pixels hanging outside the canvas: rasterize over their extent too.
            var area = state.bounds
            if let t = layer.tiles.tileBounds {
                let x0 = min(area.x, t.x), y0 = min(area.y, t.y)
                area = PixelRect(x: x0, y: y0, width: max(area.maxX, t.maxX) - x0, height: max(area.maxY, t.maxY) - y0)
            }
            let filled = try DocumentCompositor.rasterize(both, bounds: area, blendSpace: state.blendSpace, context: metal)
            let id = layer.id
            edit("Pattern Fill") { $0.updateLayer(id) { $0.tiles = filled } }
        } catch {
            report(error)
        }
    }

    // MARK: Gradient tool

    /// Creates a gradient fill layer from the drag (foreground → background or
    /// transparent), masked by the selection. Non-destructive and editable later.
    func finishGradient() {
        guard let drag = gradientDrag else { return }
        gradientDrag = nil
        guard simd_distance(drag.start, drag.end) > 2 else { return }
        let fill = GradientFill(stops: currentGradientStops, style: gradientStyle, start: drag.start, end: drag.end,
                                reverse: gradientReverse)
        let mask = state.selection?.asMask
        edit("Gradient") {
            $0.insertLayerAboveActive(Layer(name: "Gradient", mask: mask, content: .fill(.gradient(fill))))
        }
    }

    /// The stops the Gradient tool draws with.
    var currentGradientStops: [GradientStop] {
        if let custom = gradientStops, custom.count >= 2 { return custom }
        return gradientToTransparent
            ? [GradientStop(0, foreground), GradientStop(1, foreground, opacity: 0)]
            : [GradientStop(0, foreground), GradientStop(1, background)]
    }

    // MARK: Eyedropper

    func sampleColor(at point: SIMD2<Double>, intoBackground: Bool) {
        guard let metal else { return }
        let p = PixelRect(x: Int(point.x.rounded(.down)), y: Int(point.y.rounded(.down)), width: 1, height: 1)
        guard p.intersection(state.bounds).width > 0 else { return }
        do {
            let compositor = try DocumentCompositor(context: metal)
            let (buffer, _, _) = try compositor.renderPixels(state, region: p)
            let px = SIMD4<Float>(buffer.contents().load(as: SIMD4<Float16>.self))
            guard px.w > 0 else { return }
            func encode(_ c: Float) -> Double {
                let c = Double(min(max(c / px.w, 0), 1))
                return c <= 0.0031308 ? c * 12.92 : 1.055 * pow(c, 1 / 2.4) - 0.055
            }
            let color = SRGBColor(encode(px.x), encode(px.y), encode(px.z))
            if intoBackground { background = color } else { foreground = color }
        } catch {
            report(error)
        }
    }

    // MARK: Selection modify

    func modifySelection(_ id: CommandID, radius: Double) {
        guard let metal, let selection = state.selection, radius > 0 else { return }
        let op: SelectionOps.Operation = switch id {
        case .featherSelection: .feather(radius)
        case .growSelection: .grow(radius)
        default: .shrink(radius)
        }
        do {
            let result = try SelectionOps.apply(op, to: selection, limit: state.bounds, context: metal)
            let name = id == .featherSelection ? "Feather" : (id == .growSelection ? "Expand Selection" : "Contract Selection")
            edit(name) { $0.selection = result }
        } catch {
            report(error)
        }
    }

    // MARK: Copy, cut, paste, clear

    /// The active layer's pixels inside the selection.
    private func selectedPixels() throws -> TileGrid? {
        guard let metal, let layer = activeLayer, layer.isRaster else { return nil }
        // No selection: the whole layer.
        guard let selection = state.selection else { return layer.tiles }
        guard let bounds = selection.bounds(in: state.bounds) else { return nil }
        let ops = try PixelOps(context: metal)
        let coords = bounds.tileCoords.filter { layer.tiles[$0] != nil }
        var kept = TileGrid()
        let result = try ops.run(.keepSelected, on: layer.tiles, selection: selection, coords: coords)
        for c in coords { kept[c] = result[c] }
        return kept
    }

    func copySelection(cut: Bool) {
        do {
            guard let grid = try selectedPixels(), let metal,
                  let bounds = state.selection.map({ $0.bounds(in: state.bounds) }) ?? grid.tileBounds?.intersection(state.bounds),
                  !bounds.isEmpty else { return }
            // System pasteboard: a PNG of the copied area.
            let single = DocumentState(width: state.width, height: state.height, layers: [Layer(name: "copy", content: .raster(grid))])
            let pb = NSPasteboard.general
            pb.clearContents()
            if let image = try ImageExporter.flattenedSRGB(single, context: metal)
                .cropping(to: CGRect(x: bounds.x, y: bounds.y, width: bounds.width, height: bounds.height)) {
                let data = RGBAImage(image).pngData()
                pb.setData(data, forType: .png)
            }
            clipboard = (grid, pb.changeCount)
            if cut {
                if state.selection != nil {
                    clearSelectedPixels(actionName: "Cut")
                } else if let id = activeLayer?.id {
                    edit("Cut") { $0.updateLayer(id) { $0.tiles = TileGrid() } }
                }
            }
        } catch {
            report(error)
        }
    }

    func clearSelectedPixels(actionName: String = "Clear") {
        guard let metal, let layer = activeLayer, layer.isRaster, let selection = state.selection,
              let bounds = selection.bounds(in: state.bounds) else { return }
        do {
            let coords = bounds.tileCoords.filter { layer.tiles[$0] != nil }
            let cleared = try PixelOps(context: metal).run(.erase, on: layer.tiles, selection: selection, coords: coords)
            let id = layer.id
            edit(actionName) { $0.updateLayer(id) { $0.tiles = cleared } }
        } catch {
            report(error)
        }
    }

    func layerViaCopy() {
        guard state.selection != nil else {
            perform(.duplicateLayer)
            return
        }
        do {
            guard let grid = try selectedPixels() else { return }
            edit("New Layer via Copy") { $0.insertLayerAboveActive(Layer(name: $0.nextLayerName(), content: .raster(grid))) }
        } catch {
            report(error)
        }
    }

    /// Pastes Glimmer's own clipboard in place when it's current, otherwise an image from the pasteboard.
    func paste() -> Bool {
        if let clip = clipboard, clip.changeCount == NSPasteboard.general.changeCount {
            edit("Paste") { $0.insertLayerAboveActive(Layer(name: "Pasted Layer", content: .raster(clip.grid))) }
            return true
        }
        return place(from: .general)
    }
}
