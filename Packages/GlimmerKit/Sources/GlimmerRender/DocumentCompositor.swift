import Foundation
import GlimmerCore
import Metal

/// Temporary, non-undoable changes shown while a tool is active (e.g. a layer
/// being dragged). Committed edits go into `DocumentState`.
public struct LayerOverrides: Equatable, Sendable {
    /// Integer pixel offsets per layer id (groups move their descendants).
    public var offsets: [UUID: SIMD2<Int>]

    public init(offsets: [UUID: SIMD2<Int>] = [:]) {
        self.offsets = offsets
    }

    public static let none = LayerOverrides()
}

/// A mask ready for compositing (enabled, feather already applied).
struct ResolvedMask {
    var tiles: TileGrid
    var defaultValue: Float
    var density: Float

    func tile(at coord: TileCoord) -> Tile {
        tiles[coord] ?? .solid(SIMD4(repeating: defaultValue))
    }
}

/// The layer tree flattened into what the per-tile renderer needs.
indirect enum RenderNode {
    struct Common {
        var mode: BlendMode
        var opacity: Float
        var isClipped: Bool
        var mask: ResolvedMask?
    }

    struct Pixels {
        var common: Common
        var grid: TileGrid
        var offset: SIMD2<Int>
        var below: [EffectGrid]
        var above: [EffectGrid]
        var overlay: ColorOverlayEffect?
    }

    case pixels(Pixels)
    case fill(Common, Fill)
    case adjustment(Common, Adjustment)
    case group(Common, [RenderNode])

    var common: Common {
        switch self {
        case .pixels(let p): p.common
        case .fill(let c, _), .adjustment(let c, _), .group(let c, _): c
        }
    }
}

/// Composites a document into a cache of 256×256 tiles in document space,
/// re-rendering only tiles whose inputs changed.
///
/// Each cached tile is RGBA16Float, premultiplied linear, with a full mip chain
/// so the canvas can minify without aliasing.
public final class DocumentCompositor {
    public static let mipLevels = 9  // 256 → 1

    private struct Entry {
        var signature: Int
        /// nil when nothing visible contributes (fully transparent).
        var texture: MTLTexture?
    }

    private let context: MetalContext
    private let pipelines: TilePipelines
    private let styles: LayerStyleRenderer
    private let smartRenderer: SmartObjectRenderer
    private let featherRenderer: MaskFeatherRenderer

    private var cache: [TileCoord: Entry] = [:]
    private var pool: [MTLTexture] = []
    private var scratch: [MTLTexture] = []

    private var effectsCache: [UUID: (key: Int, value: LayerStyleRenderer.Rendered)] = [:]
    private var smartCache: [UUID: (key: Int, value: TileGrid)] = [:]
    private var featherCache: [UUID: (key: Int, value: TileGrid)] = [:]

    public init(context: MetalContext) throws {
        self.context = context
        self.pipelines = try context.tilePipelines()
        self.styles = LayerStyleRenderer(pipelines: pipelines)
        self.smartRenderer = SmartObjectRenderer(pipelines: pipelines)
        self.featherRenderer = MaskFeatherRenderer(pipelines: pipelines)
    }

    // MARK: Resolving the tree

