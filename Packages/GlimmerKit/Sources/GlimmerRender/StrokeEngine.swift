import Foundation
import GlimmerCore
import Metal

/// Mirrors `DabInstance` in Composite.metal.
public struct DabInstance: Sendable, Equatable {
    public var center: SIMD2<Float>
    public var radius: Float
    public var hardness: Float
    public var roundness: Float
    public var angle: Float
    public var flow: Float
    public var textured: Float

    public init(center: SIMD2<Float>, radius: Float, hardness: Float, roundness: Float = 1,
                angle: Float = 0, flow: Float, textured: Bool = false) {
        self.center = center
        self.radius = radius
        self.hardness = hardness
        self.roundness = roundness
        self.angle = angle
        self.flow = flow
        self.textured = textured ? 1 : 0
    }

    var bounds: PixelRect {
        let r = Int((radius + 2).rounded(.up))
        return PixelRect(x: Int(center.x) - r, y: Int(center.y) - r, width: 2 * r + 1, height: 2 * r + 1)
    }
}

/// One brush stroke on a layer's pixels or mask. Dabs accumulate in per-tile
/// coverage ("wet") textures; after each batch the touched tiles are recomputed
/// from the untouched originals, so opacity caps the stroke like Photoshop.
public final class StrokeEngine {
    public enum Target: Sendable {
        case pixels
        /// Painting a mask: missing tiles use `defaultValue`.
        case mask(defaultValue: Float)
    }

    public let original: TileGrid
    public private(set) var result: TileGrid

    private let ops: PixelOps
    private let target: Target
    private let mode: PixelOps.Mode
    private let color: SIMD4<Float>
    private let opacity: Float
    private let maskTarget: Float
    private let selection: Selection?
    private var wet: [TileCoord: MTLTexture] = [:]

    public init(context: MetalContext, tiles: TileGrid, target: Target, erase: Bool, color: SIMD4<Float>,
                opacity: Float, maskTarget: Float = 0, selection: Selection?) throws {
        self.ops = try PixelOps(context: context)
        self.original = tiles
        self.result = tiles
        self.target = target
        if case .mask = target {
            mode = .mask
        } else {
            mode = erase ? .erase : .paint
        }
        self.color = color
        self.opacity = opacity
        self.maskTarget = maskTarget
        self.selection = selection
    }

    /// Stamps `dabs` and updates `result`. Returns the coordinates that changed.
    @discardableResult
    public func add(_ dabs: [DabInstance]) -> Set<TileCoord> {
        guard !dabs.isEmpty, let cb = ops.context.commandQueue.makeCommandBuffer() else { return [] }
        cb.label = "Brush dabs"
        var byTile: [TileCoord: [DabInstance]] = [:]
        for dab in dabs {
            for coord in dab.bounds.tileCoords { byTile[coord, default: []].append(dab) }
        }
        for (coord, list) in byTile {
            let texture = wetTexture(at: coord, cb)
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = texture
            pass.colorAttachments[0].loadAction = .load
            pass.colorAttachments[0].storeAction = .store
            guard let e = cb.makeRenderCommandEncoder(descriptor: pass) else { continue }
            e.setRenderPipelineState(ops.dab)
            var origin = SIMD2<Float>(Float(coord.rect.x), Float(coord.rect.y))
            e.setVertexBytes(&origin, length: 8, index: 1)
            for chunk in stride(from: 0, to: list.count, by: 128) {
                var slice = Array(list[chunk..<min(chunk + 128, list.count)])
                e.setVertexBytes(&slice, length: MemoryLayout<DabInstance>.stride * slice.count, index: 0)
                e.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: slice.count)
            }
            e.endEncoding()
        }
        let coords = Array(byTile.keys)
        var sourceDefault: Float?
        if case .mask(let d) = target { sourceDefault = d }
        let updated = ops.encode(coords: coords, source: original, sourceDefault: sourceDefault, coverage: wet,
                                 fullCoverage: false, selection: selection, mode: mode, color: color,
                                 opacity: opacity, maskTarget: maskTarget, commandBuffer: cb)
        cb.commit()
        for (c, t) in updated { result[c] = t }
        return Set(coords)
    }

    /// Waits for the GPU (call before handing `result` to the document).
    public func finish() {
        guard let cb = ops.context.commandQueue.makeCommandBuffer() else { return }
        cb.commit()
        cb.waitUntilCompleted()
    }

    private func wetTexture(at coord: TileCoord, _ cb: MTLCommandBuffer) -> MTLTexture {
        if let t = wet[coord] { return t }
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: TileGeometry.pixelFormat, width: TileGeometry.size,
                                                         height: TileGeometry.size, mipmapped: false)
        d.usage = [.renderTarget, .shaderRead]
        d.storageMode = .private
        let t = ops.context.device.makeTexture(descriptor: d)!
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = t
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        pass.colorAttachments[0].storeAction = .store
        cb.makeRenderCommandEncoder(descriptor: pass)?.endEncoding()
        wet[coord] = t
        return t
    }
}
