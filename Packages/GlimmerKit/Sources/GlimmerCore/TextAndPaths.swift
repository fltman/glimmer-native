import CoreGraphics
import CoreText
import Foundation
import simd

// MARK: Text layers

public enum TextAlignment: String, Codable, CaseIterable, Sendable {
    case left, center, right
    public var title: String { rawValue.capitalized }
}

/// An editable text layer, laid out with Core Text.
public struct TextLayer: Codable, Hashable, Sendable {
    public var string: String
    /// PostScript font name (e.g. "HelveticaNeue-Bold").
    public var fontName: String
    /// Point size in document pixels.
    public var size: Double
    public var color: SRGBColor
    public var alignment: TextAlignment
    /// Extra spacing between characters, in 1/1000 em (like Photoshop's tracking).
    public var tracking: Double
    /// Line height as a multiple of the font size.
    public var lineHeight: Double
    /// Top-left of the text box in document pixels.
    public var origin: SIMD2<Double>
    /// Paragraph text wraps at this width; nil = point text.
    public var boxWidth: Double?
    /// Text on a path: the baseline follows this polyline (document pixels).
    /// Alignment places the text at the start, middle or end of the path.
    public var onPath: [SIMD2<Double>]?
    /// The document path `onPath` was taken from; the text follows that path when it is edited.
    public var onPathID: UUID?
    /// Envelope warp (Photoshop's Warp Text). Ignored for text on a path.
    public var warp: TextWarp?
    /// Rotation, scale and skew from Free Transform, applied after layout (document →
    /// document), so the text stays editable. Always affine; nil when untransformed.
    public var transform: AffineTransform?

    public init(string: String, fontName: String = "HelveticaNeue", size: Double = 72, color: SRGBColor = .black,
                alignment: TextAlignment = .left, tracking: Double = 0, lineHeight: Double = 1.2,
                origin: SIMD2<Double>, boxWidth: Double? = nil) {
        self.string = string
        self.fontName = fontName
        self.size = size
        self.color = color
        self.alignment = alignment
        self.tracking = tracking
        self.lineHeight = lineHeight
        self.origin = origin
        self.boxWidth = boxWidth
    }

    public var font: CTFont { CTFontCreateWithName(fontName as CFString, size, nil) }

