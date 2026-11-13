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

    public var bounds: PixelRect {
        if let line = onPath, line.count > 1 {
            let lo = line.reduce(line[0]) { simd_min($0, $1) }, hi = line.reduce(line[0]) { simd_max($0, $1) }
            let pad = size * 1.3
            let x0 = Int((lo.x - pad).rounded(.down)), y0 = Int((lo.y - pad).rounded(.down))
            return PixelRect(x: x0, y: y0, width: Int((hi.x + pad).rounded(.up)) - x0, height: Int((hi.y + pad).rounded(.up)) - y0)
        }
        let s = layoutSize
        return PixelRect(x: Int(origin.x.rounded(.down)), y: Int(origin.y.rounded(.down)),
                         width: Int(s.width.rounded(.up)) + 1, height: Int(s.height.rounded(.up)) + 1)
    }

    /// Renders the text into a straight-alpha sRGB image whose top-left is `bounds` origin.
    public func render() -> CGImage? {
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
        let path = CGPath(rect: CGRect(x: fx, y: Double(b.height) - fy - size.height, width: size.width, height: size.height),
                          transform: nil)
        let framesetter = CTFramesetterCreateWithAttributedString(attributedString())
        let frame = CTFramesetterCreateFrame(framesetter, CFRange(), path, nil)
        CTFrameDraw(frame, ctx)
        return ctx.makeImage()
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
