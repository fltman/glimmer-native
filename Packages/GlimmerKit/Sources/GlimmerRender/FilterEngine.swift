import Foundation
import GlimmerCore
import Metal
import MetalPerformanceShaders
import simd

/// Mirrors `FilterUniforms` in Filters.metal.
struct FilterUniforms {
    var kind: Int32
    var pad0: Int32 = 0
    var texOrigin: SIMD2<Float>
    var a: SIMD4<Float>
    var b: SIMD4<Float> = .zero
    var frameOrigin: SIMD2<Float>
    var frameSize: SIMD2<Float>
}

/// Mirrors `FilterMixUniforms` in Filters.metal.
struct FilterMixUniforms {
    var targetOrigin: SIMD2<Int32>
    var targetSize: SIMD2<Int32>
    var filteredOffset: SIMD2<Int32>
    var hasSelection: Int32
    var pad: Int32 = 0
}

/// Mirrors `SmudgeDab` in Filters.metal.
public struct SmudgeDab: Sendable {
    public var centre: SIMD2<Float>
    public var delta: SIMD2<Float>
    public var radius: Float
    public var hardness: Float
    public var strength: Float
    var pad: Float = 0

    public init(centre: SIMD2<Float>, delta: SIMD2<Float>, radius: Float, hardness: Float, strength: Float) {
        self.centre = centre
        self.delta = delta
        self.radius = radius
        self.hardness = hardness
        self.strength = strength
    }
}

/// Destructive filters and the precomputed results retouch brushes paint toward.
/// Everything stays in linear Float16 tiles; only the changed area is rewritten.
public final class FilterEngine: @unchecked Sendable {
    let context: MetalContext
    let pipelines: TilePipelines
    private let applyPipeline: MTLComputePipelineState
    private let mixPipeline: MTLComputePipelineState
    private let healPipeline: MTLComputePipelineState
    let smudgePipeline: MTLComputePipelineState

    public init(context: MetalContext) throws {
        self.context = context
        self.pipelines = try context.tilePipelines()
        func compute(_ name: String) throws -> MTLComputePipelineState {
            guard let f = context.library.makeFunction(name: name) else { throw RenderError.libraryUnavailable(name) }
            return try context.device.makeComputePipelineState(function: f)
        }
        applyPipeline = try compute("filter_apply")
        mixPipeline = try compute("filter_mix")
        healPipeline = try compute("heal_combine")
        smudgePipeline = try compute("smudge_dab")
    }

    private func kindIndex(_ k: FilterKind) -> Int32 {
        switch k {
        case .gaussianBlur: 0
        case .motionBlur: 1
        case .lensBlur: 2
        case .sharpen: 3
        case .unsharpMask: 4
        case .clarity: 5
        case .addNoise: 6
        case .pixelate: 7
        case .findEdges: 8
        case .emboss: 9
        case .oilPaint: 10
        case .halftone: 11
        case .vignette: 12
        case .chromaticAberration: 13
        }
    }

    private func parameters(_ f: FilterSettings) -> SIMD4<Float> {
        let v = { Float(f.value($0)) }
        return switch f.kind {
        case .gaussianBlur: SIMD4(v("radius"), 0, 0, 0)
        case .lensBlur: SIMD4(v("radius"), v("brightnessBoost"), 0, 0)
        case .motionBlur: SIMD4(v("angle"), v("distance"), 0, 0)
        case .sharpen: SIMD4(v("amount"), 0, 0, 0)
        case .unsharpMask: SIMD4(v("amount"), v("radius"), v("threshold"), 0)
        case .clarity: SIMD4(v("amount"), 0, 0, 0)
        case .addNoise: SIMD4(v("amount"), f.flag("monochrome") ? 1 : 0, 0, 0)
        case .pixelate: SIMD4(v("cell"), 0, 0, 0)
        case .findEdges: .zero
        case .emboss: SIMD4(v("angle"), v("amount"), 0, 0)
        case .oilPaint: SIMD4(v("radius"), v("intensity"), 0, 0)
        case .halftone: SIMD4(v("cellSize"), v("angle"), f.flag("monochrome") ? 1 : 0, 0)
        case .vignette: SIMD4(v("amount"), v("midpoint"), v("roundness"), v("feather"))
        case .chromaticAberration: SIMD4(v("amount"), f.flag("edgeOnly") ? 1 : 0, 0, 0)
        }
    }

