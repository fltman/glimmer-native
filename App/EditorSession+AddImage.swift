import AppKit
import GlimmerAI
import GlimmerCore
import GlimmerRender

extension EditorSession {
    /// Adds `image` as a new layer above the active one, fitted to the canvas (an agent's
    /// `add_image`). One undo step of its own. Returns the new layer.
    @discardableResult
    func addImageLayer(_ image: CGImage, name: String, fit: CanvasSteps.Fit, x: Double?, y: Double?, smartObject: Bool) throws -> Layer {
        guard let metal else { throw RenderError.noMetalDevice }
        commitLiveEdit()
        let p = CanvasSteps.placement(image: (image.width, image.height), canvas: (state.width, state.height), fit: fit, x: x, y: y)
        let scale = p.width / Double(image.width)
        let content: LayerContent
        if smartObject {
            let source = try ImageImporter.tiles(from: image, origin: .zero)
            content = .smart(SmartObject(source: source, width: image.width, height: image.height,
                                         transform: GlimmerCore.AffineTransform(a: scale, d: scale, tx: p.x, ty: p.y)))
        } else if abs(scale - 1) < 1e-9 {
            content = .raster(try ImageImporter.tiles(from: image, origin: SIMD2(Int(p.x.rounded()), Int(p.y.rounded()))))
        } else {
            let source = try ImageImporter.tiles(from: image, origin: .zero)
            let smart = SmartObject(source: source, width: image.width, height: image.height,
                                    transform: GlimmerCore.AffineTransform(a: scale, d: scale, tx: p.x, ty: p.y))
            content = .raster(try SmartObjectRenderer(context: metal).render(smart, limit: smart.bounds))
        }
        let layer = Layer(name: name, content: content)
        document.edit(stepName("Add Image"), undoManager: undoManager, separateStep: true) { $0.insertLayerAboveActive(layer) }
        return layer
    }
}
