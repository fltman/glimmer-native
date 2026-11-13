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
        case transform
        case crop
        case pen
        case shape
        case guide
    }

    /// Transform box, crop frame, pen paths and their handles.
    private let chromeLines = CAShapeLayer()
    private let chromeHandles = CAShapeLayer()
    private let cropShade = CAShapeLayer()
    private let guideLayer = CAShapeLayer()
    private let gridLayer = CAShapeLayer()
    private var textEditor: NSTextView?
    private var editorLayerID: UUID?
    private lazy var rulers: RulerView = {
        let v = RulerView(frame: bounds)
        v.autoresizingMask = [.width, .height]
        v.transform = { [weak self] in self?.controller.transform }
        return v
    }()

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
        chromeLines.fillColor = nil
        chromeLines.strokeColor = NSColor.controlAccentColor.cgColor
        chromeLines.lineWidth = 1
        chromeHandles.fillColor = NSColor.white.cgColor
        chromeHandles.strokeColor = NSColor.controlAccentColor.cgColor
        chromeHandles.lineWidth = 1
        cropShade.fillColor = NSColor.black.withAlphaComponent(0.5).cgColor
        cropShade.fillRule = .evenOdd
        guideLayer.strokeColor = NSColor.systemCyan.cgColor
        guideLayer.lineWidth = 1
        gridLayer.strokeColor = NSColor.gray.withAlphaComponent(0.45).cgColor
        gridLayer.lineWidth = 0.5
        for layer in [hintLayer, pointsPositive, pointsNegative, brushRing, chromeLines, chromeHandles, cropShade, guideLayer, gridLayer] {
            layer.actions = ["path": NSNull()]
        }
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
        layer.addSublayer(gridLayer)
        layer.addSublayer(guideLayer)
        layer.addSublayer(cropShade)
        layer.addSublayer(hintLayer)
        layer.addSublayer(chromeLines)
        layer.addSublayer(chromeHandles)
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
            _ = session.transformSession?.box
            _ = session.cropSession
            _ = session.activePathID
            _ = session.shapeDrag
            _ = session.guideDrag
            _ = session.editingText
            _ = session.tool
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
        if rulers.superview != nil { rulers.frame = bounds }
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
        updateToolChrome()
        updateTextEditor()
        if let d = session.shapeDrag {
            let r = CGRectLike(x0: d.start.x, y0: d.start.y, x1: d.end.x, y1: d.end.y)
            let path = CGMutablePath()
            let t = controller.transform
            switch session.shapeKind {
            case .line:
                path.addLines(between: [d.start, d.end].map { flipped(t.viewPoint(fromDocument: $0)) })
            case .ellipse:
                let c = SIMD2((r.minX + r.maxX) / 2, (r.minY + r.maxY) / 2)
                let pts = (0...48).map { i -> CGPoint in
                    let a = Double(i) / 48 * 2 * .pi
                    return flipped(t.viewPoint(fromDocument: c + SIMD2(cos(a) * r.width / 2, sin(a) * r.height / 2)))
                }
                path.addLines(between: pts)
            case .rectangle:
                let pts = [SIMD2(r.minX, r.minY), SIMD2(r.maxX, r.minY), SIMD2(r.maxX, r.maxY), SIMD2(r.minX, r.maxY), SIMD2(r.minX, r.minY)]
                path.addLines(between: pts.map { flipped(t.viewPoint(fromDocument: $0)) })
            }
            marqueeBase.path = path
            marqueeDashes.path = path
            return
        }
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

    private func handleSquares(_ points: [SIMD2<Double>], into path: CGMutablePath, size: Double = 7) {
        for p in points {
            let c = flipped(controller.transform.viewPoint(fromDocument: p))
            path.addRect(CGRect(x: c.x - size / 2, y: c.y - size / 2, width: size, height: size))
        }
    }

    private func updateToolChrome() {
        let t = controller.transform
        let showRulers = session.state.aids.rulersVisible
        if showRulers, rulers.superview == nil { rulers.frame = bounds; addSubview(rulers) } else if !showRulers, rulers.superview != nil { rulers.removeFromSuperview() }
        if showRulers { rulers.needsDisplay = true }
        func v(_ d: SIMD2<Double>) -> CGPoint { flipped(t.viewPoint(fromDocument: d)) }
        let lines = CGMutablePath(), handles = CGMutablePath()
        cropShade.path = nil

        if let ts = session.transformSession {
            let corners = ts.box.corners
            lines.addLines(between: (corners + [corners[0]]).map(v))
            handleSquares(corners + ts.box.edges, into: handles)
        }
        if let c = session.cropSession {
            let r = c.rect
            let doc = PixelRect(x: 0, y: 0, width: session.state.width, height: session.state.height)
            let outer = CGMutablePath()
            let big = [SIMD2(Double(doc.x) - 1e5, Double(doc.y) - 1e5), SIMD2(1e5, Double(doc.y) - 1e5),
                       SIMD2(1e5, 1e5), SIMD2(Double(doc.x) - 1e5, 1e5)]
            outer.addLines(between: big.map(v)); outer.closeSubpath()
            let rc = [SIMD2(r.minX, r.minY), SIMD2(r.maxX, r.minY), SIMD2(r.maxX, r.maxY), SIMD2(r.minX, r.maxY)]
            outer.addLines(between: rc.map(v)); outer.closeSubpath()
            cropShade.path = outer
            lines.addLines(between: (rc + [rc[0]]).map(v))
            for i in 1...2 {  // rule of thirds
                let fx = r.minX + r.width * Double(i) / 3, fy = r.minY + r.height * Double(i) / 3
                lines.move(to: v(SIMD2(fx, r.minY))); lines.addLine(to: v(SIMD2(fx, r.maxY)))
                lines.move(to: v(SIMD2(r.minX, fy))); lines.addLine(to: v(SIMD2(r.maxX, fy)))
            }
            handleSquares(session.cropHandles(r), into: handles)
        }
        if session.effectiveTool == .pen || session.activePathID != nil, let path = session.activePath {
            for sub in path.subpaths where !sub.anchors.isEmpty {
                let poly = VectorPath(name: "", subpaths: [sub]).polygons()[0]
                lines.addLines(between: poly.map(v))
                if session.effectiveTool == .pen {
                    for a in sub.anchors {
                        if a.handleIn != a.point { lines.move(to: v(a.handleIn)); lines.addLine(to: v(a.point)) }
                        if a.handleOut != a.point { lines.move(to: v(a.point)); lines.addLine(to: v(a.handleOut)) }
                        handleSquares([a.point], into: handles, size: 6)
                        handleSquares([a.handleIn, a.handleOut].filter { $0 != a.point }, into: handles, size: 4)
                    }
                }
            }
        }
        chromeLines.path = lines
        chromeHandles.path = handles

        // Guides and grid.
        let aids = session.state.aids
        let guides = CGMutablePath()
        let viewRect = t.visibleDocumentRect(viewSize: SIMD2(bounds.width, bounds.height))
        for g in aids.guides {
            if g.axis == .vertical {
                guides.move(to: v(SIMD2(g.position, Double(viewRect.y)))); guides.addLine(to: v(SIMD2(g.position, Double(viewRect.maxY))))
            } else {
                guides.move(to: v(SIMD2(Double(viewRect.x), g.position))); guides.addLine(to: v(SIMD2(Double(viewRect.maxX), g.position)))
            }
        }
        if let g = session.guideDrag {
            if g.axis == .vertical {
                guides.move(to: v(SIMD2(g.position, Double(viewRect.y)))); guides.addLine(to: v(SIMD2(g.position, Double(viewRect.maxY))))
            } else {
                guides.move(to: v(SIMD2(Double(viewRect.x), g.position))); guides.addLine(to: v(SIMD2(Double(viewRect.maxX), g.position)))
            }
        }
        guideLayer.path = guides
        let grid = CGMutablePath()
        if aids.grid.isVisible, aids.grid.spacing * t.scale >= 6 {
            let s = aids.grid.spacing
            let w = Double(session.state.width), h = Double(session.state.height)
            var x = 0.0
            while x <= w { grid.move(to: v(SIMD2(x, 0))); grid.addLine(to: v(SIMD2(x, h))); x += s }
            var y = 0.0
            while y <= h { grid.move(to: v(SIMD2(0, y))); grid.addLine(to: v(SIMD2(w, y))); y += s }
        }
        gridLayer.path = grid
    }

    // MARK: Text editing

    private func updateTextEditor() {
        // Commit the open editor when editing ended (Esc, a click elsewhere, a tool change).
        if session.editingText != nil, session.effectiveTool != .type { session.editingText = nil }
        if let editor = textEditor, let id = editorLayerID, session.editingText != id {
            textEditor = nil
            editorLayerID = nil
            let string = editor.string
            editor.removeFromSuperview()
            session.overrides = .none
            session.commitText(string, id: id)
            window?.makeFirstResponder(self)
        }
        guard let id = session.editingText, let layer = session.state.layer(id: id), case .text(let text) = layer.content else {
            return
        }
        let scale = controller.transform.scale
        let v = controller.transform.viewPoint(fromDocument: text.origin)
        let origin = CGPoint(x: v.x, y: v.y)  // subview frames use the (flipped) view space
        let font = NSFont(name: text.fontName, size: text.size * scale) ?? .systemFont(ofSize: text.size * scale)
        let editor: NSTextView
        if let existing = textEditor {
            editor = existing
        } else {
            editor = NSTextView(frame: .zero)
            editor.drawsBackground = false
            editor.isRichText = false
            editor.allowsUndo = true
            editor.textContainerInset = .zero
            editor.textContainer?.lineFragmentPadding = 0
            editor.string = text.string
            editor.delegate = self
            addSubview(editor)
            textEditor = editor
            editorLayerID = id
            window?.makeFirstResponder(editor)
            editor.selectAll(nil)
            // Hide the layer's own pixels while editing.
            session.overrides = LayerOverrides(pixels: [id: TileGrid()])
        }
        editor.font = font
        editor.textColor = NSColor(srgbRed: text.color.r, green: text.color.g, blue: text.color.b, alpha: 1)
        editor.alignment = text.alignment == .center ? .center : (text.alignment == .right ? .right : .left)
        if let box = text.boxWidth {
            editor.isHorizontallyResizable = false
            editor.textContainer?.widthTracksTextView = true
            editor.frame = CGRect(x: origin.x, y: origin.y, width: box * scale, height: editor.frame.height)
        } else {
            editor.isHorizontallyResizable = true
            editor.textContainer?.widthTracksTextView = false
            editor.textContainer?.containerSize = CGSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
            editor.frame.origin = origin
        }
        fitEditor()
    }

    fileprivate func fitEditor() {
        guard let editor = textEditor, let font = editor.font, let lm = editor.layoutManager, let tc = editor.textContainer else { return }
        lm.ensureLayout(for: tc)
        let used = lm.usedRect(for: tc)
        let width = editor.isHorizontallyResizable ? max(used.width + font.pointSize, font.pointSize * 2) : editor.frame.width
        editor.frame.size = CGSize(width: width, height: max(used.height, font.pointSize * 1.3) + 4)
    }

    /// Ends text editing (Esc / ⌘⏎ / clicking elsewhere).
    func endTextEditing() {
        guard session.editingText != nil else { return }
        session.editingText = nil
        updateTextEditor()
    }

    private func flipped(_ v: SIMD2<Double>) -> CGPoint {
        layer?.isGeometryFlipped == true ? CGPoint(x: v.x, y: v.y) : CGPoint(x: v.x, y: bounds.height - v.y)
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
        let t = controller.transform
        func point(_ d: SIMD2<Double>) -> CGPoint { flipped(t.viewPoint(fromDocument: d)) }
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
        if session.editingText != nil, session.effectiveTool != .type { endTextEditing() }
        // Rulers: drag out a guide. Existing guides: drag with the move tool (off-canvas deletes).
        if session.state.aids.rulersVisible, p.y < 18 || p.x < 18 {
            let d = controller.documentPoint(p)
            session.guideDrag = p.y < 18 ? (nil, .horizontal, d.y) : (nil, .vertical, d.x)
            drag = .guide
            return
        }
        if session.effectiveTool == .move, let g = hitGuide(at: p) {
            session.guideDrag = (g.id, g.axis, g.position)
            drag = .guide
            return
        }
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
        case .freeTransform:
            session.transformMouseDown(at: controller.documentPoint(p), viewTolerance: 8)
            drag = .transform
        case .crop:
            session.cropMouseDown(at: session.snapped(controller.documentPoint(p)), viewTolerance: 8)
            drag = .crop
        case .type:
            if session.editingText != nil {
                endTextEditing()
            } else {
                session.typeClick(at: controller.documentPoint(p))
            }
        case .pen:
            session.penMouseDown(at: session.snapped(controller.documentPoint(p)), viewTolerance: 7)
            drag = .pen
        case .shape:
            let d = session.snapped(controller.documentPoint(p))
            session.shapeDrag = (d, d)
            drag = .shape
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
        case .transform:
            session.transformDrag(to: controller.documentPoint(p), shift: event.modifierFlags.contains(.shift))
        case .crop:
            session.cropDrag(to: session.snapped(controller.documentPoint(p)))
        case .pen:
            session.penDragged(to: controller.documentPoint(p), breakSymmetry: event.modifierFlags.contains(.option))
        case .shape:
            guard let s0 = session.shapeDrag else { break }
            var d = session.snapped(controller.documentPoint(p))
            if event.modifierFlags.contains(.shift) {
                let v = d - s0.start
                if session.shapeKind == .line {
                    let a = (atan2(v.y, v.x) / (.pi / 4)).rounded() * (.pi / 4)
                    d = s0.start + SIMD2(cos(a), sin(a)) * simd_length(v)
                } else {
                    let side = max(abs(v.x), abs(v.y))
                    d = s0.start + SIMD2(v.x < 0 ? -side : side, v.y < 0 ? -side : side)
                }
            }
            session.shapeDrag = (s0.start, d)
        case .guide:
            guard let g = session.guideDrag else { break }
            let d = controller.documentPoint(p)
            session.guideDrag = (g.id, g.axis, g.axis == .vertical ? d.x : d.y)
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
        case .transform: session.transformMouseUp()
        case .crop: session.cropSession?.dragging = nil
        case .pen: session.penMouseUp()
        case .shape: session.finishShape()
        case .guide:
            if let g = session.guideDrag {
                session.guideDrag = nil
                let p = location(of: event)
                let outside = p.x < 18 || p.y < 18 || p.x > bounds.width || p.y > bounds.height
                if let id = g.id {
                    outside ? session.removeGuide(id) : session.moveGuide(id, to: g.position.rounded(), live: false)
                } else if !outside {
                    session.addGuide(g.axis, at: g.position.rounded())
                }
            }
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

    private func hitGuide(at p: SIMD2<Double>) -> Guide? {
        let d = controller.documentPoint(p)
        let tol = 4 / max(controller.transform.scale, 0.001)
        return session.state.aids.guides.first { g in
            abs((g.axis == .vertical ? d.x : d.y) - g.position) < tol
        }
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
             .brush, .eraser, .gradient, .eyedropper, .paintBucket, .crop, .pen, .shape: .crosshair
        case .type: .iBeam
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
        let isReturn = event.keyCode == 36 || event.keyCode == 76, isEscape = event.keyCode == 53
        if session.transformSession != nil, isReturn || isEscape {
            isReturn ? session.commitTransform() : session.cancelTransform()
            session.tool = .move
            return
        }
        if session.cropSession != nil, isReturn || isEscape {
            isReturn ? session.applyCrop() : (session.cropSession = nil)
            session.tool = .move
            return
        }
        if session.effectiveTool == .pen, isReturn || isEscape {
            session.finishPathSegment()
            if isEscape { session.activePathID = nil }
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
                                           .magicSelect, .crop, .freeTransform, .brush, .eraser, .paintBucket, .gradient,
                                           .type, .pen, .shape, .eyedropper, .hand]

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

extension CanvasNSView: NSTextViewDelegate {
    /// Esc (and ⌘⏎ / Enter on the keypad) ends text editing; plain Return inserts a line break.
    func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.cancelOperation(_:)) || selector == #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)) {
            endTextEditing()
            return true
        }
        if selector == #selector(NSResponder.insertNewline(_:)), NSApp.currentEvent?.modifierFlags.contains(.command) == true
            || NSApp.currentEvent?.keyCode == 76 {
            endTextEditing()
            return true
        }
        return false
    }

    func textDidChange(_ notification: Notification) {
        fitEditor()
    }
}