    /// Clarity's base blur scales with the frame so it reads as local contrast.
    private func claritySigma(_ frame: PixelRect) -> Float {
        Float(min(40, max(4, (Double(min(frame.width, frame.height)) * 0.02).rounded()))) * 1.4
    }

    private func reach(_ f: FilterSettings, frame: PixelRect) -> Int {
        f.kind == .clarity ? Int(claritySigma(frame) * 3) + 1 : f.reach
    }

    private func isIdentity(_ f: FilterSettings) -> Bool {
        switch f.kind {
        case .gaussianBlur, .lensBlur: f.value("radius") < 0.25
        case .motionBlur: f.value("distance") < 0.5
        case .sharpen, .unsharpMask, .clarity, .addNoise, .vignette: f.value("amount") == 0
        case .chromaticAberration: f.value("amount") < 0.05
        default: false
        }
    }

    /// Filters a raster layer's tiles inside `frame` (the document), limited to `selection`.
    public func apply(_ f: FilterSettings, to grid: TileGrid, frame: PixelRect, selection: Selection?) throws -> TileGrid {
        guard !isIdentity(f), let content = grid.tileBounds else { return grid }
        let area = content.intersection(frame)
        guard !area.isEmpty else { return grid }
        var target = area
        if let selection {
            guard let b = selection.bounds(in: area) else { return grid }
            target = b
        }
        let srcRect = RegionOps.expand(target, by: reach(f, frame: frame)).intersection(area)
        let aligned = RegionOps.tileAligned(target)

        guard let cb = context.commandQueue.makeCommandBuffer() else { throw RenderError.resourceCreationFailed("filter") }
        cb.label = "Filter \(f.kind.rawValue)"
        let src = try RegionOps.assemble(grid, region: srcRect, pipelines: pipelines, commandBuffer: cb)
        let filtered = try RegionOps.makeTexture(context.device, width: srcRect.width, height: srcRect.height)

        switch f.kind {
        case .gaussianBlur:
            let blur = MPSImageGaussianBlur(device: context.device, sigma: Float(f.value("radius")) / 2)
            blur.edgeMode = .clamp
            blur.encode(commandBuffer: cb, sourceTexture: src, destinationTexture: filtered)
        default:
            var aux = src
            if f.kind == .unsharpMask || f.kind == .clarity {
                aux = try RegionOps.makeTexture(context.device, width: srcRect.width, height: srcRect.height)
                let sigma = f.kind == .clarity ? claritySigma(frame) : Float(f.value("radius"))
                let blur = MPSImageGaussianBlur(device: context.device, sigma: max(sigma, 0.3))
                blur.edgeMode = .clamp
                blur.encode(commandBuffer: cb, sourceTexture: src, destinationTexture: aux)
            }
            guard let e = cb.makeComputeCommandEncoder() else { throw RenderError.resourceCreationFailed("filter encoder") }
            var u = FilterUniforms(kind: kindIndex(f.kind), texOrigin: SIMD2(Float(srcRect.x), Float(srcRect.y)),
                                   a: parameters(f), frameOrigin: SIMD2(Float(frame.x), Float(frame.y)),
                                   frameSize: SIMD2(Float(max(frame.width, 1)), Float(max(frame.height, 1))))
            e.setComputePipelineState(applyPipeline)
            e.setTexture(src, index: 0)
            e.setTexture(aux, index: 1)
            e.setTexture(filtered, index: 2)
            e.setBytes(&u, length: MemoryLayout<FilterUniforms>.stride, index: 0)
            dispatch(e, width: srcRect.width, height: srcRect.height)
            e.endEncoding()
        }

        let out = try mix(original: grid, filtered: filtered, filteredRect: srcRect, target: target, aligned: aligned,
                          selection: selection, cb: cb)
        cb.commit()
        cb.waitUntilCompleted()
        if let error = cb.error { throw error }
        var result = grid
        for (c, t) in out.tiles { result[c] = t }
        return result
    }

