import CoreGraphics
import Foundation
import ImageIO
import GlimmerCore
import Testing
import simd
@testable import GlimmerRender

/// A project written for the web app must read back the same.
@Suite struct AipsExporterTests {
    private func flat(_ state: DocumentState) throws -> [UInt8] {
        let image = try ImageExporter.flattenedSRGB(state, context: context())
        var px = [UInt8](repeating: 0, count: image.width * image.height * 4)
        px.withUnsafeMutableBytes {
            let ctx = CGContext(data: $0.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8,
                                bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return px
    }

    @Test func layersMasksAndSettingsRoundTrip() throws {
        let size = 300
        // A red layer hanging outside the canvas, masked to its left half; a blue one in a group; an adjustment.
        var red = Layer(name: "Red", opacity: 0.8, blendMode: .multiply,
                        content: .raster(.solid(SIMD4(1, 0, 0, 1), covering: PixelRect(x: 0, y: 0, width: 512, height: 256))))
        red.mask = Selection.rectangle(CGRectLike(x0: 0, y0: 0, x1: 150, y1: 300)).asMask
        var stroke = StrokeEffect()
        stroke.width = 5
        stroke.position = .inside
        red.effects.stroke = stroke
        let blue = solidLayer(SIMD4(0, 0, 1, 1))
        var curves = Adjustment(.curves)
        curves.curves[.rgb] = [CurvePoint(0, 0), CurvePoint(0.5, 0.7), CurvePoint(1, 1)]
        let group = Layer(name: "Group", content: .group(LayerGroup(children: [blue, Layer(name: "Curves", content: .adjustment(curves))],
                                                                    isExpanded: false)))
        let white = Layer(name: "White", content: .raster(.solid(SIMD4(1, 1, 1, 1), covering: PixelRect(x: 0, y: 0, width: 512, height: 512))))
        var state = DocumentState(width: size, height: size, layers: [white, group, red])
        state.activeLayerID = red.id
        state.paths = [VectorPath(name: "Curve", subpaths: [Subpath(anchors: [
            PathAnchor(SIMD2(10, 20), handleOut: SIMD2(40, 20)), PathAnchor(SIMD2(200, 220), handleIn: SIMD2(150, 220)),
        ], isClosed: false)])]
        state.aids.guides = [Guide(axis: .vertical, position: 120), Guide(axis: .horizontal, position: 33)]
        state.aids.grid.isVisible = true
        state.aids.grid.spacing = 50
        state.aids.snap = false

        let data = try AipsExporter.exportProject(state, context: context())
        let back = try AipsImporter.importProject(data)

        #expect(back.width == size && back.height == size)
        #expect(back.layers.map(\.name) == ["White", "Group", "Red"])
        #expect(back.activeLayer?.name == "Red")
        let r = try #require(back.layers.last)
        #expect(r.opacity == 0.8 && r.blendMode == .multiply)
        #expect(r.effects.stroke?.width == 5 && r.effects.stroke?.position == .inside)
        #expect(r.mask != nil)
        let g = try #require(back.layers[1].content.groupValue)
        #expect(!g.isExpanded && g.children.map(\.name) == ["L", "Curves"])
        if case .adjustment(let a) = g.children[1].content {
            #expect(a.kind == .curves && a.curves[.rgb] == curves.curves[.rgb])
        } else {
            Issue.record("the adjustment came back as something else")
        }
        #expect(back.paths.count == 1 && back.paths[0].name == "Curve")
        #expect(back.paths[0].subpaths == state.paths[0].subpaths)
        #expect(back.aids.guides.map(\.position) == [120, 33])
        #expect(back.aids.guides.map(\.axis) == [.vertical, .horizontal])
        #expect(back.aids.grid.isVisible && back.aids.grid.spacing == 50 && !back.aids.snap)

        // The picture is the same (8-bit PNG round trip: allow one level of rounding).
        let before = try flat(state), after = try flat(back)
        let worst = zip(before, after).map { abs(Int($0) - Int($1)) }.max() ?? 0
        #expect(worst <= 2, "largest channel difference \(worst)")
    }

    @Test func textKeepsItsSettingsAndPath() throws {
        let path = VectorPath(name: "Arc", subpaths: [Subpath(anchors: [PathAnchor(SIMD2(20, 100)), PathAnchor(SIMD2(280, 100))])])
        var text = TextLayer(string: "Hello", fontName: "Helvetica-Bold", size: 40, color: SRGBColor(0.2, 0.4, 0.6),
                             alignment: .center, origin: SIMD2(30, 40))
        text.onPath = path.polygons().first
        text.onPathID = path.id
        var state = DocumentState(width: 300, height: 200, layers: [Layer(name: "Hello", content: .text(text))])
        state.paths = [path]

        let back = try AipsImporter.importProject(AipsExporter.exportProject(state, context: context()))
        guard case .text(let t) = back.layers.first?.content else {
            Issue.record("the text layer came back as something else")
            return
        }
        #expect(t.string == "Hello" && t.size == 40 && t.alignment == .center)
        #expect(t.fontName == "Helvetica-Bold")
        #expect(abs(t.color.g - 0.4) < 1e-9)
        #expect(abs(t.origin.x - 30) <= 1 && abs(t.origin.y - 40) <= 1)
        #expect(t.onPathID == back.paths.first?.id)
        #expect(t.onPath == back.paths.first?.polygons().first)
    }

    @Test func fillLayersGoOutAsPixels() throws {
        let fill = Layer(name: "Fill", content: .fill(.solid(SRGBColor(0, 1, 0))))
        let state = DocumentState(width: 64, height: 64, layers: [fill])
        let back = try AipsImporter.importProject(AipsExporter.exportProject(state, context: context()))
        #expect(back.layers.first?.isRaster == true)
        let px = try flat(back)
        #expect(px[0] == 0 && px[1] == 255 && px[2] == 0 && px[3] == 255)
    }
}

private extension LayerContent {
    var groupValue: LayerGroup? { if case .group(let g) = self { g } else { nil } }
}

/// Shapes are fill layers with a mask; their layer styles follow the mask's outline.
@Suite struct ShapeStyleTests {
    @Test func strokeFollowsAShapesOutline() throws {
        let shape = Selection.rectangle(CGRectLike(x0: 100, y0: 100, x1: 200, y1: 200))
        var layer = Layer(name: "Shape", mask: shape.asMask, content: .fill(.solid(SRGBColor(0, 0, 1))))
        var stroke = StrokeEffect()
        stroke.color = SRGBColor(1, 0, 0)
        stroke.width = 10
        stroke.position = .outside
        layer.effects.stroke = stroke
        let state = DocumentState(width: 300, height: 300, layers: [layer])
        let image = try ImageExporter.flattenedSRGB(state, context: context())
        var px = [UInt8](repeating: 0, count: 300 * 300 * 4)
        px.withUnsafeMutableBytes {
            let ctx = CGContext(data: $0.baseAddress, width: 300, height: 300, bitsPerComponent: 8, bytesPerRow: 1200,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: 300, height: 300))
        }
        func at(_ x: Int, _ y: Int) -> [UInt8] { Array(px[(y * 300 + x) * 4..<(y * 300 + x) * 4 + 4]) }
        #expect(at(150, 150) == [0, 0, 255, 255], "the fill")
        #expect(at(95, 150) == [255, 0, 0, 255], "the stroke, 5 px outside the left edge")
        #expect(at(150, 205) == [255, 0, 0, 255], "the stroke, below the bottom edge")
        #expect(at(80, 150)[3] == 0, "nothing beyond the stroke")
    }
}

/// Writes a project with one of everything to GLIMMER_AIPS_OUT, for opening in the web app by hand.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["GLIMMER_AIPS_OUT"] != nil))
struct AipsSampleTests {
    @Test func writesASample() throws {
        let path = VectorPath(name: "Arc", subpaths: [Subpath(anchors: [
            PathAnchor(SIMD2(60, 420), handleOut: SIMD2(200, 300)), PathAnchor(SIMD2(560, 420), handleIn: SIMD2(420, 300)),
        ])])
        var onPath = TextLayer(string: "Along the path", fontName: "Helvetica-Bold", size: 36, color: SRGBColor(1, 1, 1), origin: SIMD2(60, 380))
        onPath.onPath = path.polygons().first
        onPath.onPathID = path.id
        let plain = TextLayer(string: "Glimmer native", fontName: "Helvetica-Bold", size: 48, color: SRGBColor(1, 0.9, 0.2), origin: SIMD2(40, 30))
        var red = Layer(name: "Red, masked left half", opacity: 0.9,
                        content: .raster(.solid(SIMD4(1, 0, 0, 1), covering: PixelRect(x: 256, y: 0, width: 256, height: 256))))
        red.mask = Selection.rectangle(CGRectLike(x0: 256, y0: 0, x1: 384, y1: 256)).asMask
        var shadow = ShadowEffect()
        shadow.distance = 12
        red.effects.dropShadow = shadow
        let smartSource = TileGrid.solid(SIMD4(0, 0.6, 0, 1), covering: PixelRect(x: 0, y: 0, width: 256, height: 256))
        let smart = Layer(name: "Smart, rotated", content: .smart(SmartObject(
            source: smartSource, width: 256, height: 256,
            transform: .make(x: 330, y: 250, scaleX: 0.6, scaleY: 0.4, rotation: 0.4, sourceSize: SIMD2(256, 256)))))
        var hue = Adjustment(.hueSaturation)
        hue.numbers["hue"] = 60
        let group = Layer(name: "Group", content: .group(LayerGroup(children: [
            Layer(name: "Blue", content: .raster(.solid(SIMD4(0, 0, 1, 1), covering: PixelRect(x: 0, y: 256, width: 256, height: 256)))),
            Layer(name: "Hue +60", content: .adjustment(hue)),
        ])))
        let sky = Layer(name: "Grey", content: .raster(.solid(SIMD4(0.2, 0.2, 0.2, 1), covering: PixelRect(x: 0, y: 0, width: 768, height: 512))))
        var state = DocumentState(width: 640, height: 480, layers: [
            sky, group, red, smart, Layer(name: "Title", content: .text(plain)), Layer(name: "On path", content: .text(onPath)),
        ])
        state.paths = [path]
        state.aids.guides = [Guide(axis: .vertical, position: 320)]
        state.aids.rulersVisible = true
        let out = ProcessInfo.processInfo.environment["GLIMMER_AIPS_OUT"]!
        try AipsExporter.exportProject(state, context: context()).write(to: URL(fileURLWithPath: out))
        // What the native app shows, to compare with the web app's rendering.
        let image = try ImageExporter.flattenedSRGB(state, context: context())
        let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: out + ".png") as CFURL, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, image, nil)
        CGImageDestinationFinalize(dest)
    }
}