    /// Renders anything that needs neighbouring pixels (smart objects, styles,
    /// feathered masks), using caches, and returns the render tree.
    func resolve(_ state: DocumentState, overrides: LayerOverrides) -> [RenderNode] {
        let limit = RegionOps.expand(state.bounds, by: 512)
        var seen = Set<UUID>()

        func mask(for layer: Layer) -> ResolvedMask? {
            guard let m = layer.mask, m.isEnabled, m.density > 0 else { return nil }
            var tiles = m.tiles
            if m.feather > 0.25 {
                var h = Hasher()
                h.combine(m.tiles.contentSignature); h.combine(m.feather); h.combine(m.defaultValue)
                let key = h.finalize()
                if let hit = featherCache[layer.id], hit.key == key {
                    tiles = hit.value
                } else if let feathered = try? featherRenderer.feather(m, limit: limit) {
                    featherCache[layer.id] = (key, feathered)
                    tiles = feathered
                }
            }
            return ResolvedMask(tiles: tiles, defaultValue: m.defaultValue, density: Float(m.density))
        }

        func resolveList(_ layers: [Layer], offset: SIMD2<Int>) -> [RenderNode] {
            var nodes: [RenderNode] = []
            var baseHidden = false
            for layer in layers {
                if !layer.isClipped { baseHidden = !layer.isVisible }
                guard layer.isVisible, !(layer.isClipped && baseHidden) else { continue }
                seen.insert(layer.id)
                let o = offset &+ (overrides.offsets[layer.id] ?? .zero)
                let common = RenderNode.Common(mode: layer.blendMode, opacity: Float(layer.opacity),
                                               isClipped: layer.isClipped, mask: mask(for: layer))
                let overlay = layer.effects.colorOverlay.flatMap { $0.isEnabled ? $0 : nil }
                switch layer.content {
                case .raster(let grid):
                    nodes.append(pixelsNode(layer, grid: grid, common: common, offset: o, overlay: overlay, limit: limit))
                case .smart(let smart):
                    var h = Hasher()
                    h.combine(smart.source.contentSignature); h.combine(smart.transform); h.combine(limit)
                    let key = h.finalize()
                    let grid: TileGrid
                    if let hit = smartCache[layer.id], hit.key == key {
                        grid = hit.value
                    } else {
                        grid = (try? smartRenderer.render(smart, limit: limit)) ?? TileGrid()
                        smartCache[layer.id] = (key, grid)
                    }
                    nodes.append(pixelsNode(layer, grid: grid, common: common, offset: o, overlay: overlay, limit: limit))
                case .fill(let fill):
                    nodes.append(.fill(common, fill))
                case .adjustment(let adjustment):
                    nodes.append(.adjustment(common, adjustment))
                case .group(let group):
                    nodes.append(.group(common, resolveList(group.children, offset: o)))
                }
            }
            return nodes
        }

        let nodes = resolveList(state.layers, offset: .zero)
        // Forget caches for layers that are gone or hidden.
        effectsCache = effectsCache.filter { seen.contains($0.key) }
        smartCache = smartCache.filter { seen.contains($0.key) }
        featherCache = featherCache.filter { seen.contains($0.key) }
        return nodes
    }

    private func pixelsNode(_ layer: Layer, grid: TileGrid, common: RenderNode.Common, offset: SIMD2<Int>,
                            overlay: ColorOverlayEffect?, limit: PixelRect) -> RenderNode {
        var rendered = LayerStyleRenderer.Rendered()
        if layer.effects.hasSpatialEffects {
            var h = Hasher()
            h.combine(grid.contentSignature)
            h.combine(layer.effects)
            h.combine(limit)
            if let m = common.mask { h.combine(m.tiles.contentSignature); h.combine(m.defaultValue) }
            let key = h.finalize()
            if let hit = effectsCache[layer.id], hit.key == key {
                rendered = hit.value
            } else {
                rendered = (try? styles.render(pixels: grid, mask: common.mask, effects: layer.effects, limit: limit))
                    ?? LayerStyleRenderer.Rendered()
                effectsCache[layer.id] = (key, rendered)
            }
        }
        return .pixels(RenderNode.Pixels(common: common, grid: grid, offset: offset,
                                         below: rendered.below, above: rendered.above, overlay: overlay))
    }

    // MARK: Signatures

    /// Layer-space tiles feeding output tile `coord` for content shifted by `offset`.
    private func sourceCoords(_ coord: TileCoord, offset: SIMD2<Int>) -> [TileCoord] {
        offset == .zero ? [coord] : coord.rect.offsetBy(-offset.x, -offset.y).tileCoords
    }

