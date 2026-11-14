import GlimmerCore
import Metal
import QuartzCore
import simd

/// Everything needed to draw one frame of the canvas.
public struct CanvasFrame: Sendable {
    public var transform: ViewTransform
    /// View size in points.
    public var viewSize: SIMD2<Double>
    /// Drawable pixels per view point.
    public var backingScale: Double
    public var documentSize: SIMD2<Double>
    /// Linear, premultiplied.
    public var pasteboardColor: SIMD4<Float>
    /// Checker square size in view points.
    public var checkerSize: Double

    public init(
        transform: ViewTransform,
        viewSize: SIMD2<Double>,
        backingScale: Double,
        documentSize: SIMD2<Double>,
        pasteboardColor: SIMD4<Float>,
        checkerSize: Double = 8
    ) {
        self.transform = transform
        self.viewSize = viewSize
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

/// Mirrors `PresentUniforms` in Tiles.metal.
struct PresentUniforms {
    var documentToClip: simd_float3x3
    var documentRect: SIMD4<Float>
    var uvRect: SIMD4<Float>
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

/// Draws the pasteboard, the transparency checkerboard and the composited tiles.
public final class CanvasRenderer: @unchecked Sendable {
    public static let pixelFormat = MTLPixelFormat.rgba16Float

    public let context: MetalContext
    private let background: MTLRenderPipelineState
    private let present: MTLRenderPipelineState
    private let ants: MTLRenderPipelineState

    private let checkerLight = LinearColor.fromSRGB(1, 1, 1)
    private let checkerDark = LinearColor.fromSRGB(0.8, 0.8, 0.8)

    public init(context: MetalContext) throws {
        self.context = context
        let library = context.library

        let bg = MTLRenderPipelineDescriptor()
        bg.label = "Canvas background"
        bg.vertexFunction = library.makeFunction(name: "canvas_vertex")
        bg.fragmentFunction = library.makeFunction(name: "canvas_fragment")
        bg.colorAttachments[0].pixelFormat = Self.pixelFormat

        let tiles = MTLRenderPipelineDescriptor()
        tiles.label = "Canvas tiles"
        tiles.vertexFunction = library.makeFunction(name: "present_vertex")
        tiles.fragmentFunction = library.makeFunction(name: "present_fragment")
        let a = tiles.colorAttachments[0]!
        a.pixelFormat = Self.pixelFormat
        a.isBlendingEnabled = true
        a.sourceRGBBlendFactor = .one
        a.sourceAlphaBlendFactor = .one
        a.destinationRGBBlendFactor = .oneMinusSourceAlpha
        a.destinationAlphaBlendFactor = .oneMinusSourceAlpha

        let antsDesc = tiles.copy() as! MTLRenderPipelineDescriptor
        antsDesc.label = "Selection outline"
        antsDesc.fragmentFunction = library.makeFunction(name: "ants_fragment")

        for d in [bg, tiles, antsDesc] where d.vertexFunction == nil || d.fragmentFunction == nil {
            throw RenderError.libraryUnavailable("\(d.label ?? "canvas") shader functions missing")
        }
        self.background = try context.device.makeRenderPipelineState(descriptor: bg)
        self.present = try context.device.makeRenderPipelineState(descriptor: tiles)
        self.ants = try context.device.makeRenderPipelineState(descriptor: antsDesc)
    }

    public var device: MTLDevice { context.device }

    func uniforms(for frame: CanvasFrame) -> CanvasUniforms {
        let pointsPerPixel = 1 / frame.backingScale
        let pixelToPoint = simd_double3x3(diagonal: SIMD3(pointsPerPixel, pointsPerPixel, 1))
        let m = frame.transform.viewToDocumentMatrix * pixelToPoint
        let docPerPixel = simd_length(SIMD2(m.columns.0.x, m.columns.0.y))
        return CanvasUniforms(
            pixelToDocument: Self.float3x3(m),
            documentSize: SIMD2<Float>(Float(frame.documentSize.x), Float(frame.documentSize.y)),
            checkerSize: Float(frame.checkerSize * frame.backingScale),
            documentPerPixel: Float(docPerPixel),
            pasteboard: frame.pasteboardColor,
            checkerLight: checkerLight,
            checkerDark: checkerDark
        )
    }

    static func float3x3(_ m: simd_double3x3) -> simd_float3x3 {
        func f(_ c: SIMD3<Double>) -> SIMD3<Float> { SIMD3<Float>(Float(c.x), Float(c.y), Float(c.z)) }
        return simd_float3x3(columns: (f(m.columns.0), f(m.columns.1), f(m.columns.2)))
    }

    /// Encodes the canvas into `target` (must be `pixelFormat`).
    /// `tile` returns the composited texture for a coordinate, if any.
    public func encode(
        _ frame: CanvasFrame,
        tiles coords: [TileCoord] = [],
        tile: (TileCoord) -> MTLTexture? = { _ in nil },
        selection: Selection? = nil,
        time: Double = 0,
        channelMask: Int = 15,
        into commandBuffer: MTLCommandBuffer,
        target: MTLTexture
    ) {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .dontCare
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        encoder.label = "Canvas"

        var u = uniforms(for: frame)
        encoder.setRenderPipelineState(background)
        encoder.setFragmentBytes(&u, length: MemoryLayout<CanvasUniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)

        if !coords.isEmpty {
            // document → view points → clip space (y up).
            let pointsToClip = simd_double3x3(columns: (
                SIMD3(2 / frame.viewSize.x, 0, 0),
                SIMD3(0, -2 / frame.viewSize.y, 0),
                SIMD3(-1, 1, 1)
            ))
            let docToClip = Self.float3x3(pointsToClip * frame.transform.documentToViewMatrix)
            let docRect = PixelRect(x: 0, y: 0, width: Int(frame.documentSize.x), height: Int(frame.documentSize.y))
            let s = Float(TileGeometry.size)

            encoder.setRenderPipelineState(present)
            var channelIndex = Int32(channelMask)
            encoder.setFragmentBytes(&channelIndex, length: 4, index: 0)
            for coord in coords {
                guard let texture = tile(coord) else { continue }
                let r = coord.rect.intersection(docRect)  // never draw outside the document
                guard !r.isEmpty else { continue }
                let u0 = Float(r.x - coord.rect.x) / s, v0 = Float(r.y - coord.rect.y) / s
                var p = PresentUniforms(
                    documentToClip: docToClip,
                    documentRect: SIMD4(Float(r.x), Float(r.y), Float(r.width), Float(r.height)),
                    uvRect: SIMD4(u0, v0, u0 + Float(r.width) / s, v0 + Float(r.height) / s)
                )
                encoder.setVertexBytes(&p, length: MemoryLayout<PresentUniforms>.stride, index: 0)
                encoder.setFragmentTexture(texture, index: 0)
                encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            }

            // Marching ants on stored selection tiles (uniform areas have no edges).
            if let selection, !selection.tiles.isEmpty {
                encoder.setRenderPipelineState(ants)
                var t = Float(time.truncatingRemainder(dividingBy: 1000))
                encoder.setFragmentBytes(&t, length: 4, index: 0)
                for coord in coords {
                    guard case .texture(let tex)? = selection.tiles[coord] else { continue }
                    let r = coord.rect
                    var p = PresentUniforms(documentToClip: docToClip,
                                            documentRect: SIMD4(Float(r.x), Float(r.y), s, s),
                                            uvRect: SIMD4(0, 0, 1, 1))
                    encoder.setVertexBytes(&p, length: MemoryLayout<PresentUniforms>.stride, index: 0)
                    encoder.setFragmentTexture(tex.texture, index: 0)
                    encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
                }
            }
        }
        encoder.endEncoding()
    }
}