/// Pixel rulers along the top and left edges. Purely visual; clicks fall through
/// to the canvas, which turns ruler drags into guides.
final class RulerView: NSView {
    static let thickness: CGFloat = 18
    var transform: () -> ViewTransform? = { nil }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard let t = transform() else { return }
        let th = Self.thickness
        NSColor.windowBackgroundColor.withAlphaComponent(0.92).setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: th).fill()
        NSRect(x: 0, y: 0, width: th, height: bounds.height).fill()
        NSColor.separatorColor.setFill()
        NSRect(x: 0, y: th - 1, width: bounds.width, height: 1).fill()
        NSRect(x: th - 1, y: 0, width: 1, height: bounds.height).fill()

        // Pick a step that leaves ~60 pt between labelled ticks.
        let steps: [Double] = [1, 2, 5, 10, 20, 50, 100, 200, 500, 1000, 2000, 5000, 10000]
        let step = steps.first { $0 * t.scale >= 60 } ?? 10000
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .regular),
                                                    .foregroundColor: NSColor.secondaryLabelColor]
        NSColor.tertiaryLabelColor.setFill()
        let topLeft = t.documentPoint(fromView: SIMD2(0, 0)), bottomRight = t.documentPoint(fromView: SIMD2(bounds.width, bounds.height))
        // Horizontal ruler.
        var x = (min(topLeft.x, bottomRight.x) / step).rounded(.down) * step
        while x <= max(topLeft.x, bottomRight.x) {
            for i in 0..<10 {
                let dx = x + step * Double(i) / 10
                let vx = t.viewPoint(fromDocument: SIMD2(dx, topLeft.y)).x
                guard vx >= th else { continue }
                let h: CGFloat = i == 0 ? th : (i == 5 ? 7 : 4)
                NSRect(x: vx, y: th - h, width: 1, height: h).fill()
            }
            let vx = t.viewPoint(fromDocument: SIMD2(x, topLeft.y)).x
            if vx >= th { NSString(string: "\(Int(x))").draw(at: NSPoint(x: vx + 2, y: 1), withAttributes: attrs) }
            x += step
        }
        // Vertical ruler.
        var y = (min(topLeft.y, bottomRight.y) / step).rounded(.down) * step
        while y <= max(topLeft.y, bottomRight.y) {
            for i in 0..<10 {
                let dy = y + step * Double(i) / 10
                let vy = t.viewPoint(fromDocument: SIMD2(topLeft.x, dy)).y
                guard vy >= th else { continue }
                let w: CGFloat = i == 0 ? th : (i == 5 ? 7 : 4)
                NSRect(x: th - w, y: vy, width: w, height: 1).fill()
            }
            let vy = t.viewPoint(fromDocument: SIMD2(topLeft.x, y)).y
            if vy >= th {
                NSGraphicsContext.saveGraphicsState()
                let xf = NSAffineTransform()
                xf.translateX(by: 1, yBy: vy + 2)
                xf.rotate(byDegrees: 90)
                xf.concat()
                NSString(string: "\(Int(y))").draw(at: NSPoint(x: 0, y: -10), withAttributes: attrs)
                NSGraphicsContext.restoreGraphicsState()
            }
            y += step
        }
        NSColor.windowBackgroundColor.setFill()
        NSRect(x: 0, y: 0, width: th, height: th).fill()
    }
}

