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
    var filterEngine: FilterEngine? {
        if let e = filterEngineCache { return e }
        guard let metal else { return nil }
        filterEngineCache = try? FilterEngine(context: metal)
        return filterEngineCache
    }

    // MARK: Filters

    private var activeSmart: (layer: Layer, smart: SmartObject)? {
        guard let layer = activeLayer, case .smart(let smart) = layer.content else { return nil }
        return (layer, smart)
    }

    /// Opens the filter dialog (filters without settings run immediately). On a
    /// smart object the filter becomes a smart filter.
    func openFilter(_ kind: FilterKind) {
        commitLiveEdit()
        smartFilterEditIndex = nil
        let settings = lastFilter?.kind == kind ? lastFilter! : FilterSettings(kind)
        if kind.fields.isEmpty {
            applyFilter(settings)
        } else {
            filterDialog = settings
            previewFilter(settings)
        }
    }

    /// Re-opens a smart filter's settings.
    func editSmartFilter(layerID: UUID, index: Int) {
        commitLiveEdit()
        guard let layer = state.layer(id: layerID), case .smart(let smart) = layer.content, smart.filters.indices.contains(index) else { return }
        setActiveLayer(layerID)
        smartFilterEditIndex = index
        filterDialog = smart.filters[index].settings
        previewFilter(smart.filters[index].settings)
    }

    /// Live preview on the active layer (debounced, computed off the main thread).
    func previewFilter(_ settings: FilterSettings) {
        filterPreviewTask?.cancel()
        if let (layer, smart) = activeSmart {
            // Smart objects preview by temporarily changing their filter list.
            if smartFilterPreviewBase == nil { smartFilterPreviewBase = state }
            var filters = smart.filters
            if let i = smartFilterEditIndex, filters.indices.contains(i) {
                filters[i].settings = settings
            } else if let base = smartFilterPreviewBase, case .smart(let original)? = base.layer(id: layer.id)?.content {
                filters = original.filters + [SmartFilter(settings)]
            }
            document.state.updateLayer(layer.id) { l in
                if case .smart(var s) = l.content { s.filters = filters; l.content = .smart(s) }
            }
            return
        }
        guard let engine = filterEngine, let layer = activeLayer, layer.isRaster else { return }
        let tiles = layer.tiles, frame = state.bounds, selection = state.selection, id = layer.id
        isPreviewingFilter = true
        filterPreviewTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(60))
            guard !Task.isCancelled else { return }
            let result = await Task.detached(priority: .userInitiated) {
                try? engine.apply(settings, to: tiles, frame: frame, selection: selection)
            }.value
            guard !Task.isCancelled, let self, let result else { return }
            self.overrides = LayerOverrides(pixels: [id: result])
            self.isPreviewingFilter = false
        }
    }

    func cancelFilterDialog() {
        filterPreviewTask?.cancel()
        filterDialog = nil
        isPreviewingFilter = false
        overrides = .none
        if let base = smartFilterPreviewBase {
            document.state = base
            smartFilterPreviewBase = nil
        }
        smartFilterEditIndex = nil
    }

    func applyFilter(_ settings: FilterSettings) {
        filterPreviewTask?.cancel()
        filterDialog = nil
        isPreviewingFilter = false
        if let (layer, smart) = activeSmart {
            let before = smartFilterPreviewBase ?? state
            smartFilterPreviewBase = nil
            var filters: [SmartFilter]
            if case .smart(let original)? = before.layer(id: layer.id)?.content { filters = original.filters } else { filters = smart.filters }
            if let i = smartFilterEditIndex, filters.indices.contains(i) {
                filters[i].settings = settings
            } else {
                filters.append(SmartFilter(settings))
            }
            smartFilterEditIndex = nil
            document.state = before
            lastFilter = settings
            edit(String(localized: "Smart Filter")) { state in
                state.updateLayer(layer.id) { l in
                    if case .smart(var s) = l.content { s.filters = filters; l.content = .smart(s) }
                }
            }
            return
        }
        guard let engine = filterEngine, let layer = activeLayer, layer.isRaster else {
            overrides = .none
            errorMessage = "Filters work on pixel layers and smart objects. Rasterize the layer first."
            return
        }
        do {
            let result = try engine.apply(settings, to: layer.tiles, frame: state.bounds, selection: state.selection)
            lastFilter = settings
            edit(String(localized: String.LocalizationValue(settings.kind.title))) { $0.updateLayer(layer.id) { $0.tiles = result } }
        } catch {
            report(error)
        }
        overrides = .none
    }

    func setSmartFilterEnabled(layerID: UUID, index: Int, _ enabled: Bool) {
        edit(enabled ? "Show Smart Filter" : "Hide Smart Filter") { state in
            state.updateLayer(layerID) { l in
                if case .smart(var s) = l.content, s.filters.indices.contains(index) { s.filters[index].isEnabled = enabled; l.content = .smart(s) }
            }
        }
    }

    func deleteSmartFilter(layerID: UUID, index: Int) {
        edit("Delete Smart Filter") { state in
            state.updateLayer(layerID) { l in
                if case .smart(var s) = l.content, s.filters.indices.contains(index) { s.filters.remove(at: index); l.content = .smart(s) }
            }
        }
    }

    /// Preset filter steps (web ids) run on the active pixel layer, as one undo step.
    func applyFilterSteps(_ steps: [(String, [String: Double])]) -> Bool {
        guard let engine = filterEngine, let layer = activeLayer, layer.isRaster else { return false }
        var tiles = layer.tiles
        for (id, params) in steps {
            guard let f = FilterSettings(id: id, params) else { continue }
            guard let next = try? engine.apply(f, to: tiles, frame: state.bounds, selection: state.selection) else { return false }
            tiles = next
        }
        edit("Preset Filters") { $0.updateLayer(layer.id) { $0.tiles = tiles } }
        return true
    }

    // MARK: Retouch tools

    static let retouchTools: Set<ToolID> = [.cloneStamp, .healingBrush, .dodge, .burn, .blur, .sharpen, .smudge, .patternStamp]

    func setCloneSource(_ point: SIMD2<Double>) {
        cloneSource = point
        cloneOffset = nil
    }

    /// Starts a clone / heal / dodge / burn / blur / sharpen / smudge stroke.
    func beginRetouch(at point: SIMD2<Double>, pressure: Double) {
        commitLiveEdit()
        guard let metal, let engine = filterEngine, let layer = activeLayer else { return }
        guard layer.isRaster else {
            errorMessage = "Retouch tools work on pixel layers."
            return
        }
        let frame = state.bounds
        do {
            var sampler = StrokeSampler(settings: brush)
            let dabs = sampler.begin(.init(point, pressure: pressure))
            if tool == .smudge {
                let engine = try SmudgeEngine(context: metal, tiles: layer.tiles, region: frame, selection: state.selection)
                smudge = (engine, sampler, layer.id, point)
                overrides = LayerOverrides(pixels: [layer.id: engine.result])
                return
            }
            let mode: PixelOps.Mode
            var effect: TileGrid?
            var parameters = SIMD4<Float>.zero
            switch tool {
            case .cloneStamp, .healingBrush:
                guard let source = cloneSource else {
                    errorMessage = "⌥-click to set the \(tool == .cloneStamp ? "clone" : "healing") source first."
                    return
                }
                let offset: SIMD2<Double>
                if cloneAligned, let o = cloneOffset { offset = o } else { offset = source - point }
                cloneOffset = offset
                let shift = SIMD2(Int(-offset.x.rounded()), Int(-offset.y.rounded()))
                effect = tool == .cloneStamp
                    ? try engine.shifted(layer.tiles, by: shift, region: frame)
                    : try engine.healed(layer.tiles, by: shift, region: frame, sigma: Float(max(brush.size / 4, 3)))
                mode = .towardEffect
            case .blur:
                effect = try engine.apply(FilterSettings(.gaussianBlur, ["radius": 2 + 10 * retouchStrength]),
                                          to: layer.tiles, frame: frame, selection: nil)
                mode = .towardEffect
            case .sharpen:
                effect = try engine.apply(FilterSettings(.unsharpMask, ["amount": 0.5 + 2 * retouchStrength, "radius": 1.5]),
                                          to: layer.tiles, frame: frame, selection: nil)
                mode = .towardEffect
            case .patternStamp:
                let pattern = Layer(name: "Pattern", content: .fill(.pattern(PatternFill(
                    kind: patternKind, scale: patternScale, foreground: foreground, background: background))))
                effect = try DocumentCompositor.rasterize(pattern, bounds: frame, blendSpace: state.blendSpace, context: metal)
                mode = .towardEffect
            case .dodge, .burn:
                mode = tool == .dodge ? .dodge : .burn
                parameters = SIMD4(Float(dodgeExposure), Float(dodgeRange), 0, 0)
            default:
                return
            }
            let stroke = try StrokeEngine(context: metal, tiles: layer.tiles, retouch: mode, effect: effect,
                                          parameters: parameters, opacity: Float(brush.opacity), selection: state.selection)
            stroke.add(dabs)
            self.stroke = (stroke, sampler, layer.id, false)
            overrides = LayerOverrides(pixels: [layer.id: stroke.result])
        } catch {
            report(error)
        }
    }

    func continueSmudge(to point: SIMD2<Double>, pressure: Double) {
        guard var s = smudge else { return }
        let dabs = s.sampler.move(to: .init(point, pressure: pressure))
        guard !dabs.isEmpty else { smudge = s; return }
        var last = s.last
        let smudgeDabs = dabs.map { d -> SmudgeDab in
            let c = SIMD2(Double(d.center.x), Double(d.center.y))
            defer { last = c }
            return SmudgeDab(centre: d.center, delta: SIMD2(Float(c.x - last.x), Float(c.y - last.y)), radius: d.radius,
                             hardness: d.hardness, strength: Float(retouchStrength) * d.flow / max(Float(brush.flow), 0.01))
        }
        s.last = last
        smudge = s
        s.engine.add(smudgeDabs)
        overrides = LayerOverrides(pixels: [s.layer: s.engine.result])
    }

    func endSmudge() {
        guard let s = smudge else { return }
        smudge = nil
        s.engine.finish()
        let result = s.engine.result
        edit("Smudge") { $0.updateLayer(s.layer) { $0.tiles = result } }
        overrides = .none
    }

    var retouchActionName: String {
        switch tool {
        case .cloneStamp: "Clone Stamp"
        case .healingBrush: "Healing Brush"
        case .dodge: "Dodge"
        case .burn: "Burn"
        case .blur: "Blur Tool"
        case .sharpen: "Sharpen Tool"
        case .smudge: "Smudge"
        case .patternStamp: "Pattern Stamp"
        default: "Retouch"
        }
    }

    /// Where the clone source sits for a brush at `point` (for the canvas marker).
    func cloneMarker(for point: SIMD2<Double>?) -> SIMD2<Double>? {
        guard tool == .cloneStamp || tool == .healingBrush else { return nil }
        if let point, let offset = cloneOffset, cloneAligned || stroke != nil { return point + offset }
        return cloneSource
    }

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

    private func liquifyDab(at p: SIMD2<Double>, delta: SIMD2<Double>) {
        guard let l = liquify else { return }
        l.engine.dab(liquifyMode, at: p, delta: delta, radius: liquifySize / 2, strength: liquifyPressure)
    }

    func liquifyMouseUp() {
        liquify?.last = nil
        publishLiquify()
    }

    private func publishLiquify() {
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

    func cancelLiquify() {
        liquify = nil
        overrides = .none
    }

    // MARK: Channels

    /// Loads a channel (0 = RGB luminosity, 1-3 = R, G, B) of the composite as a selection.
    func loadChannelAsSelection(_ channel: Int) {
        commitLiveEdit()
        guard let metal else { return }
        do {
            let image = try ImageExporter.flattenedSRGB(state, context: metal)
            let rgba = RGBAImage(image)
            var mask = [Float](repeating: 0, count: rgba.width * rgba.height)
            for i in 0..<mask.count {
                let r = rgba.pixels[i * 4], g = rgba.pixels[i * 4 + 1], b = rgba.pixels[i * 4 + 2], a = rgba.pixels[i * 4 + 3]
                let v: Float = switch channel {
                case 1: r
                case 2: g
                case 3: b
                default: 0.299 * r + 0.587 * g + 0.114 * b
                }
                mask[i] = v * a
            }
            let selection = Selection.from(mask: mask, rect: PixelRect(x: 0, y: 0, width: rgba.width, height: rgba.height))
            edit("Load Channel") { $0.selection = selection }
        } catch {
            report(error)
        }
    }
}
