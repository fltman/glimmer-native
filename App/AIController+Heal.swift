#if GLIMMER_HEAL
import AppKit
import GlimmerAI
import GlimmerCore
import GlimmerHeal
import GlimmerRender

/// Heal Selection: fills the selected area from what surrounds it, on this Mac, with no
/// model (Packages/GlimmerKit/Sources/GlimmerHeal; the rules it keeps to are in docs/PATENTS.md).
extension AIController {
    struct HealRequest {
        var method = Heal.Method.auto
        /// Pixels the selection is grown by first, so an object's edge and halo go with it.
        var expand = 3
        /// True: read what is visible, put the fill in a new layer. False: the active pixel layer, in place.
        var sampleAllLayers = true
        var allowLarge = false
    }

    /// Everything the fill needs, read on the main actor.
    struct HealJob: Sendable {
        var request: HealRequestValues
        var window: PixelRect
        var holeBounds: PixelRect
        var pixels: [Float]
        var hole: [Bool]
        var weight: [Float]
        var thickness: Double
        var solidPixels: Int
        var layerID: UUID?
    }

    struct HealRequestValues: Sendable {
        var method: Heal.Method
        var sampleAllLayers: Bool
    }

    struct HealResult: Sendable {
        var method: Heal.Method
        /// Premultiplied RGBA over `holeBounds`.
        var pixels: [Float16]
        var filled: Int
    }

    private func healRefusal(_ r: Heal.Refusal) -> StepError {
        var e = StepError(r.message, reason: r.reason)
        e.hard = r.hard
        return e
    }

    /// Reads the selection and the pixels around it. Throws a `StepError` with a reason when there is nothing to do.
    func prepareHeal(_ request: HealRequest) throws -> HealJob {
        let state = session.state
        let canvas = state.bounds
        guard let selection = state.selection, let selected = selection.bounds(in: canvas) else {
            throw StepError("There's no selection to heal. Select the area to fill first.", reason: "no_selection")
        }
        let expand = min(50, max(0, request.expand))
        let around = PixelRect(x: selected.x - expand - 1, y: selected.y - expand - 1,
                               width: selected.width + 2 * expand + 2, height: selected.height + 2 * expand + 2).intersection(canvas)
        guard let area = Heal.area(coverage: selection.values(in: around), width: around.width, height: around.height, expand: expand) else {
            throw StepError("The selection is too faint to heal: nothing is selected at least half.", reason: "no_selection")
        }
        if let refusal = Heal.refusal(pixels: area.pixels, thickness: area.thickness, allowLarge: request.allowLarge) {
            throw healRefusal(refusal)
        }
        let holeBounds = PixelRect(x: around.x + area.bounds.x, y: around.y + area.bounds.y, width: area.bounds.width, height: area.bounds.height)
        let pad = Heal.padding(thickness: area.thickness)
        let window = PixelRect(x: holeBounds.x - pad, y: holeBounds.y - pad, width: holeBounds.width + 2 * pad,
                               height: holeBounds.height + 2 * pad).intersection(canvas)

        var hole = [Bool](repeating: false, count: window.width * window.height)
        var weight = [Float](repeating: 0, count: hole.count)
        for y in 0..<around.height {
            for x in 0..<around.width where area.hole[y * around.width + x] {
                let i = (around.y + y - window.y) * window.width + (around.x + x - window.x)
                hole[i] = true
                weight[i] = area.weight[y * around.width + x]
            }
        }

        var pixels = [Float](repeating: 0, count: hole.count * 4)
        var layerID: UUID?
        if request.sampleAllLayers {
            let (buffer, bytesPerRow, rect) = try DocumentCompositor(context: try metal).renderPixels(state, region: window)
            precondition(rect == window)
            let source = buffer.contents()
            for y in 0..<window.height {
                let row = (source + y * bytesPerRow).assumingMemoryBound(to: Float16.self)
                for i in 0..<window.width * 4 { pixels[y * window.width * 4 + i] = Float(row[i]) }
            }
        } else {
            guard let layer = state.activeLayer, layer.isRaster else {
                throw StepError("With sampleAllLayers false, heal_selection works on a pixel layer. Select one, or leave sampleAllLayers on.",
                                reason: "not_pixel_layer")
            }
            layerID = layer.id
            let s = TileGeometry.size
            for coord in window.tileCoords {
                guard let tile = layer.tiles[coord] else { continue }
                let p = tile.pixels()
                let part = coord.rect.intersection(window)
                for y in part.y..<part.maxY {
                    for x in part.x..<part.maxX {
                        let from = ((y - coord.rect.y) * s + (x - coord.rect.x)) * 4, to = ((y - window.y) * window.width + (x - window.x)) * 4
                        for c in 0..<4 { pixels[to + c] = Float(p[from + c]) }
                    }
                }
            }
        }
        return HealJob(request: HealRequestValues(method: request.method, sampleAllLayers: request.sampleAllLayers),
                       window: window, holeBounds: holeBounds, pixels: pixels, hole: hole, weight: weight,
                       thickness: area.thickness, solidPixels: area.pixels, layerID: layerID)
    }