    public func attributedString() -> NSAttributedString {
        let ctAlign: CTTextAlignment = switch alignment {
        case .left: .left
        case .center: .center
        case .right: .right
        }
        var align = ctAlign
        var lineHeightValue = CGFloat(size * lineHeight)
        let settings = [
            CTParagraphStyleSetting(spec: .alignment, valueSize: MemoryLayout<CTTextAlignment>.size, value: &align),
            CTParagraphStyleSetting(spec: .minimumLineHeight, valueSize: MemoryLayout<CGFloat>.size, value: &lineHeightValue),
            CTParagraphStyleSetting(spec: .maximumLineHeight, valueSize: MemoryLayout<CGFloat>.size, value: &lineHeightValue),
        ]
        let style = CTParagraphStyleCreate(settings, settings.count)
        let attrs: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String):
                CGColor(srgbRed: color.r, green: color.g, blue: color.b, alpha: 1),
            NSAttributedString.Key(kCTParagraphStyleAttributeName as String): style,
            NSAttributedString.Key(kCTKernAttributeName as String): tracking / 1000 * size,
        ]
        return NSAttributedString(string: string.isEmpty ? " " : string, attributes: attrs)
    }

    /// Size of the laid-out text (document pixels).
    public var layoutSize: CGSize {
        let framesetter = CTFramesetterCreateWithAttributedString(attributedString())
        let constraint = CGSize(width: boxWidth ?? .greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        let fit = CTFramesetterSuggestFrameSizeWithConstraints(framesetter, CFRange(), nil, constraint, nil)
        return CGSize(width: ceil(boxWidth ?? fit.width) + 2, height: ceil(fit.height) + 2)
    }

    /// Bounds of the rendered text, after `transform`.
    public var bounds: PixelRect {
        let b = layoutBounds
        guard let t = transform, t != .identity else { return b }
        let x0 = Double(b.x), y0 = Double(b.y), x1 = Double(b.x + b.width), y1 = Double(b.y + b.height)
        let corners = [SIMD2(x0, y0), SIMD2(x1, y0), SIMD2(x1, y1), SIMD2(x0, y1)].map(t.apply)
        let lo = corners.reduce(corners[0], simd_min), hi = corners.reduce(corners[0], simd_max)
        let nx = Int(lo.x.rounded(.down)), ny = Int(lo.y.rounded(.down))
        return PixelRect(x: nx, y: ny, width: Int(hi.x.rounded(.up)) - nx + 1, height: Int(hi.y.rounded(.up)) - ny + 1)
    }

    /// Bounds of the laid-out text before `transform`.
    public var layoutBounds: PixelRect {
        if let line = onPath, line.count > 1 {
            let lo = line.reduce(line[0]) { simd_min($0, $1) }, hi = line.reduce(line[0]) { simd_max($0, $1) }
            let pad = size * 1.3
            let x0 = Int((lo.x - pad).rounded(.down)), y0 = Int((lo.y - pad).rounded(.down))
            return PixelRect(x: x0, y: y0, width: Int((hi.x + pad).rounded(.up)) - x0, height: Int((hi.y + pad).rounded(.up)) - y0)
        }
        let s = layoutSize
        let m = activeWarp?.margins(width: s.width, height: s.height) ?? .zero
        return PixelRect(x: Int((origin.x - m.x).rounded(.down)), y: Int((origin.y - m.y).rounded(.down)),
                         width: Int((s.width + 2 * m.x).rounded(.up)) + 1, height: Int((s.height + 2 * m.y).rounded(.up)) + 1)
    }

    /// The warp, when it changes anything.
    public var activeWarp: TextWarp? {
        guard onPath == nil, let warp, warp.isActive else { return nil }
        return warp
    }

    /// Renders the text into a straight-alpha sRGB image whose top-left is `bounds` origin.
    public func render() -> CGImage? {
        if let t = transform, t != .identity {
            // Lay out and draw as usual, then map the picture through the transform.
            var plain = self
            plain.transform = nil
            guard let image = plain.render() else { return nil }
            let ub = plain.bounds, tb = bounds
            guard tb.width > 0, tb.height > 0, tb.width * tb.height < 300_000_000,
                  let ctx = CGContext(data: nil, width: tb.width, height: tb.height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
            ctx.interpolationQuality = .high
            ctx.translateBy(x: 0, y: CGFloat(tb.height))  // document space, y down, from tb's corner
            ctx.scaleBy(x: 1, y: -1)
            ctx.translateBy(x: CGFloat(-tb.x), y: CGFloat(-tb.y))
            ctx.concatenate(CGAffineTransform(a: t.a, b: t.b, c: t.c, d: t.d, tx: t.tx, ty: t.ty))
            ctx.translateBy(x: CGFloat(ub.x), y: CGFloat(ub.y + ub.height))  // draw the image upright
            ctx.scaleBy(x: 1, y: -1)
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: ub.width, height: ub.height))
            return ctx.makeImage()
        }
        let b = bounds
        guard b.width > 0, b.height > 0, b.width * b.height < 300_000_000,
              let ctx = CGContext(data: nil, width: b.width, height: b.height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setShouldAntialias(true)
        ctx.setShouldSmoothFonts(false)
        if let line = onPath, line.count > 1 {
            drawOnPath(line, in: ctx, bounds: b)
            return ctx.makeImage()
        }
        // Sub-pixel placement of the origin.
        let fx = origin.x - Double(b.x), fy = origin.y - Double(b.y)
        let size = layoutSize
        if let warp = activeWarp {
            drawWarped(warp, in: ctx, bounds: b, size: size)
            return ctx.makeImage()
        }
        let path = CGPath(rect: CGRect(x: fx, y: Double(b.height) - fy - size.height, width: size.width, height: size.height),
                          transform: nil)
        let framesetter = CTFramesetterCreateWithAttributedString(attributedString())
        let frame = CTFramesetterCreateFrame(framesetter, CFRange(), path, nil)
        CTFrameDraw(frame, ctx)
        return ctx.makeImage()
    }

    /// The glyph outlines of the laid-out text, in text-box coordinates (y down, origin top-left).
    public func glyphOutlines() -> CGPath {
        let size = layoutSize
        let framesetter = CTFramesetterCreateWithAttributedString(attributedString())
        let frame = CTFramesetterCreateFrame(framesetter, CFRange(),
                                             CGPath(rect: CGRect(origin: .zero, size: size), transform: nil), nil)
        let lines = CTFrameGetLines(frame) as! [CTLine]
        var origins = [CGPoint](repeating: .zero, count: lines.count)
        CTFrameGetLineOrigins(frame, CFRange(), &origins)
        let result = CGMutablePath()
        for (line, lineOrigin) in zip(lines, origins) {
            for run in CTLineGetGlyphRuns(line) as! [CTRun] {
                let count = CTRunGetGlyphCount(run)
                guard count > 0 else { continue }
                var glyphs = [CGGlyph](repeating: 0, count: count)
                var positions = [CGPoint](repeating: .zero, count: count)
                CTRunGetGlyphs(run, CFRange(), &glyphs)
                CTRunGetPositions(run, CFRange(), &positions)
                let attrs = CTRunGetAttributes(run) as NSDictionary
                let runFont = attrs[kCTFontAttributeName as String].map { $0 as! CTFont } ?? font
                for k in 0..<count {
                    guard let glyph = CTFontCreatePathForGlyph(runFont, glyphs[k], nil) else { continue }
                    // Glyph space is y up; flip into the y-down box.
                    let x = lineOrigin.x + positions[k].x, y = lineOrigin.y + positions[k].y
                    let t = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: x, ty: size.height - y)
                    result.addPath(glyph, transform: t)
                }
            }
        }
        return result
    }

    /// Fills the glyph outlines bent through the warp envelope (vector, so edges stay crisp).
    private func drawWarped(_ warp: TextWarp, in ctx: CGContext, bounds b: PixelRect, size: CGSize) {
        let w = Double(size.width), h = Double(size.height)
        let ox = origin.x - Double(b.x), oy = origin.y - Double(b.y)
        let warped = warp.apply(to: glyphOutlines(), width: w, height: h)
        // Box (y down) → context (y up).
        var t = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: ox, ty: Double(b.height) - oy)
        guard let placed = warped.copy(using: &t) else { return }
        ctx.setFillColor(CGColor(srgbRed: color.r, green: color.g, blue: color.b, alpha: 1))
        ctx.addPath(placed)
        ctx.fillPath(using: .winding)
    }

    /// Draws each glyph centred on its arc-length position along `line`, rotated to the tangent.
    private func drawOnPath(_ line: [SIMD2<Double>], in ctx: CGContext, bounds b: PixelRect) {
        var lengths = [0.0]
        for i in 1..<line.count { lengths.append(lengths[i - 1] + simd_distance(line[i - 1], line[i])) }
        let total = lengths.last!
        guard total > 0 else { return }
        let ctLine = CTLineCreateWithAttributedString(attributedString())
        let width = CTLineGetTypographicBounds(ctLine, nil, nil, nil)
        let start: Double = switch alignment {
        case .left: 0
        case .center: (total - width) / 2
        case .right: total - width
        }
        func point(at s: Double) -> (SIMD2<Double>, Double)? {
            guard s >= 0, s <= total else { return nil }
            var i = 1
            while i < lengths.count - 1, lengths[i] < s { i += 1 }
            let seg = lengths[i] - lengths[i - 1]
            let t = seg > 0 ? (s - lengths[i - 1]) / seg : 0
            let a = line[i - 1], c = line[i]
            return (a + (c - a) * t, atan2(c.y - a.y, c.x - a.x))
        }
        ctx.setFillColor(CGColor(srgbRed: color.r, green: color.g, blue: color.b, alpha: 1))
        let runs = CTLineGetGlyphRuns(ctLine) as! [CTRun]
        for run in runs {
            let count = CTRunGetGlyphCount(run)
            guard count > 0 else { continue }
            var glyphs = [CGGlyph](repeating: 0, count: count)
            var positions = [CGPoint](repeating: .zero, count: count)
            var advances = [CGSize](repeating: .zero, count: count)
            CTRunGetGlyphs(run, CFRange(), &glyphs)
            CTRunGetPositions(run, CFRange(), &positions)
            CTRunGetAdvances(run, CFRange(), &advances)
            let attrs = CTRunGetAttributes(run) as NSDictionary
            let runFont = attrs[kCTFontAttributeName as String].map { $0 as! CTFont } ?? font
            for k in 0..<count {
                let mid = start + Double(positions[k].x) + Double(advances[k].width) / 2
                guard let (p, angle) = point(at: mid) else { continue }
                ctx.saveGState()
                // Document (y down) → context (y up).
                ctx.translateBy(x: p.x - Double(b.x), y: Double(b.height) - (p.y - Double(b.y)))
                ctx.rotate(by: -angle)
                var glyph = glyphs[k]
                var origin = CGPoint(x: -advances[k].width / 2, y: 0)
                CTFontDrawGlyphs(runFont, &glyph, &origin, 1, ctx)
                ctx.restoreGState()
            }
        }
    }
}

