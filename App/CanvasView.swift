import AppKit
import GlimmerCore
import GlimmerRender
import GlimmerTools
import QuartzCore
import SwiftUI

struct CanvasView: NSViewRepresentable {
    let session: EditorSession

    func makeNSView(context: Context) -> CanvasNSView {
        CanvasNSView(session: session)
    }

    func updateNSView(_ view: CanvasNSView, context: Context) {}
}

/// Hosts the Metal canvas and turns mouse, trackpad and keyboard input into
/// view changes and tool actions.
final class CanvasNSView: NSView, NSUserInterfaceValidations {
    private let session: EditorSession
    private var controller: CanvasController { session.canvas }
    private let renderer: CanvasRenderer?
    private let compositor: DocumentCompositor?
    private var displayLink: CADisplayLink?
    private var needsRender = true

    private enum Drag {
        case pan(last: SIMD2<Double>)
        case move
        case marquee
    }

    /// Dashed outline of the marquee being dragged (white under black dashes).
    private let marqueeBase = CAShapeLayer()
    private let marqueeDashes = CAShapeLayer()
    private var drag: Drag?

    init(session: EditorSession) {
        self.session = session
        let metal = MetalContext.shared
        self.renderer = metal.flatMap { try? CanvasRenderer(context: $0) }
        self.compositor = metal.flatMap { try? DocumentCompositor(context: $0) }
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        registerForDraggedTypes([.fileURL, .png, .tiff])
        controller.onNeedsRender = { [weak self] in
            self?.setNeedsRender()
            self?.updateMarqueeOverlay()
        }
        for (layer, color) in [(marqueeBase, NSColor.white), (marqueeDashes, NSColor.black)] {
            layer.fillColor = nil
            layer.strokeColor = color.cgColor
            layer.lineWidth = 1
            layer.actions = ["path": NSNull()]
        }
        marqueeDashes.lineDashPattern = [4, 4]
        observeSession()
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
        layer.addSublayer(marqueeBase)
        layer.addSublayer(marqueeDashes)
        return layer
    }

