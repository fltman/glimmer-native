import AppKit
import GlimmerCore
import GlimmerRender
import GlimmerTools
import QuartzCore
import SwiftUI
import simd

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
        case stroke
        case lasso
        case gradient
        case eyedropper
    }

    /// Brush size ring under the pointer.
    private let brushRing = CAShapeLayer()

    /// Dashed outline of the marquee being dragged (white under black dashes).
    private let marqueeBase = CAShapeLayer()
    private let marqueeDashes = CAShapeLayer()
    /// Boxes from Find Distractions and Magic Select click points.
    private let hintLayer = CAShapeLayer()
    private let pointsPositive = CAShapeLayer()
    private let pointsNegative = CAShapeLayer()
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
        hintLayer.fillColor = NSColor.systemOrange.withAlphaComponent(0.12).cgColor
        hintLayer.strokeColor = NSColor.systemOrange.cgColor
        hintLayer.lineWidth = 2
        hintLayer.lineDashPattern = [6, 3]
        for (layer, color) in [(pointsPositive, NSColor.systemGreen), (pointsNegative, NSColor.systemRed)] {
            layer.fillColor = color.cgColor
            layer.strokeColor = NSColor.white.cgColor
            layer.lineWidth = 2
        }
        brushRing.fillColor = nil
        brushRing.strokeColor = NSColor.white.cgColor
        brushRing.lineWidth = 1
        brushRing.shadowColor = NSColor.black.cgColor
        brushRing.shadowOpacity = 0.9
        brushRing.shadowRadius = 0.5
        brushRing.shadowOffset = .zero
        for layer in [hintLayer, pointsPositive, pointsNegative, brushRing] { layer.actions = ["path": NSNull()] }
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
        layer.addSublayer(hintLayer)
        layer.addSublayer(marqueeBase)
        layer.addSublayer(marqueeDashes)
        layer.addSublayer(pointsPositive)
        layer.addSublayer(pointsNegative)
        layer.addSublayer(brushRing)
        return layer
    }

    /// Re-renders and refreshes cursors whenever inputs the canvas draws change.
    private func observeSession() {
        withObservationTracking {
            _ = session.document.state
            _ = session.overrides
            _ = session.effectiveTool
            _ = session.marquee
            _ = session.ai.distractions
            _ = session.ai.magicPoints
            _ = session.lasso
            _ = session.gradientDrag
            _ = session.hoverPoint
            _ = session.brush.size
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
        updateHints()
        updateBrushRing()
        if let points = session.lasso, !points.isEmpty {
            let path = CGMutablePath()
            var all = points
            if session.effectiveTool == .polygonLasso, let hover = session.hoverPoint {
                all.append(controller.documentPoint(hover))
            }
            path.addLines(between: all.map { flipped(controller.transform.viewPoint(fromDocument: $0)) })
            marqueeBase.path = path
            marqueeDashes.path = path
            return
        }
        if let g = session.gradientDrag {
            let path = CGMutablePath()
            path.addLines(between: [g.start, g.end].map { flipped(controller.transform.viewPoint(fromDocument: $0)) })
            for p in [g.start, g.end] {
                let c = flipped(controller.transform.viewPoint(fromDocument: p))
                path.addEllipse(in: CGRect(x: c.x - 4, y: c.y - 4, width: 8, height: 8))
            }
            marqueeBase.path = path
            marqueeDashes.path = path
            return
        }
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

    private func flipped(_ v: SIMD2<Double>) -> CGPoint {
        CGPoint(x: v.x, y: bounds.height - v.y)
    }

    private func updateBrushRing() {
        let tool = session.effectiveTool
        guard tool == .brush || tool == .eraser, let hover = session.hoverPoint else {
            brushRing.path = nil
            return
        }
        let r = max(session.brush.size * controller.transform.scale / 2, 1)
        let c = flipped(hover)
        let path = CGMutablePath()
        path.addEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
        if r < 4 {
            path.move(to: CGPoint(x: c.x - 6, y: c.y)); path.addLine(to: CGPoint(x: c.x + 6, y: c.y))
            path.move(to: CGPoint(x: c.x, y: c.y - 6)); path.addLine(to: CGPoint(x: c.x, y: c.y + 6))
        }
        brushRing.path = path
    }

    private func updateHints() {
        // Document → layer coordinates (the Metal layer isn't flipped).
        let t = controller.transform
        func point(_ d: SIMD2<Double>) -> CGPoint {
            let v = t.viewPoint(fromDocument: d)
            return CGPoint(x: v.x, y: bounds.height - v.y)
        }
        let boxes = CGMutablePath()
        let state = session.state
        for d in session.ai.distractions {
            let r = d.pixelRect(width: state.width, height: state.height)
            let corners = [SIMD2(Double(r.x), Double(r.y)), SIMD2(Double(r.maxX), Double(r.y)),
                           SIMD2(Double(r.maxX), Double(r.maxY)), SIMD2(Double(r.x), Double(r.maxY))]
            boxes.addLines(between: corners.map(point))
            boxes.closeSubpath()
        }
        hintLayer.path = boxes
        let positive = CGMutablePath(), negative = CGMutablePath()
        for p in session.ai.magicPoints {
            let c = point(p.location)
            (p.positive ? positive : negative).addEllipse(in: CGRect(x: c.x - 5, y: c.y - 5, width: 10, height: 10))
        }
        pointsPositive.path = positive
        pointsNegative.path = negative
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
        case .magicSelect:
            // Click adds a point on the object; ⌥-click marks what to leave out.
            session.ai.magicSelect(at: controller.documentPoint(p), positive: !event.modifierFlags.contains(.option))
        case .brush, .eraser:
            session.beginStroke(at: controller.documentPoint(p), pressure: pressure(event),
                                erase: session.effectiveTool == .eraser, straightLine: event.modifierFlags.contains(.shift))
            drag = .stroke
        case .lasso:
            session.beginLasso(at: controller.documentPoint(p), modifiers: event.modifierFlags)
            drag = .lasso
        case .polygonLasso:
            session.polygonClick(at: controller.documentPoint(p), modifiers: event.modifierFlags,
                                 doubleClick: event.clickCount == 2)
        case .magicWand:
            session.magicWand(at: controller.documentPoint(p), modifiers: event.modifierFlags)
        case .paintBucket:
            session.paintBucket(at: controller.documentPoint(p))
        case .gradient:
            let d = controller.documentPoint(p)
            session.gradientDrag = (d, d)
            drag = .gradient
        case .eyedropper:
            session.sampleColor(at: controller.documentPoint(p), intoBackground: event.modifierFlags.contains(.option))
            drag = .eyedropper
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
        case .stroke:
            session.continueStroke(to: controller.documentPoint(p), pressure: pressure(event))
            session.hoverPoint = p
        case .lasso:
            session.extendLasso(to: controller.documentPoint(p))
        case .gradient:
            guard let g = session.gradientDrag else { break }
            var d = controller.documentPoint(p)
            if event.modifierFlags.contains(.shift) {
                // Constrain to 45° steps.
                let v = d - g.start
                let a = (atan2(v.y, v.x) / (.pi / 4)).rounded() * (.pi / 4)
                let len = simd_length(v)
                d = g.start + SIMD2(cos(a), sin(a)) * len
            }
            session.gradientDrag = (g.start, d)
        case .eyedropper:
            session.sampleColor(at: controller.documentPoint(p), intoBackground: event.modifierFlags.contains(.option))
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
        switch drag {
        case .move: session.endMove()
        case .marquee: session.endMarquee()
        case .stroke: session.endStroke(at: controller.documentPoint(location(of: event)))
        case .lasso: session.finishLasso()
        case .gradient: session.finishGradient()
        default: break
        }
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

    private func pressure(_ event: NSEvent) -> Double {
        event.subtype == .tabletPoint ? Double(max(event.pressure, 0.01)) : 1
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                       owner: self))
    }

    override func mouseMoved(with event: NSEvent) {
        session.hoverPoint = location(of: event)
    }

    override func mouseExited(with event: NSEvent) {
        session.hoverPoint = nil
    }

    override func tabletPoint(with event: NSEvent) {
        mouseDragged(with: event)
    }

    override func resetCursorRects() {
        let cursor: NSCursor = switch session.effectiveTool {
        case .hand: .openHand
        case .rectangleMarquee, .ellipseMarquee, .magicSelect, .lasso, .polygonLasso, .magicWand,
             .brush, .eraser, .gradient, .eyedropper, .paintBucket: .crosshair
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
            if key == "l" {
                session.tool = session.tool == .lasso ? .polygonLasso : .lasso
                return
            }
            switch key {
            case "x": session.swapColors(); return
            case "d": session.resetColors(); return
            case "[": session.adjustBrushSize(by: 0.9); return
            case "]": session.adjustBrushSize(by: 1.1); return
            default: break
            }
            if let tool = ToolID.allCases.first(where: { $0.shortcutKey == key && Self.availableTools.contains($0) }) {
                session.tool = tool
                return
            }
        }
        if event.keyCode == 53 || event.keyCode == 36, session.effectiveTool == .magicSelect, !session.ai.magicPoints.isEmpty {
            // Return keeps the Magic Select result, Esc discards it.
            if event.keyCode == 53 { session.perform(.deselect) }
            session.ai.resetMagicSelect()
            return
        }
        if session.lasso != nil, event.keyCode == 36 || event.keyCode == 76 || event.keyCode == 53 {
            event.keyCode == 53 ? session.cancelLasso() : session.finishLasso()
            return
        }
        if event.keyCode == 51 || event.keyCode == 117, session.canPerform(.clearPixels) {  // ⌫ / ⌦
            session.perform(.clearPixels)
            return
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
    static let availableTools: [ToolID] = [.move, .rectangleMarquee, .ellipseMarquee, .lasso, .polygonLasso, .magicWand,
                                           .magicSelect, .brush, .eraser, .paintBucket, .gradient, .eyedropper, .hand]

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
        if !session.paste() { NSSound.beep() }
    }

    @objc func copy(_ sender: Any?) { session.perform(.copy) }
    @objc func cut(_ sender: Any?) { session.perform(.cut) }
    @objc func delete(_ sender: Any?) { session.perform(.clearPixels) }

    func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(copy(_:)) { return session.canPerform(.copy) }
        if item.action == #selector(cut(_:)) { return session.canPerform(.cut) }
        if item.action == #selector(delete(_:)) { return session.canPerform(.clearPixels) }
        if item.action == #selector(paste(_:)) {
            if session.clipboard?.changeCount == NSPasteboard.general.changeCount { return true }
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