    private func dispatch(_ e: MTLComputeCommandEncoder, width: Int, height: Int) {
        e.dispatchThreads(MTLSize(width: width, height: height, depth: 1),
                          threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
    }

    /// Blends `filtered` (covering `filteredRect`) into the original inside `target`, by the selection.
    private func mix(original grid: TileGrid, filtered: MTLTexture, filteredRect: PixelRect, target: PixelRect,
                     aligned: PixelRect, selection: Selection?, cb: MTLCommandBuffer) throws -> TileGrid {
        let original = try RegionOps.assemble(grid, region: aligned, pipelines: pipelines, commandBuffer: cb)
        let selectionTexture = try selection.map { s in
            try RegionOps.assemble(s.tiles, region: aligned, clearValue: s.defaultValue, pipelines: pipelines, commandBuffer: cb)
        } ?? original
        let out = try RegionOps.makeTexture(context.device, width: aligned.width, height: aligned.height)
        guard let e = cb.makeComputeCommandEncoder() else { throw RenderError.resourceCreationFailed("mix encoder") }
        var u = FilterMixUniforms(targetOrigin: SIMD2(Int32(target.x - aligned.x), Int32(target.y - aligned.y)),
                                  targetSize: SIMD2(Int32(target.width), Int32(target.height)),
                                  filteredOffset: SIMD2(Int32(aligned.x - filteredRect.x), Int32(aligned.y - filteredRect.y)),
                                  hasSelection: selection == nil ? 0 : 1)
        e.setComputePipelineState(mixPipeline)
        e.setTexture(original, index: 0)
        e.setTexture(filtered, index: 1)
        e.setTexture(selectionTexture, index: 2)
        e.setTexture(out, index: 3)
        e.setBytes(&u, length: MemoryLayout<FilterMixUniforms>.stride, index: 0)
        dispatch(e, width: aligned.width, height: aligned.height)
        e.endEncoding()
        return RegionOps.split(out, region: aligned, device: context.device, commandBuffer: cb)
    }

    // MARK: Retouch sources

    /// `grid` moved by `offset` (integer pixels), covering `region`: what the clone stamp paints.
    public func shifted(_ grid: TileGrid, by offset: SIMD2<Int>, region: PixelRect) throws -> TileGrid {
        let aligned = RegionOps.tileAligned(region)
        guard let cb = context.commandQueue.makeCommandBuffer() else { throw RenderError.resourceCreationFailed("shift") }
        let t = try RegionOps.assemble(grid, region: aligned.offsetBy(-offset.x, -offset.y), pipelines: pipelines, commandBuffer: cb)
        let out = RegionOps.split(t, region: aligned, device: context.device, commandBuffer: cb)
        cb.commit()
        cb.waitUntilCompleted()
        if let error = cb.error { throw error }
        return out
    }

    /// Healing-brush source: the clone with the destination's low frequencies (`sigma` px).
    public func healed(_ grid: TileGrid, by offset: SIMD2<Int>, region: PixelRect, sigma: Float) throws -> TileGrid {
        let aligned = RegionOps.tileAligned(region)
        guard let cb = context.commandQueue.makeCommandBuffer() else { throw RenderError.resourceCreationFailed("heal") }
        let dest = try RegionOps.assemble(grid, region: aligned, pipelines: pipelines, commandBuffer: cb)
        let clone = try RegionOps.assemble(grid, region: aligned.offsetBy(-offset.x, -offset.y), pipelines: pipelines, commandBuffer: cb)
        let destBlur = try RegionOps.makeTexture(context.device, width: aligned.width, height: aligned.height)
        let cloneBlur = try RegionOps.makeTexture(context.device, width: aligned.width, height: aligned.height)
        let out = try RegionOps.makeTexture(context.device, width: aligned.width, height: aligned.height)
        let blur = MPSImageGaussianBlur(device: context.device, sigma: max(sigma, 1))
        blur.edgeMode = .clamp
        blur.encode(commandBuffer: cb, sourceTexture: dest, destinationTexture: destBlur)
        blur.encode(commandBuffer: cb, sourceTexture: clone, destinationTexture: cloneBlur)
        guard let e = cb.makeComputeCommandEncoder() else { throw RenderError.resourceCreationFailed("heal encoder") }
        e.setComputePipelineState(healPipeline)
        for (i, t) in [clone, destBlur, cloneBlur, out].enumerated() { e.setTexture(t, index: i) }
        dispatch(e, width: aligned.width, height: aligned.height)
        e.endEncoding()
        let grid = RegionOps.split(out, region: aligned, device: context.device, commandBuffer: cb)
        cb.commit()
        cb.waitUntilCompleted()
        if let error = cb.error { throw error }
        return grid
    }
}

/// One smudge stroke. The layer's pixels in `region` live in a working texture
/// while the stroke runs; each dab drags colour from behind it.
public final class SmudgeEngine {
    private let engine: FilterEngine
    public let original: TileGrid
    public private(set) var result: TileGrid
    private let region: PixelRect
    private let working: MTLTexture
    private let before: MTLTexture
    private let selection: MTLTexture?