    /// Re-renders and refreshes cursors whenever inputs the canvas draws change.
    private func observeSession() {
        withObservationTracking {
            _ = session.document.state
            _ = session.overrides
            _ = session.effectiveTool
            _ = session.marquee
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.setNeedsRender()
                self.updateMarqueeOverlay()
                self.window?.invalidateCursorRects(for: self)
                self.observeSession()
            }
        }
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
        // Marching ants animate while there is a selection.
        let animating = session.state.selection.map { !$0.tiles.isEmpty } ?? false
        guard needsRender || animating else {
            link.isPaused = true
            return
        }
        needsRender = false
        draw()
        if animating { link.isPaused = false }
    }

    private func updateMarqueeOverlay() {
        guard let m = session.marquee else {
            marqueeBase.path = nil
            marqueeDashes.path = nil
            return
        }
        let r = m.rect
        let corners = [SIMD2(r.minX, r.minY), SIMD2(r.maxX, r.minY), SIMD2(r.maxX, r.maxY), SIMD2(r.minX, r.maxY)]
            .map { controller.transform.viewPoint(fromDocument: $0) }
        let path = CGMutablePath()
        if m.ellipse {
            // An ellipse in document space, mapped through the (possibly rotated) view.
            let t = controller.transform
            let c = SIMD2((r.minX + r.maxX) / 2, (r.minY + r.maxY) / 2)
            for i in 0...64 {
                let a = Double(i) / 64 * 2 * .pi
                let p = t.viewPoint(fromDocument: c + SIMD2(cos(a) * r.width / 2, sin(a) * r.height / 2))
                i == 0 ? path.move(to: CGPoint(x: p.x, y: p.y)) : path.addLine(to: CGPoint(x: p.x, y: p.y))
            }
        } else {
            path.addLines(between: corners.map { CGPoint(x: $0.x, y: $0.y) })
            path.closeSubpath()
        }
        // The Metal layer isn't flipped: convert from view (y-down) coordinates.
        var flip = CGAffineTransform(translationX: 0, y: bounds.height).scaledBy(x: 1, y: -1)
        let flipped = path.copy(using: &flip)
        marqueeBase.path = flipped
        marqueeDashes.path = flipped
    }

    private func draw() {
        guard let renderer, let compositor, let metalLayer, bounds.width > 0, bounds.height > 0,
              let drawable = metalLayer.nextDrawable(),
              let commandBuffer = renderer.context.commandQueue.makeCommandBuffer() else { return }
        let state = session.document.state
        let tiles = controller.visibleTiles(in: state.bounds)
        compositor.purge(outside: state.bounds)
        // Composite progressively so huge documents stay responsive.
        let more = compositor.update(state, overrides: session.overrides, coords: tiles,
                                     budget: 96, commandBuffer: commandBuffer)
        let frame = CanvasFrame(
            transform: controller.transform,
            viewSize: SIMD2(bounds.width, bounds.height),
            backingScale: Double(metalLayer.contentsScale),
            documentSize: state.size,
            pasteboardColor: pasteboardColor()
        )
        renderer.encode(frame, tiles: tiles, tile: compositor.texture(at:), selection: state.selection,
                        time: CACurrentMediaTime(), into: commandBuffer, target: drawable.texture)
        commandBuffer.present(drawable)
        commandBuffer.commit()
        if more { setNeedsRender() }
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

    // MARK: Pointer input

    private func location(of event: NSEvent) -> SIMD2<Double> {
        let p = convert(event.locationInWindow, from: nil)
        return SIMD2(p.x, p.y)
    }

    override func scrollWheel(with event: NSEvent) {
        let zoomModifier = !event.modifierFlags.isDisjoint(with: [.option, .command])
        if event.hasPreciseScrollingDeltas, !zoomModifier {
            controller.pan(by: SIMD2(event.scrollingDeltaX, event.scrollingDeltaY))
        } else {
            let step = event.hasPreciseScrollingDeltas ? 0.01 : 0.1
            controller.zoom(by: exp(event.scrollingDeltaY * step), around: location(of: event))
        }
    }

    override func magnify(with event: NSEvent) {
        controller.zoom(by: 1 + event.magnification, around: location(of: event))
    }

    override func rotate(with event: NSEvent) {
        if event.phase == .began { controller.beginRotationGesture() }
        controller.rotateGesture(by: -Double(event.rotation) * .pi / 180, around: location(of: event))
    }

    override func smartMagnify(with event: NSEvent) {
        controller.toggleFitAndActualSize(around: location(of: event))
    }

    override func mouseDown(with event: NSEvent) {
        let p = location(of: event)
        switch session.effectiveTool {
        case .move:
            session.beginMove(at: controller.documentPoint(p))
            drag = .move
        case .rectangleMarquee, .ellipseMarquee:
            session.beginMarquee(at: controller.documentPoint(p), modifiers: event.modifierFlags)
            drag = .marquee
        default:
            beginPan(at: p)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let p = location(of: event)
        switch drag {
        case .pan(let last):
            controller.pan(by: p - last)
            drag = .pan(last: p)
        case .move:
            session.updateMove(to: controller.documentPoint(p))
        case .marquee:
            var d = controller.documentPoint(p)
            if event.modifierFlags.contains(.shift), let m = session.marquee, m.operation == .replace {
                // Shift constrains to a square / circle.
                let v = d - m.start
                let side = max(abs(v.x), abs(v.y))
                d = m.start + SIMD2(v.x < 0 ? -side : side, v.y < 0 ? -side : side)
            }
            session.updateMarquee(to: d)
        case nil:
            break
        }
    }

    override func mouseUp(with event: NSEvent) {
        if case .move = drag { session.endMove() }
        if case .marquee = drag { session.endMarquee() }
        endDrag()
    }

    override func otherMouseDown(with event: NSEvent) { beginPan(at: location(of: event)) }
    override func otherMouseDragged(with event: NSEvent) { mouseDragged(with: event) }
    override func otherMouseUp(with event: NSEvent) { endDrag() }

    private func beginPan(at p: SIMD2<Double>) {
        drag = .pan(last: p)
        NSCursor.closedHand.push()
    }

    private func endDrag() {
        if case .pan = drag { NSCursor.pop() }
        drag = nil
    }

    override func resetCursorRects() {
        let cursor: NSCursor = switch session.effectiveTool {
        case .hand: .openHand
        case .rectangleMarquee, .ellipseMarquee: .crosshair
        default: .arrow
        }
        addCursorRect(bounds, cursor: cursor)
    }

    // MARK: Keyboard

    override func keyDown(with event: NSEvent) {
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if event.keyCode == 49 {  // space
            if !event.isARepeat { session.temporaryHand = true }
            return
        }
        if session.effectiveTool == .move, let arrow = arrowOffset(event) {
            session.nudgeActiveLayer(by: mods.contains(.shift) ? arrow &* 10 : arrow)
            return
        }
        if mods.isDisjoint(with: [.command, .control, .option]),
           let key = event.charactersIgnoringModifiers?.lowercased().first {
            if key == "m" {
                // M toggles between the rectangular and elliptical marquee.
                session.tool = session.tool == .rectangleMarquee ? .ellipseMarquee : .rectangleMarquee
                return
            }
            if let tool = ToolID.allCases.first(where: { $0.shortcutKey == key && Self.availableTools.contains($0) }) {
                session.tool = tool
                return
            }
        }
        if event.keyCode == 53, session.state.selection != nil {  // Esc deselects
            session.perform(.deselect)
            return
        }
        super.keyDown(with: event)
    }

    override func keyUp(with event: NSEvent) {
        if event.keyCode == 49 {
            session.temporaryHand = false
            return
        }
        super.keyUp(with: event)
    }

    /// Tools implemented so far (see docs/PLAN.md for the rest).
    static let availableTools: [ToolID] = [.move, .rectangleMarquee, .ellipseMarquee, .hand]

    private func arrowOffset(_ event: NSEvent) -> SIMD2<Int>? {
        switch event.keyCode {
        case 123: SIMD2(-1, 0)
        case 124: SIMD2(1, 0)
        case 125: SIMD2(0, 1)
        case 126: SIMD2(0, -1)
        default: nil
        }
    }

    // MARK: Paste and drop

    @objc override func selectAll(_ sender: Any?) {
        session.perform(.selectAll)
    }

    @objc func paste(_ sender: Any?) {
        if !session.place(from: .general) { NSSound.beep() }
    }

    func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(paste(_:)) {
            let pb = NSPasteboard.general
            return pb.canReadObject(forClasses: [NSURL.self], options: [
                .urlReadingContentsConformToTypes: [UTType.image.identifier],
            ]) || pb.availableType(from: [.png, .tiff]) != nil
        }
        return true
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        canAccept(sender.draggingPasteboard) ? .copy : []
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        session.place(from: sender.draggingPasteboard)
    }

    private func canAccept(_ pb: NSPasteboard) -> Bool {
        pb.canReadObject(forClasses: [NSURL.self], options: [
            .urlReadingContentsConformToTypes: [UTType.image.identifier],
        ]) || pb.availableType(from: [.png, .tiff]) != nil
    }
}

import UniformTypeIdentifiers