    private func combine(_ c: RenderNode.Common, _ h: inout Hasher) {
        h.combine(c.mode); h.combine(c.opacity); h.combine(c.isClipped)
        if let m = c.mask { h.combine(m.density); h.combine(m.defaultValue) } else { h.combine(-1) }
    }

    /// Hashes everything that affects `coord`. Returns whether anything could be visible there.
    @discardableResult
    private func signature(_ nodes: [RenderNode], at coord: TileCoord, into h: inout Hasher) -> Bool {
        var visible = false
        for node in nodes {
            combine(node.common, &h)
            switch node {
            case .pixels(let p):
                h.combine(0)
                h.combine(p.offset.x); h.combine(p.offset.y)
                for lc in sourceCoords(coord, offset: p.offset) {
                    h.combine(lc)
                    if let t = p.grid[lc] { t.combineIdentity(into: &h); visible = true }
                    p.common.mask?.tile(at: lc).combineIdentity(into: &h)
                    for e in p.below + p.above {
                        h.combine(e.mode)
                        if let t = e.grid[lc] { t.combineIdentity(into: &h); visible = true }
                    }
                }
                h.combine(p.overlay)
            case .fill(_, let fill):
                h.combine(1); h.combine(fill)
                node.common.mask?.tile(at: coord).combineIdentity(into: &h)
                visible = true
            case .adjustment(_, let adjustment):
                h.combine(2); h.combine(adjustment)
                node.common.mask?.tile(at: coord).combineIdentity(into: &h)
            case .group(_, let children):
                h.combine(3)
                node.common.mask?.tile(at: coord).combineIdentity(into: &h)
                h.combine(children.count)
                if signature(children, at: coord, into: &h) { visible = true }
            }
        }
        return visible
    }

    // MARK: Updating

    /// Re-composites up to `budget` stale tiles from `coords` (in priority order).
    /// Returns true when stale tiles remain.
    @discardableResult
    public func update(
        _ state: DocumentState,
        overrides: LayerOverrides = .none,
        coords: [TileCoord],
        budget: Int = .max,
        commandBuffer: MTLCommandBuffer
    ) -> Bool {
        let nodes = resolve(state, overrides: overrides)
        let gamma = state.blendSpace == .gamma
        var done = 0
        var remaining = false
        var mipTargets: [MTLTexture] = []

        for coord in coords {
            var h = Hasher()
            h.combine(gamma)
            let visible = signature(nodes, at: coord, into: &h)
            let sig = h.finalize()
            if cache[coord]?.signature == sig { continue }
            if done >= budget {
                remaining = true
                break
            }
            done += 1

            guard visible else {
                if let old = cache[coord]?.texture { pool.append(old) }
                cache[coord] = Entry(signature: sig, texture: nil)
                continue
            }
            let texture = cache[coord]?.texture ?? makeCompositeTexture()
            render(nodes, at: coord, into: texture, clear: true, gamma: gamma, commandBuffer: commandBuffer)
            mipTargets.append(texture)
            cache[coord] = Entry(signature: sig, texture: texture)
        }

        if !mipTargets.isEmpty, let blit = commandBuffer.makeBlitCommandEncoder() {
            blit.label = "Composite mips"
            for texture in mipTargets { blit.generateMipmaps(for: texture) }
            blit.endEncoding()
        }
        return remaining
    }

    // MARK: Rendering one tile

    /// What a clipped layer is clipped to.
    private struct ClipSource {
        var alpha: MTLTexture
        var mask: MTLTexture
        var density: Float
    }

    private func beginPass(_ target: MTLTexture, clear: Bool, _ cb: MTLCommandBuffer) -> MTLRenderCommandEncoder? {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = clear ? .clear : .load
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        pass.colorAttachments[0].storeAction = .store
        return cb.makeRenderCommandEncoder(descriptor: pass)
    }

