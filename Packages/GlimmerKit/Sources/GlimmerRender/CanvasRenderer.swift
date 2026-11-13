import Metal
import QuartzCore
import simd

/// Everything needed to draw one frame of the canvas.
public struct CanvasFrame: Sendable {
    /// View points → document pixels (from `ViewTransform.viewToDocumentMatrix`).
    public var viewToDocument: simd_double3x3
    /// Drawable pixels per view point.
    public var backingScale: Double
    public var documentSize: SIMD2<Double>
    /// Linear, premultiplied.
    public var pasteboardColor: SIMD4<Float>
    /// Checker square size in view points.
    public var checkerSize: Double

    public init(
        viewToDocument: simd_double3x3,
        backingScale: Double,
        documentSize: SIMD2<Double>,
        pasteboardColor: SIMD4<Float>,
        checkerSize: Double = 8
    ) {
        self.viewToDocument = viewToDocument
        self.backingScale = backingScale
        self.documentSize = documentSize
        self.pasteboardColor = pasteboardColor
        self.checkerSize = checkerSize
    }
}

/// Mirrors `CanvasUniforms` in Canvas.metal.
struct CanvasUniforms {
    var pixelToDocument: simd_float3x3
    var documentSize: SIMD2<Float>
    var checkerSize: Float
    var documentPerPixel: Float
    var pasteboard: SIMD4<Float>
    var checkerLight: SIMD4<Float>
    var checkerDark: SIMD4<Float>
}

public enum LinearColor {
    /// sRGB-encoded component → linear light.
    public static func linearize(_ c: Double) -> Double {
        c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
    }

    public static func fromSRGB(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) -> SIMD4<Float> {
        SIMD4(Float(linearize(r) * a), Float(linearize(g) * a), Float(linearize(b) * a), Float(a))
    }
}

/// Draws the pasteboard and document area. Later phases add the composite.
public final class CanvasRenderer: @unchecked Sendable {
    public static let pixelFormat = MTLPixelFormat.rgba16Float

    public let context: MetalContext
    private let pipeline: MTLRenderPipelineState

    private let checkerLight = LinearColor.fromSRGB(1, 1, 1)
    private let checkerDark = LinearColor.fromSRGB(0.8, 0.8, 0.8)

    public init(context: MetalContext) throws {
        self.context = context
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.label = "Canvas"
        descriptor.vertexFunction = context.library.makeFunction(name: "canvas_vertex")
        descriptor.fragmentFunction = context.library.makeFunction(name: "canvas_fragment")
        descriptor.colorAttachments[0].pixelFormat = Self.pixelFormat
        guard descriptor.vertexFunction != nil, descriptor.fragmentFunction != nil else {
            throw RenderError.libraryUnavailable("canvas shader functions missing")
        }
        self.pipeline = try context.device.makeRenderPipelineState(descriptor: descriptor)
    }

    public var device: MTLDevice { context.device }

    func uniforms(for frame: CanvasFrame) -> CanvasUniforms {
        let pointsPerPixel = 1 / frame.backingScale
        let pixelToPoint = simd_double3x3(diagonal: SIMD3(pointsPerPixel, pointsPerPixel, 1))
        let m = frame.viewToDocument * pixelToPoint
        let docPerPixel = simd_length(SIMD2(m.columns.0.x, m.columns.0.y))
        func f(_ c: SIMD3<Double>) -> SIMD3<Float> { SIMD3<Float>(Float(c.x), Float(c.y), Float(c.z)) }
        return CanvasUniforms(
            pixelToDocument: simd_float3x3(columns: (f(m.columns.0), f(m.columns.1), f(m.columns.2))),
            documentSize: SIMD2<Float>(Float(frame.documentSize.x), Float(frame.documentSize.y)),
            checkerSize: Float(frame.checkerSize * frame.backingScale),
            documentPerPixel: Float(docPerPixel),
            pasteboard: frame.pasteboardColor,
            checkerLight: checkerLight,
            checkerDark: checkerDark
        )
    }

    /// Encodes the canvas into `target` (must be `pixelFormat`).
    public func encode(_ frame: CanvasFrame, into commandBuffer: MTLCommandBuffer, target: MTLTexture) {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .dontCare
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        encoder.label = "Canvas"
        var u = uniforms(for: frame)
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentBytes(&u, length: MemoryLayout<CanvasUniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
    }

    public func render(_ frame: CanvasFrame, to drawable: CAMetalDrawable) {
        guard let commandBuffer = context.commandQueue.makeCommandBuffer() else { return }
        commandBuffer.label = "Canvas frame"
        encode(frame, into: commandBuffer, target: drawable.texture)
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }
}