// MARK: Warp Text

/// Photoshop-style text warp envelope (the web app's `TextWarp`). `bend`,
/// `horizontal` and `vertical` are -1…1.
public struct TextWarp: Codable, Hashable, Sendable {
    public enum Style: String, Codable, CaseIterable, Sendable, Identifiable {
        case none, arc, arch, bulge, wave, flag, rise
        public var id: String { rawValue }
        public var title: String { rawValue.capitalized }
    }

    public var style: Style
    public var bend: Double
    public var horizontal: Double
    public var vertical: Double

    public init(style: Style, bend: Double = 0.5, horizontal: Double = 0, vertical: Double = 0) {
        self.style = style
        self.bend = bend
        self.horizontal = horizontal
        self.vertical = vertical
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        style = (try? c.decode(Style.self, forKey: .style)) ?? .none
        bend = (try? c.decode(Double.self, forKey: .bend)) ?? 0
        horizontal = (try? c.decode(Double.self, forKey: .horizontal)) ?? 0
        vertical = (try? c.decode(Double.self, forKey: .vertical)) ?? 0
    }

    public var isActive: Bool { style != .none && (bend != 0 || horizontal != 0 || vertical != 0) }

    /// Displacement of the box point at normalised (u, v) (0…1, v down) as a
    /// fraction of the box size. The formulas match the web app.
    public func displacement(u: Double, v: Double) -> SIMD2<Double> {
        let bend = min(max(bend, -1), 1), hz = min(max(horizontal, -1), 1), vt = min(max(vertical, -1), 1)
        let uc = u * 2 - 1, vc = v * 2 - 1
        var dy: Double = switch style {
        case .none: 0
        case .arc: bend * 0.5 * (1 - uc * uc) * (1 - v)
        case .arch: bend * 0.5 * (1 - uc * uc)
        case .bulge: bend * 0.5 * (1 - uc * uc) * vc
        case .wave: bend * 0.3 * sin(uc * .pi * 2)
        case .flag: bend * 0.3 * sin(uc * .pi * 2) * (0.4 + 0.6 * u)
        case .rise: bend * 0.5 * uc
        }
        dy += vt * 0.3 * uc
        return SIMD2(hz * 0.3 * vc, dy)
    }

