import AppKit
import GlimmerCore
import GlimmerRender
import QuartzCore
import SwiftUI

struct CanvasView: NSViewRepresentable {
    let controller: CanvasController

    func makeNSView(context: Context) -> CanvasNSView {
        CanvasNSView(controller: controller)
    }

    func updateNSView(_ view: CanvasNSView, context: Context) {}
}

/// Hosts the Metal canvas and turns mouse, trackpad and (later) tablet input
/// into view and tool actions.
final class CanvasNSView: NSView {
    private let controller: CanvasController
    private let renderer: CanvasRenderer?
    private var displayLink: CADisplayLink?
    private var needsRender = true
    private var lastDragPoint: SIMD2<Double>?

    init(controller: CanvasController) {
        self.controller = controller
        self.renderer = MetalContext.shared.flatMap { try? CanvasRenderer(context: $0) }
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        controller.onNeedsRender = { [weak self] in self?.setNeedsRender() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private var metalLayer: CAMetalLayer? { layer as? CAMetalLayer }

    override func makeBackingLayer() -> CALayer {
        let layer = CAMetalLayer()
        layer.device = renderer?.device
        layer.pixelFormat = CanvasRenderer.pixelFormat
        layer.colorspace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)
        layer.framebufferOnly = true
        layer.isOpaque = true
        return layer
    }

    // MARK: Lifecycle

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        displayLink?.invalidate()
        displayLink = nil
        guard window != nil else { return }
        let link = displayLink(target: self, selector: #selector(step(_:)))
        link.add(to: .main, forMode: .common)
        displayLink = link
        updateBackingScale()
        window?.makeFirstResponder(self)
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateBackingScale()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        setNeedsRender()
    }

    override func layout() {
        super.layout()
        updateDrawableSize()
        controller.viewDidResize(to: SIMD2(bounds.width, bounds.height))
        setNeedsRender()
    }

    private func updateBackingScale() {
        let scale = window?.backingScaleFactor ?? 2
        metalLayer?.contentsScale = scale
        controller.backingScale = scale
        updateDrawableSize()
    }

    private func updateDrawableSize() {
        let scale = metalLayer?.contentsScale ?? 2
        metalLayer?.drawableSize = CGSize(width: max(1, bounds.width * scale),
                                          height: max(1, bounds.height * scale))
    }

    // MARK: Rendering

    func setNeedsRender() {
        needsRender = true
        displayLink?.isPaused = false
    }

    @objc private func step(_ link: CADisplayLink) {
        guard needsRender else {
            link.isPaused = true
            return
        }
        needsRender = false
        draw()
    }

    private func draw() {
        guard let renderer, let metalLayer, bounds.width > 0, bounds.height > 0,
              let drawable = metalLayer.nextDrawable() else { return }
        let frame = CanvasFrame(
            viewToDocument: controller.transform.viewToDocumentMatrix,
            backingScale: Double(metalLayer.contentsScale),
            documentSize: controller.documentSize,
            pasteboardColor: pasteboardColor()
        )
        renderer.render(frame, to: drawable)
    }

    private func pasteboardColor() -> SIMD4<Float> {
        var color = SIMD4<Float>(0.05, 0.05, 0.05, 1)
        effectiveAppearance.performAsCurrentDrawingAppearance {
            if let c = NSColor.underPageBackgroundColor.usingColorSpace(.sRGB) {
                color = LinearColor.fromSRGB(c.redComponent, c.greenComponent, c.blueComponent)
            }
        }
        return color
    }

    // MARK: Input

    private func location(of event: NSEvent) -> SIMD2<Double> {
        let p = convert(event.locationInWindow, from: nil)
        return SIMD2(p.x, p.y)
    }

    override func scrollWheel(with event: NSEvent) {
        let zoomModifier = !event.modifierFlags.isDisjoint(with: [.option, .command])
        if event.hasPreciseScrollingDeltas, !zoomModifier {
            // Trackpad / Magic Mouse: two-finger scroll pans.
            controller.pan(by: SIMD2(event.scrollingDeltaX, event.scrollingDeltaY))
        } else {
            // Mouse wheel, or ⌥/⌘-scroll: zoom around the cursor.
            let step = event.hasPreciseScrollingDeltas ? 0.01 : 0.1
            controller.zoom(by: exp(event.scrollingDeltaY * step), around: location(of: event))
        }
    }

    override func magnify(with event: NSEvent) {
        controller.zoom(by: 1 + event.magnification, around: location(of: event))
    }

    override func rotate(with event: NSEvent) {
        if event.phase == .began { controller.beginRotationGesture() }
        // AppKit reports counter-clockwise degrees; the view transform is clockwise.
        controller.rotateGesture(by: -Double(event.rotation) * .pi / 180, around: location(of: event))
    }

    override func smartMagnify(with event: NSEvent) {
        controller.toggleFitAndActualSize(around: location(of: event))
    }

    // Phase 0 has no tools yet: any drag pans (the Hand tool).
    override func mouseDown(with event: NSEvent) { beginPan(event) }
    override func mouseDragged(with event: NSEvent) { continuePan(event) }
    override func mouseUp(with event: NSEvent) { endPan() }
    override func otherMouseDown(with event: NSEvent) { beginPan(event) }
    override func otherMouseDragged(with event: NSEvent) { continuePan(event) }
    override func otherMouseUp(with event: NSEvent) { endPan() }

    private func beginPan(_ event: NSEvent) {
        lastDragPoint = location(of: event)
        NSCursor.closedHand.push()
    }

    private func continuePan(_ event: NSEvent) {
        let p = location(of: event)
        if let last = lastDragPoint { controller.pan(by: p - last) }
        lastDragPoint = p
    }

    private func endPan() {
        if lastDragPoint != nil { NSCursor.pop() }
        lastDragPoint = nil
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .openHand)
    }
}
