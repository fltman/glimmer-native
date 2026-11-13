import Foundation
import GlimmerCore
import Metal
import MetalPerformanceShaders

/// Feather / grow / shrink on the GPU, any radius (the web app capped these at 32 px).
public enum SelectionOps {
    public enum Operation: Sendable {
        case feather(Double)
        case grow(Double)
        case shrink(Double)
    }

    public static func apply(_ op: Operation, to selection: Selection, limit: PixelRect,
                             context: MetalContext) throws -> Selection {
        let radius: Double
        switch op {
        case .feather(let r), .grow(let r), .shrink(let r): radius = r
        }
        guard radius > 0 else { return selection }
        // Work over everything that can change: the stored tiles plus reach, within the document.
        let stored = selection.tiles.tileBounds ?? limit
        let region = RegionOps.tileAligned(RegionOps.expand(selection.defaultValue > 0 ? limit : stored,
                                                            by: Int((radius * 3).rounded(.up))).intersection(RegionOps.expand(limit, by: 256)))
        guard !region.isEmpty else { return selection }
        let pipelines = try context.tilePipelines()
        guard let cb = context.commandQueue.makeCommandBuffer() else { throw RenderError.resourceCreationFailed("selection ops") }
        let source = try RegionOps.assemble(selection.tiles, region: region, clearValue: selection.defaultValue,
                                            pipelines: pipelines, commandBuffer: cb)
        let out = try RegionOps.makeTexture(context.device, width: region.width, height: region.height)
        switch op {
        case .feather(let r):
            let blur = MPSImageGaussianBlur(device: context.device, sigma: Float(r / 2))
            blur.edgeMode = .clamp
            blur.encode(commandBuffer: cb, sourceTexture: source, destinationTexture: out)
        case .grow(let r), .shrink(let r):
            let grow: Bool = if case .grow = op { true } else { false }
            // Distance from the (thresholded) selection, or from its complement for shrink.
            let binary = try RegionOps.makeTexture(context.device, width: region.width, height: region.height, format: .r32Float)
            let distance = try RegionOps.makeTexture(context.device, width: region.width, height: region.height, format: .r32Float)
            // The selection value is in every channel; using red via a gray transform picks it up.
            let pick = MPSImageThresholdBinary(device: context.device, thresholdValue: 0.5, maximumValue: 1,
                                               linearGrayColorTransform: [1, 0, 0])
            pick.encode(commandBuffer: cb, sourceTexture: source, destinationTexture: binary)
            let input: MTLTexture
            if grow {
                input = binary
            } else {
                let inverted = try RegionOps.makeTexture(context.device, width: region.width, height: region.height, format: .r32Float)
                let invert = MPSImageThresholdBinaryInverse(device: context.device, thresholdValue: 0.5, maximumValue: 1,
                                                            linearGrayColorTransform: [1, 0, 0])
                invert.encode(commandBuffer: cb, sourceTexture: binary, destinationTexture: inverted)
                input = inverted
            }
            MPSImageEuclideanDistanceTransform(device: context.device)
                .encode(commandBuffer: cb, sourceTexture: input, destinationTexture: distance)
            try encodeRemap(distance: distance, radius: Float(r), grow: grow, into: out, cb: cb, context: context)
        }
        var grid = RegionOps.split(out, region: region, device: context.device, commandBuffer: cb)
        cb.commit()
        cb.waitUntilCompleted()
        if let error = cb.error { throw error }
        // Keep the default outside the processed region.
        for (c, t) in selection.tiles.tiles where !region.tileCoords.contains(c) { grid[c] = t }
        return Selection(tiles: grid, defaultValue: selection.defaultValue)
    }

    /// value = grow ? (d ≤ r) : (d > r), with a 1 px anti-aliased edge.
    private static func encodeRemap(distance: MTLTexture, radius: Float, grow: Bool, into out: MTLTexture,
                                    cb: MTLCommandBuffer, context: MetalContext) throws {
        guard let fn = context.library.makeFunction(name: "selection_distance_remap"),
              let e = cb.makeComputeCommandEncoder() else { throw RenderError.libraryUnavailable("selection_distance_remap") }
        let pipeline = try context.device.makeComputePipelineState(function: fn)
        var params = SIMD2<Float>(radius, grow ? 1 : 0)
        e.setComputePipelineState(pipeline)
        e.setTexture(distance, index: 0)
        e.setTexture(out, index: 1)
        e.setBytes(&params, length: 8, index: 0)
        e.dispatchThreads(MTLSize(width: out.width, height: out.height, depth: 1),
                          threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
        e.endEncoding()
    }
}