    /// How far the warp can push content outside a `width` × `height` box.
    public func margins(width: Double, height: Double) -> SIMD2<Double> {
        let b = abs(min(max(bend, -1), 1))
        var v: Double = switch style {
        case .none: 0
        case .arc, .arch, .bulge, .rise: b * 0.5
        case .wave, .flag: b * 0.3
        }
        v += abs(vertical) * 0.3
        return SIMD2((abs(horizontal) * 0.3 * width).rounded(.up) + 2, (v * height).rounded(.up) + 2)
    }

    /// Maps a point in a `width` × `height` box (y down) through the envelope.
    public func map(_ p: SIMD2<Double>, width: Double, height: Double) -> SIMD2<Double> {
        let d = displacement(u: width > 0 ? p.x / width : 0, v: height > 0 ? p.y / height : 0)
        return p + d * SIMD2(width, height)
    }

    /// Bends a path (box coordinates, y down). Curves are flattened first so
    /// straight stems bend smoothly too.
    public func apply(to path: CGPath, width: Double, height: Double) -> CGPath {
        let out = CGMutablePath()
        let step = max(min(width, height) / 64, 0.75)
        var current = CGPoint.zero, start = CGPoint.zero
        func emit(_ p: CGPoint, move: Bool) {
            let m = map(SIMD2(p.x, p.y), width: width, height: height)
            if move { out.move(to: CGPoint(x: m.x, y: m.y)) } else { out.addLine(to: CGPoint(x: m.x, y: m.y)) }
        }
        func lineTo(_ p: CGPoint) {
            let n = max(Int((hypot(p.x - current.x, p.y - current.y) / step).rounded(.up)), 1)
            for i in 1...n {
                let t = Double(i) / Double(n)
                emit(CGPoint(x: current.x + (p.x - current.x) * t, y: current.y + (p.y - current.y) * t), move: false)
            }
            current = p
        }
        func curve(_ n: Int, _ at: (Double) -> CGPoint) {
            for i in 1...n { lineTo(at(Double(i) / Double(n))) }
        }
        path.applyWithBlock { element in
            let e = element.pointee
            switch e.type {
            case .moveToPoint:
                current = e.points[0]
                start = current
                emit(current, move: true)
            case .addLineToPoint:
                lineTo(e.points[0])
            case .addQuadCurveToPoint:
                let p0 = current, c = e.points[0], p1 = e.points[1]
                curve(8) { t in
                    let a = (1 - t) * (1 - t), b = 2 * (1 - t) * t, d = t * t
                    return CGPoint(x: a * p0.x + b * c.x + d * p1.x, y: a * p0.y + b * c.y + d * p1.y)
                }
            case .addCurveToPoint:
                let p0 = current, c1 = e.points[0], c2 = e.points[1], p1 = e.points[2]
                curve(10) { t in
                    let m = 1 - t
                    let a = m * m * m, b = 3 * m * m * t, c = 3 * m * t * t, d = t * t * t
                    return CGPoint(x: a * p0.x + b * c1.x + c * c2.x + d * p1.x,
                                   y: a * p0.y + b * c1.y + c * c2.y + d * p1.y)
                }
            case .closeSubpath:
                lineTo(start)
                out.closeSubpath()
            @unknown default:
                break
            }
        }
        return out
    }
}