    private func bindMasks(_ e: MTLRenderCommandEncoder, mask: Tile?, clip: ClipSource?) {
        e.setFragmentTexture(mask.map(pipelines.texture(for:)) ?? pipelines.white, index: 1)
        e.setFragmentTexture(clip?.alpha ?? pipelines.white, index: 2)
        e.setFragmentTexture(clip?.mask ?? pipelines.white, index: 3)
    }

    private func layerUniforms(_ c: RenderNode.Common, gamma: Bool, clip: ClipSource?, coord: TileCoord) -> LayerUniforms {
        var u = LayerUniforms()
        u.mode = c.mode.shaderIndex
        u.opacity = c.opacity
        u.gammaSpace = gamma ? 1 : 0
        u.maskDensity = c.mask?.density ?? 0
        u.clipDensity = clip?.density ?? 0
        u.tileOrigin = SIMD2(Float(coord.rect.x), Float(coord.rect.y))
        return u
    }

    private func maskTexture(_ c: RenderNode.Common, at coord: TileCoord) -> MTLTexture {
        c.mask.map { pipelines.texture(for: $0.tile(at: coord)) } ?? pipelines.white
    }

    private func render(_ nodes: [RenderNode], at coord: TileCoord, into target: MTLTexture, clear: Bool,
                        gamma: Bool, commandBuffer cb: MTLCommandBuffer) {
        guard var encoder = beginPass(target, clear: clear, cb) else { return }
        var temps: [MTLTexture] = []
        defer { scratch.append(contentsOf: temps) }
        var base: ClipSource?  // the current clipping base; nil hides clipped layers
        let s = Float(TileGeometry.size)

        for node in nodes {
            let c = node.common
            let clip: ClipSource?
            if c.isClipped {
                guard let b = base else { continue }
                clip = b
            } else {
                clip = nil
            }

            switch node {
            case .pixels(let p):
                encoder.setRenderPipelineState(pipelines.layer)
                let u = layerUniforms(c, gamma: gamma, clip: clip, coord: coord)
                let lcs = sourceCoords(coord, offset: p.offset)
                func rect(_ lc: TileCoord) -> SIMD4<Float> {
                    let o = lc.origin &+ p.offset &- coord.origin
                    return SIMD4(Float(o.x), Float(o.y), s, s)
                }
                func drawEffects(_ effects: [EffectGrid]) {
                    for effect in effects {
                        var eu = u
                        eu.mode = effect.mode.shaderIndex
                        eu.maskDensity = 0  // effects are already shaped by the mask
                        for lc in lcs {
                            guard let tile = effect.grid[lc] else { continue }
                            encoder.setFragmentTexture(pipelines.texture(for: tile), index: 0)
                            bindMasks(encoder, mask: nil, clip: clip)
                            encoder.setFragmentBytes(&eu, length: MemoryLayout<LayerUniforms>.stride, index: 0)
                            pipelines.drawQuad(encoder, rect: rect(lc))
                        }
                    }
                }
                drawEffects(p.below)
                var lu = u
                if let overlay = p.overlay {
                    lu.overlay = SIMD4(overlay.color.linear, Float(overlay.opacity))
                    lu.overlayMode = overlay.blendMode.shaderIndex
                }
                for lc in lcs {
                    guard let tile = p.grid[lc] else { continue }
                    encoder.setFragmentTexture(pipelines.texture(for: tile), index: 0)
                    bindMasks(encoder, mask: p.common.mask?.tile(at: lc), clip: clip)
                    encoder.setFragmentBytes(&lu, length: MemoryLayout<LayerUniforms>.stride, index: 0)
                    pipelines.drawQuad(encoder, rect: rect(lc))
                }
                drawEffects(p.above)
                if !c.isClipped {
                    let alpha = p.offset == .zero
                        ? (p.grid[coord].map(pipelines.texture(for:)) ?? pipelines.clear) : pipelines.white
                    base = ClipSource(alpha: alpha, mask: maskTexture(c, at: coord), density: c.mask?.density ?? 0)
                }

            case .fill(_, let fill):
                encoder.setRenderPipelineState(pipelines.layer)
                var u = layerUniforms(c, gamma: gamma, clip: clip, coord: coord)
                var source = pipelines.white
                var lut = pipelines.white
                switch fill {
                case .solid(let color):
                    source = pipelines.solid(SIMD4(color.linear, 1))
                case .gradient(let g):
                    u.sourceKind = g.style == .linear ? 1 : 2
                    u.gradientStart = SIMD2(Float(g.start.x), Float(g.start.y))
                    u.gradientEnd = SIMD2(Float(g.end.x), Float(g.end.y))
                    u.gradientReverse = g.reverse ? 1 : 0
                    lut = pipelines.lut(key: g.stops.hashValue) { Self.gradientTable(g.stops) }
                case .pattern(let pattern):
                    u.sourceKind = 3
                    u.patternKind = pattern.kind.shaderIndex
                    u.patternScale = Float(pattern.scale)
                    u.patternForeground = SIMD4(pattern.foreground.linear, 1)
                    u.patternBackground = SIMD4(pattern.background.linear, 1)
                }
                encoder.setFragmentTexture(source, index: 0)
                encoder.setFragmentTexture(lut, index: 4)
                bindMasks(encoder, mask: c.mask?.tile(at: coord), clip: clip)
                encoder.setFragmentBytes(&u, length: MemoryLayout<LayerUniforms>.stride, index: 0)
                pipelines.drawQuad(encoder, rect: TilePipelines.fullTile)
                if !c.isClipped {
                    base = ClipSource(alpha: pipelines.white, mask: maskTexture(c, at: coord), density: c.mask?.density ?? 0)
                }

            case .adjustment(_, let adjustment):
                encoder.setRenderPipelineState(pipelines.adjust)
                var u = AdjustUniforms()
                u.kind = adjustment.kind.shaderIndex
                u.mode = c.mode.shaderIndex
                u.opacity = c.opacity
                u.gammaSpace = gamma ? 1 : 0
                u.maskDensity = c.mask?.density ?? 0
                u.clipDensity = clip?.density ?? 0
                u.setParameters(adjustment.shaderParameters)
                let lut = adjustment.kind.usesLUT
                    ? pipelines.lut(key: adjustment.hashValue) { adjustment.lookupTable() } : pipelines.white
                encoder.setFragmentTexture(lut, index: 0)
                bindMasks(encoder, mask: c.mask?.tile(at: coord), clip: clip)
                encoder.setFragmentBytes(&u, length: MemoryLayout<AdjustUniforms>.stride, index: 0)
                pipelines.drawQuad(encoder, rect: TilePipelines.fullTile)
                if !c.isClipped {
                    base = ClipSource(alpha: pipelines.white, mask: maskTexture(c, at: coord), density: c.mask?.density ?? 0)
                }

            case .group(_, let children):
                encoder.endEncoding()
                let maskTile = c.mask?.tile(at: coord)
                if c.mode == .passThrough {
                    // Children blend straight into this target; opacity and mask
                    // then pull the result back toward the saved backdrop.
                    let needsMix = c.opacity < 1 || c.mask != nil || clip != nil
                    var backup: MTLTexture?
                    if needsMix, let blit = cb.makeBlitCommandEncoder() {
                        let b = scratchTexture()
                        temps.append(b)
                        blit.copy(from: target, sourceSlice: 0, sourceLevel: 0, to: b, destinationSlice: 0,
                                  destinationLevel: 0, sliceCount: 1, levelCount: 1)
                        blit.endEncoding()
                        backup = b
                    }
                    render(children, at: coord, into: target, clear: false, gamma: gamma, commandBuffer: cb)
                    guard let next = beginPass(target, clear: false, cb) else { return }
                    encoder = next
                    if let backup {
                        encoder.setRenderPipelineState(pipelines.passthroughMix)
                        var u = layerUniforms(c, gamma: gamma, clip: clip, coord: coord)
                        encoder.setFragmentTexture(backup, index: 0)
                        bindMasks(encoder, mask: maskTile, clip: clip)
                        encoder.setFragmentBytes(&u, length: MemoryLayout<LayerUniforms>.stride, index: 0)
                        pipelines.drawQuad(encoder, rect: TilePipelines.fullTile)
                    }
                    if !c.isClipped {
                        base = ClipSource(alpha: pipelines.white, mask: maskTexture(c, at: coord), density: c.mask?.density ?? 0)
                    }
                } else {
                    let temp = scratchTexture()
                    temps.append(temp)
                    render(children, at: coord, into: temp, clear: true, gamma: gamma, commandBuffer: cb)
                    guard let next = beginPass(target, clear: false, cb) else { return }
                    encoder = next
                    encoder.setRenderPipelineState(pipelines.layer)
                    var u = layerUniforms(c, gamma: gamma, clip: clip, coord: coord)
                    encoder.setFragmentTexture(temp, index: 0)
                    bindMasks(encoder, mask: maskTile, clip: clip)
                    encoder.setFragmentBytes(&u, length: MemoryLayout<LayerUniforms>.stride, index: 0)
                    pipelines.drawQuad(encoder, rect: TilePipelines.fullTile)
                    if !c.isClipped {
                        base = ClipSource(alpha: temp, mask: maskTexture(c, at: coord), density: c.mask?.density ?? 0)
                    }
                }
            }
        }
        encoder.endEncoding()
    }

