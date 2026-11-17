import AppKit
import GlimmerAI
import GlimmerCore
import GlimmerRender
import GlimmerTools
import simd

extension EditorSession {
    var filterEngine: FilterEngine? {
        if let e = filterEngineCache { return e }
        guard let metal else { return nil }
        filterEngineCache = try? FilterEngine(context: metal)
        return filterEngineCache
    }

    // MARK: Filters

    var activeSmart: (layer: Layer, smart: SmartObject)? {
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
            edit(stepName("Smart Filter")) { state in
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
            edit(stepName(String.LocalizationValue(settings.kind.title), english: settings.kind.title)) { $0.updateLayer(layer.id) { $0.tiles = result } }
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
}