    public init(context: MetalContext, tiles: TileGrid, region: PixelRect, selection: Selection?) throws {
        engine = try FilterEngine(context: context)
        original = tiles
        result = tiles
        let aligned = RegionOps.tileAligned(region)
        let pipelines = engine.pipelines
        self.region = aligned
        guard let cb = context.commandQueue.makeCommandBuffer() else { throw RenderError.resourceCreationFailed("smudge") }
        working = try RegionOps.assemble(tiles, region: aligned, pipelines: pipelines, commandBuffer: cb)
        before = try RegionOps.makeTexture(context.device, width: aligned.width, height: aligned.height)
        self.selection = try selection.map { s in
            try RegionOps.assemble(s.tiles, region: aligned, clearValue: s.defaultValue, pipelines: pipelines, commandBuffer: cb)
        }
        cb.commit()
    }

    /// Applies dabs (document coordinates) and returns the tiles that changed.
    @discardableResult
    public func add(_ dabs: [SmudgeDab]) -> Set<TileCoord> {
        guard !dabs.isEmpty, let cb = engine.context.commandQueue.makeCommandBuffer() else { return [] }
        var touched = Set<TileCoord>()
        let origin = SIMD2<Float>(Float(region.x), Float(region.y))
        var hasSelection: Int32 = selection == nil ? 0 : 1
        for var dab in dabs {
            dab.centre -= origin
            let r = Int(dab.radius.rounded(.up)) + 2
            let box = PixelRect(x: Int(dab.centre.x) - r, y: Int(dab.centre.y) - r, width: 2 * r + 1, height: 2 * r + 1)
            // Snapshot the area the dab reads (its rect plus the drag distance).
            let reach = Int(simd_length(dab.delta).rounded(.up)) + 1
            let read = RegionOps.expand(box, by: reach).intersection(PixelRect(x: 0, y: 0, width: region.width, height: region.height))
            guard !read.isEmpty, let blit = cb.makeBlitCommandEncoder() else { continue }
            blit.copy(from: working, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: read.x, y: read.y, z: 0),
                      sourceSize: MTLSize(width: read.width, height: read.height, depth: 1),
                      to: before, destinationSlice: 0, destinationLevel: 0, destinationOrigin: MTLOrigin(x: read.x, y: read.y, z: 0))
            blit.endEncoding()
            guard let e = cb.makeComputeCommandEncoder() else { continue }
            e.setComputePipelineState(engine.smudgePipeline)
            e.setTexture(before, index: 0)
            e.setTexture(working, index: 1)
            e.setTexture(selection ?? before, index: 2)
            e.setBytes(&dab, length: MemoryLayout<SmudgeDab>.stride, index: 0)
            var o = SIMD2<Int32>(Int32(box.x), Int32(box.y))
            e.setBytes(&o, length: 8, index: 1)
            e.setBytes(&hasSelection, length: 4, index: 2)
            e.dispatchThreads(MTLSize(width: box.width, height: box.height, depth: 1),
                              threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
            e.endEncoding()
            for c in box.offsetBy(region.x, region.y).intersection(region).tileCoords { touched.insert(c) }
        }
        // Copy touched tiles out of the working texture.
        if let blit = cb.makeBlitCommandEncoder() {
            let s = TileGeometry.size
            for coord in touched {
                let tile = TileTexture.makeTexture(device: engine.context.device)
                blit.copy(from: working, sourceSlice: 0, sourceLevel: 0,
                          sourceOrigin: MTLOrigin(x: coord.rect.x - region.x, y: coord.rect.y - region.y, z: 0),
                          sourceSize: MTLSize(width: s, height: s, depth: 1),
                          to: tile, destinationSlice: 0, destinationLevel: 0, destinationOrigin: MTLOrigin())
                result[coord] = .texture(TileTexture(tile))
            }
            blit.endEncoding()
        }
        cb.commit()
        return touched
    }

    public func finish() {
        guard let cb = engine.context.commandQueue.makeCommandBuffer() else { return }
        cb.commit()
        cb.waitUntilCompleted()
    }
}
