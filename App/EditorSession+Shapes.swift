import AppKit
import GlimmerCore
import GlimmerRender
import GlimmerTools
import SwiftUI
import simd

extension EditorSession {
    // MARK: Shapes

    enum ShapeKind: String, CaseIterable {
        case rectangle, roundedRectangle, ellipse, line
        var title: String {
            switch self {
            case .rectangle: "Rectangle"
            case .roundedRectangle: "Rounded Rectangle"
            case .ellipse: "Ellipse"
            case .line: "Line"
            }
        }
    }

    /// Outline of a rounded rectangle (corner arcs sampled finely enough for antialiasing).
    static func roundedRectPolygon(_ r: CGRectLike, radius: Double) -> [SIMD2<Double>] {
        let rad = max(0, min(radius, r.width / 2, r.height / 2))
        guard rad > 0.5 else {
            return [SIMD2(r.minX, r.minY), SIMD2(r.maxX, r.minY), SIMD2(r.maxX, r.maxY), SIMD2(r.minX, r.maxY)]
        }
        let steps = max(8, Int(rad / 2).clamped(to: 8...48))
        let centres = [SIMD2(r.maxX - rad, r.minY + rad), SIMD2(r.maxX - rad, r.maxY - rad),
                       SIMD2(r.minX + rad, r.maxY - rad), SIMD2(r.minX + rad, r.minY + rad)]
        var points: [SIMD2<Double>] = []
        for (i, c) in centres.enumerated() {
            let start = -Double.pi / 2 + Double(i) * Double.pi / 2
            for k in 0...steps {
                let a = start + Double(k) / Double(steps) * Double.pi / 2
                points.append(c + SIMD2(cos(a), sin(a)) * rad)
            }
        }
        return points
    }

    /// A shape becomes a solid colour fill layer with the shape as its mask, so
    /// it stays recolourable and editable.
    func finishShape() {
        guard let drag = shapeDrag else { return }
        shapeDrag = nil
        let r = CGRectLike(x0: drag.start.x, y0: drag.start.y, x1: drag.end.x, y1: drag.end.y)
        let path: VectorPath
        switch shapeKind {
        case .rectangle:
            guard r.width >= 1, r.height >= 1 else { return }
            path = .rectangle(r)
        case .roundedRectangle:
            guard r.width >= 1, r.height >= 1 else { return }
            path = .roundedRectangle(r, radius: shapeCornerRadius)
        case .ellipse:
            guard r.width >= 1, r.height >= 1 else { return }
            path = .ellipse(r)
        case .line:
            let v = drag.end - drag.start
            guard simd_length(v) >= 1 else { return }
            let n = SIMD2(-v.y, v.x) / simd_length(v) * max(shapeLineWidth, 1) / 2
            path = VectorPath(name: "Line", subpaths: [Subpath(anchors: [drag.start + n, drag.end + n, drag.end - n, drag.start - n].map { PathAnchor($0) },
                                                                isClosed: true)])
        }
        // A shape is a solid fill layer with a vector mask: recolourable, editable with the pen, scalable.
        var layer = Layer(name: layerName(shapeKind.title), mask: path.asSelection.asMask, vectorMask: path, content: .fill(.solid(shapeFillColor ?? foreground)))
        if shapeFillColor == nil, foregroundOpacity < 1 { layer.opacity = foregroundOpacity }
        if shapeStrokeWidth >= 1 {
            // The outline is a layer style, so its colour and width stay editable.
            var stroke = StrokeEffect()
            stroke.color = shapeStrokeColor
            stroke.width = shapeStrokeWidth
            stroke.position = .center
            layer.effects.stroke = stroke
        }
        edit(String(localized: "New \(String(localized: String.LocalizationValue(shapeKind.title)))")) { $0.insertLayerAboveActive(layer) }
    }
}
