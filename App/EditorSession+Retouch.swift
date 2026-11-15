import AppKit
import GlimmerAI
import GlimmerCore
import GlimmerRender
import GlimmerTools
import simd

extension EditorSession {
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
                let pattern = Layer(name: layerName("Pattern"), content: .fill(.pattern(PatternFill(
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
}