    static func gradientTable(_ stops: [GradientStop]) -> [SIMD4<Float>] {
        (0..<1024).map { i in
            let (c, o) = GradientStop.sample(stops, at: Double(i) / 1023)
            return SIMD4(Float(c.r), Float(c.g), Float(c.b), Float(o))
        }
    }

    // MARK: Textures

    /// The composited tile at `coord`, if it has been rendered and isn't empty.
    public func texture(at coord: TileCoord) -> MTLTexture? {
        cache[coord]?.texture
    }

    /// Drops cached tiles outside `bounds` (e.g. after the document shrinks).
    public func purge(outside bounds: PixelRect) {
        let keep = Set(bounds.tileCoords)
        for (coord, entry) in cache where !keep.contains(coord) {
            if let t = entry.texture { pool.append(t) }
            cache[coord] = nil
        }
    }

    private func makeCompositeTexture() -> MTLTexture {
        if let reused = pool.popLast() { return reused }
        let d = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: TileGeometry.pixelFormat,
            width: TileGeometry.size, height: TileGeometry.size, mipmapped: true)
        d.mipmapLevelCount = Self.mipLevels
        d.usage = [.renderTarget, .shaderRead]
        d.storageMode = .private
        guard let texture = context.device.makeTexture(descriptor: d) else {
            fatalError("Out of GPU memory allocating a composite tile")
        }
        texture.label = "Composite tile"
        return texture
    }

    private func scratchTexture() -> MTLTexture {
        if let reused = scratch.popLast() { return reused }
        let d = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: TileGeometry.pixelFormat,
            width: TileGeometry.size, height: TileGeometry.size, mipmapped: false)
        d.usage = [.renderTarget, .shaderRead]
        d.storageMode = .private
        guard let texture = context.device.makeTexture(descriptor: d) else {
            fatalError("Out of GPU memory allocating a group tile")
        }
        texture.label = "Group tile"
        return texture
    }

    // MARK: Rasterizing

    /// Renders `layer` on its own (normal blending, full opacity, no mask, no
    /// styles) into raster tiles covering `bounds`. Used for Rasterize Layer
    /// and Merge Group; the caller keeps the layer's own properties.
    public static func rasterize(_ layer: Layer, bounds: PixelRect, blendSpace: BlendSpace,
                                 context: MetalContext) throws -> TileGrid {
        var solo = layer
        solo.isVisible = true
        solo.opacity = 1
        solo.blendMode = layer.isGroup && layer.blendMode == .passThrough ? .passThrough : .normal
        solo.mask = nil
        solo.isClipped = false
        solo.effects = LayerEffects()
        let state = DocumentState(width: max(1, bounds.maxX), height: max(1, bounds.maxY),
                                  blendSpace: blendSpace, layers: [solo])
        let compositor = try DocumentCompositor(context: context)
        let coords = bounds.tileCoords
        var grid = TileGrid()
        for batch in stride(from: 0, to: coords.count, by: 64) {
            let slice = Array(coords[batch..<min(batch + 64, coords.count)])
            guard let cb = context.commandQueue.makeCommandBuffer() else { continue }
            compositor.update(state, coords: slice, commandBuffer: cb)
            if let blit = cb.makeBlitCommandEncoder() {
                for coord in slice {
                    guard let source = compositor.texture(at: coord) else { continue }
                    let tile = TileTexture.makeTexture(device: context.device)
                    blit.copy(from: source, sourceSlice: 0, sourceLevel: 0, to: tile, destinationSlice: 0,
                              destinationLevel: 0, sliceCount: 1, levelCount: 1)
                    grid[coord] = .texture(TileTexture(tile))
                }
                blit.endEncoding()
            }
            cb.commit()
            cb.waitUntilCompleted()
        }
        return grid
    }

    // MARK: Full-document rendering (export, thumbnails, tests)

    /// Composites every tile of the document and returns premultiplied linear
    /// Float16 RGBA pixels for `region` (default: the whole document).
    public func renderPixels(
        _ state: DocumentState, overrides: LayerOverrides = .none, region: PixelRect? = nil
    ) throws -> (buffer: MTLBuffer, bytesPerRow: Int, rect: PixelRect) {
        let rect = (region ?? state.bounds).intersection(state.bounds)
        guard !rect.isEmpty else { throw RenderError.resourceCreationFailed("empty region") }
        let bytesPerRow = rect.width * TileGeometry.bytesPerPixel
        guard let buffer = context.device.makeBuffer(length: bytesPerRow * rect.height, options: .storageModeShared) else {
            throw RenderError.resourceCreationFailed("export buffer")
        }
        memset(buffer.contents(), 0, buffer.length)

        let coords = rect.tileCoords
        // Batch so huge documents don't build one enormous command buffer.
        for batch in stride(from: 0, to: coords.count, by: 64) {
            let slice = Array(coords[batch..<min(batch + 64, coords.count)])
            guard let cb = context.commandQueue.makeCommandBuffer() else { continue }
            update(state, overrides: overrides, coords: slice, commandBuffer: cb)
            if let blit = cb.makeBlitCommandEncoder() {
                for coord in slice {
                    guard let texture = texture(at: coord) else { continue }
                    let part = coord.rect.intersection(rect)
                    let src = MTLOrigin(x: part.x - coord.rect.x, y: part.y - coord.rect.y, z: 0)
                    let offset = (part.y - rect.y) * bytesPerRow + (part.x - rect.x) * TileGeometry.bytesPerPixel
                    blit.copy(from: texture, sourceSlice: 0, sourceLevel: 0, sourceOrigin: src,
                              sourceSize: MTLSize(width: part.width, height: part.height, depth: 1),
                              to: buffer, destinationOffset: offset,
                              destinationBytesPerRow: bytesPerRow,
                              destinationBytesPerImage: bytesPerRow * rect.height)
                }
                blit.endEncoding()
            }
            cb.commit()
            cb.waitUntilCompleted()
        }
        return (buffer, bytesPerRow, rect)
    }
}