    /// The fill itself; runs anywhere.
    nonisolated static func heal(_ job: HealJob, isCancelled: @escaping @Sendable () -> Bool) throws -> HealResult {
        let filled = try Heal.fill(pixels: job.pixels, width: job.window.width, height: job.window.height, hole: job.hole,
                                   thickness: job.thickness, method: job.request.method, isCancelled: isCancelled)
        let b = job.holeBounds, w = job.window
        var out = [Float16](repeating: 0, count: b.width * b.height * 4)
        var count = 0
        for y in 0..<b.height {
            for x in 0..<b.width {
                let i = (b.y + y - w.y) * w.width + (b.x + x - w.x), o = (y * b.width + x) * 4
                if job.hole[i] {
                    count += 1
                    let k = job.weight[i]
                    for c in 0..<4 {
                        // A new layer carries the fill at the strength of the selection there; in
                        // place, the same blend is done against the layer's own pixel.
                        let v = job.request.sampleAllLayers ? filled.pixels[i * 4 + c] * k
                            : job.pixels[i * 4 + c] + (filled.pixels[i * 4 + c] - job.pixels[i * 4 + c]) * k
                        out[o + c] = Float16(v)
                    }
                } else if !job.request.sampleAllLayers {
                    for c in 0..<4 { out[o + c] = Float16(job.pixels[i * 4 + c]) }
                }
            }
        }
        return HealResult(method: filled.method, pixels: out, filled: count)
    }

    /// Puts the fill into the document as one undo step; returns what the step reports.
    @discardableResult
    func applyHeal(_ job: HealJob, _ result: HealResult) throws -> [String: Any] {
        let b = job.holeBounds, s = TileGeometry.size
        var existing = TileGrid()
        if let id = job.layerID {
            guard let layer = session.state.layer(id: id), layer.isRaster else {
                throw StepError("The layer being healed is gone.", reason: "unknown_layer")
            }
            existing = layer.tiles
        }
        var grid = existing
        var buffer = [Float16](repeating: 0, count: s * s * 4)
        for coord in b.tileCoords {
            if let tile = existing[coord] { buffer = tile.pixels() } else { for i in buffer.indices { buffer[i] = 0 } }
            let part = coord.rect.intersection(b)
            for y in part.y..<part.maxY {
                for x in part.x..<part.maxX {
                    let from = ((y - b.y) * b.width + (x - b.x)) * 4, to = ((y - coord.rect.y) * s + (x - coord.rect.x)) * 4
                    for c in 0..<4 { buffer[to + c] = result.pixels[from + c] }
                }
            }
            grid[coord] = buffer.withUnsafeBytes { Tile.make(pixels: $0.baseAddress!, bytesPerRow: TileGeometry.bytesPerRow) }
        }
        let layerID: UUID
        if let id = job.layerID {
            layerID = id
            session.edit(stepName("Heal Selection")) { $0.updateLayer(id) { $0.tiles = grid } }
        } else {
            let layer = Layer(name: String(localized: "Heal"), content: .raster(grid))
            layerID = layer.id
            session.edit(stepName("Heal Selection")) { $0.insertLayerAboveActive(layer) }
        }
        var info: [String: Any] = ["method": result.method.rawValue, "pixels": result.filled,
                                   "width": Int(job.thickness.rounded()), "layer": layerID.uuidString]
        if job.thickness > Heal.comfortableWidth { info["quality"] = "may_repeat" }
        return info
    }

    /// The agent's `heal_selection` step.
    func performHealSelection(_ step: AgentStep) async throws {
        var request = HealRequest()
        if let name = step.string("method") {
            guard let method = Heal.Method(rawValue: name) else {
                throw StepError("method must be one of: \(Heal.Method.allCases.map(\.rawValue).joined(separator: ", ")).", reason: "bad_method")
            }
            request.method = method
        }
        if let expand = step.number("expand") {
            guard expand.isFinite, (0...50).contains(expand) else { throw StepError("expand must be 0…50 pixels.", reason: "bad_expand") }
            request.expand = Int(expand.rounded())
        }
        request.sampleAllLayers = step.params["sampleAllLayers"]?.bool ?? true
        request.allowLarge = step.params["allowLarge"]?.bool ?? false
        let job = try prepareHeal(request)
        let result: HealResult
        do {
            result = try await Task.detached(priority: .userInitiated) { try Self.heal(job) { false } }.value
        } catch let refusal as Heal.Refusal {
            throw healRefusal(refusal)
        }
        stepInfo = try applyHeal(job, result)
    }

    /// Edit › Heal Selection. A large area asks first (`session.healWarning`).
    func healSelection(allowLarge: Bool = false) {
        do {
            let job = try prepareHeal(HealRequest(allowLarge: allowLarge))
            run(String(localized: "Heal Selection"), {
                do {
                    return (try Self.heal(job) { Task.isCancelled }, nil)
                } catch let refusal as Heal.Refusal {
                    throw StepError(refusal.message, reason: refusal.reason)
                }
            }, apply: { [weak self] (result: HealResult) in
                try self?.applyHeal(job, result)
            })
        } catch let error as StepError where error.reason == "area_too_large" && !error.hard && !allowLarge {
            session.healWarning = error.errorDescription.map(PersonMessage.text)   // in the person's language (the API keeps the English)
        } catch {
            session.report(error)
        }
    }
}
#endif