// MARK: Paths (pen tool)

public struct PathAnchor: Codable, Hashable, Sendable {
    public var point: SIMD2<Double>
    /// Absolute positions of the incoming/outgoing control points (equal to `point` for corners).
    public var handleIn: SIMD2<Double>
    public var handleOut: SIMD2<Double>

    public init(_ point: SIMD2<Double>, handleIn: SIMD2<Double>? = nil, handleOut: SIMD2<Double>? = nil) {
        self.point = point
        self.handleIn = handleIn ?? point
        self.handleOut = handleOut ?? point
    }
}

public struct Subpath: Codable, Hashable, Sendable {
    public var anchors: [PathAnchor]
    public var isClosed: Bool

    public init(anchors: [PathAnchor] = [], isClosed: Bool = false) {
        self.anchors = anchors
        self.isClosed = isClosed
    }
}

public struct VectorPath: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var subpaths: [Subpath]

    public init(id: UUID = UUID(), name: String, subpaths: [Subpath] = []) {
        self.id = id
        self.name = name
        self.subpaths = subpaths
    }

    /// The path with every point mapped through `t`.
    public func applying(_ t: AffineTransform) -> VectorPath {
        var p = self
        p.subpaths = subpaths.map { sub in
            var s = sub
            s.anchors = sub.anchors.map { PathAnchor(t.apply($0.point), handleIn: t.apply($0.handleIn), handleOut: t.apply($0.handleOut)) }
            return s
        }
        return p
    }

    /// The area enclosed by the path (each subpath filled; overlapping subpaths add).
    public var asSelection: Selection { Selection.polygons(polygons()) }

    /// Bounding box of all anchors and handles.
    public var controlBounds: CGRectLike? {
        let pts = subpaths.flatMap { $0.anchors.flatMap { [$0.point, $0.handleIn, $0.handleOut] } }
        guard let f = pts.first else { return nil }
        let lo = pts.reduce(f) { simd_min($0, $1) }, hi = pts.reduce(f) { simd_max($0, $1) }
        return CGRectLike(x0: lo.x, y0: lo.y, x1: hi.x, y1: hi.y)
    }

    // MARK: Shapes (cubic Béziers, so they scale cleanly)

    public static func rectangle(_ r: CGRectLike, name: String = "Rectangle") -> VectorPath {
        roundedRectangle(r, radius: 0, name: name)
    }

    public static func roundedRectangle(_ r: CGRectLike, radius: Double, name: String = "Rounded Rectangle") -> VectorPath {
        let rad = max(0, min(radius, r.width / 2, r.height / 2))
        guard rad > 0.01 else {
            return VectorPath(name: name, subpaths: [Subpath(anchors: [
                PathAnchor(SIMD2(r.minX, r.minY)), PathAnchor(SIMD2(r.maxX, r.minY)),
                PathAnchor(SIMD2(r.maxX, r.maxY)), PathAnchor(SIMD2(r.minX, r.maxY)),
            ], isClosed: true)])
        }
        let k = rad * 0.5522847498
        let (x0, y0, x1, y1) = (r.minX, r.minY, r.maxX, r.maxY)
        let a: [PathAnchor] = [
            PathAnchor(SIMD2(x0 + rad, y0), handleIn: SIMD2(x0 + rad - k, y0)),
            PathAnchor(SIMD2(x1 - rad, y0), handleOut: SIMD2(x1 - rad + k, y0)),
            PathAnchor(SIMD2(x1, y0 + rad), handleIn: SIMD2(x1, y0 + rad - k)),
            PathAnchor(SIMD2(x1, y1 - rad), handleOut: SIMD2(x1, y1 - rad + k)),
            PathAnchor(SIMD2(x1 - rad, y1), handleIn: SIMD2(x1 - rad + k, y1)),
            PathAnchor(SIMD2(x0 + rad, y1), handleOut: SIMD2(x0 + rad - k, y1)),
            PathAnchor(SIMD2(x0, y1 - rad), handleIn: SIMD2(x0, y1 - rad + k)),
            PathAnchor(SIMD2(x0, y0 + rad), handleOut: SIMD2(x0, y0 + rad - k)),
        ]
        return VectorPath(name: name, subpaths: [Subpath(anchors: a, isClosed: true)])
    }

    public static func ellipse(_ r: CGRectLike, name: String = "Ellipse") -> VectorPath {
        let cx = (r.minX + r.maxX) / 2, cy = (r.minY + r.maxY) / 2, rx = r.width / 2, ry = r.height / 2
        let kx = rx * 0.5522847498, ky = ry * 0.5522847498
        let a: [PathAnchor] = [
            PathAnchor(SIMD2(cx, cy - ry), handleIn: SIMD2(cx - kx, cy - ry), handleOut: SIMD2(cx + kx, cy - ry)),
            PathAnchor(SIMD2(cx + rx, cy), handleIn: SIMD2(cx + rx, cy - ky), handleOut: SIMD2(cx + rx, cy + ky)),
            PathAnchor(SIMD2(cx, cy + ry), handleIn: SIMD2(cx + kx, cy + ry), handleOut: SIMD2(cx - kx, cy + ry)),
            PathAnchor(SIMD2(cx - rx, cy), handleIn: SIMD2(cx - rx, cy + ky), handleOut: SIMD2(cx - rx, cy - ky)),
        ]
        return VectorPath(name: name, subpaths: [Subpath(anchors: a, isClosed: true)])
    }

    /// Flattened polygons (one per subpath), `steps` samples per curved segment.
    public func polygons(steps: Int = 24) -> [[SIMD2<Double>]] {
        subpaths.map { sub in
            var out: [SIMD2<Double>] = []
            let n = sub.anchors.count
            guard n > 0 else { return out }
            out.append(sub.anchors[0].point)
            let segments = sub.isClosed ? n : n - 1
            for i in 0..<max(segments, 0) {
                let a = sub.anchors[i], b = sub.anchors[(i + 1) % n]
                let straight = a.handleOut == a.point && b.handleIn == b.point
                if straight {
                    out.append(b.point)
                    continue
                }
                for s in 1...steps {
                    let t = Double(s) / Double(steps), u = 1 - t
                    let p = u * u * u * a.point + 3 * u * u * t * a.handleOut + 3 * u * t * t * b.handleIn + t * t * t * b.point
                    out.append(p)
                }
            }
            return out
        }
    }

    public var cgPath: CGPath {
        let path = CGMutablePath()
        for sub in subpaths where !sub.anchors.isEmpty {
            let first = sub.anchors[0]
            path.move(to: CGPoint(x: first.point.x, y: first.point.y))
            let n = sub.anchors.count
            let segments = sub.isClosed ? n : n - 1
            for i in 0..<max(segments, 0) {
                let a = sub.anchors[i], b = sub.anchors[(i + 1) % n]
                path.addCurve(to: CGPoint(x: b.point.x, y: b.point.y),
                              control1: CGPoint(x: a.handleOut.x, y: a.handleOut.y),
                              control2: CGPoint(x: b.handleIn.x, y: b.handleIn.y))
            }
            if sub.isClosed { path.closeSubpath() }
        }
        return path
    }
}

// MARK: Guides and grid

public struct Guide: Codable, Hashable, Identifiable, Sendable {
    public enum Axis: String, Codable, Sendable { case horizontal, vertical }
    public var id: UUID
    public var axis: Axis
    /// Document pixels (y for horizontal, x for vertical).
    public var position: Double

    public init(id: UUID = UUID(), axis: Axis, position: Double) {
        self.id = id
        self.axis = axis
        self.position = position
    }
}

public struct GridSettings: Codable, Hashable, Sendable {
    public var isVisible = false
    public var spacing = 100.0
    public var subdivisions = 4

    public init() {}
}

public struct ViewAids: Codable, Hashable, Sendable {
    public var guides: [Guide] = []
    public var grid = GridSettings()
    public var rulersVisible = false
    public var snap = true

    public init() {}
}
