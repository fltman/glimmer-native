import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import GlimmerCore

@Suite struct AipsImporterTests {
    /// A 10×10 opaque red PNG as a data URL.
    private func redPNG() -> String {
        let ctx = CGContext(data: nil, width: 10, height: 10, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 10, height: 10))
        let data = NSMutableData()
        let dest = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        CGImageDestinationFinalize(dest)
        return "data:image/png;base64," + (data as Data).base64EncodedString()
    }

    private func sample() -> Data {
        let mask = Data((0..<100).map { $0 < 50 ? 0 : 255 }).base64EncodedString()
        let json: [String: Any] = [
            "magic": "aips", "version": 1, "width": 300, "height": 200, "activeLayerId": "r1",
            "rootOrder": ["g1", "a1"],
            "nodes": [
                ["id": "a1", "kind": "adjustment", "name": "Curves", "visible": true, "opacity": 0.5,
                 "blendMode": "overlay", "parentId": NSNull(), "adjustmentType": "curves", "clipping": false,
                 "params": ["rgb": [["x": 0, "y": 0], ["x": 0.5, "y": 0.7], ["x": 1, "y": 1]]]],
                ["id": "g1", "kind": "group", "name": "Group", "visible": true, "opacity": 1,
                 "blendMode": "normal", "parentId": NSNull(), "collapsed": true, "childrenIds": ["r1", "s1", "t1", "e1"]],
                ["id": "r1", "kind": "raster", "name": "Red", "visible": true, "opacity": 1, "blendMode": "multiply",
                 "parentId": "g1", "x": 20, "y": 30, "width": 10, "height": 10, "clipping": false,
                 "pixels": redPNG(),
                 "mask": ["width": 10, "height": 10, "enabled": true, "data": mask],
                 "effects": ["dropShadow": ["enabled": true, "color": ["r": 0, "g": 0, "b": 0, "a": 1],
                                            "opacity": 0.6, "angle": 45, "distance": 4, "size": 2],
                             "stroke": ["enabled": true, "color": ["r": 1, "g": 1, "b": 1, "a": 1],
                                        "width": 2, "position": "inside"]]],
                ["id": "s1", "kind": "smart", "name": "Smart", "visible": true, "opacity": 1, "blendMode": "normal",
                 "parentId": "g1", "x": 0, "y": 0, "width": 20, "height": 20, "naturalWidth": 10, "naturalHeight": 10,
                 "transform": ["tx": 50, "ty": 60, "sx": 2, "sy": 2, "rot": 0], "clipping": true, "pixels": redPNG()],
                ["id": "t1", "kind": "text", "name": "Title", "visible": true, "opacity": 1, "blendMode": "normal",
                 "parentId": "g1", "x": 5, "y": 5, "clipping": false,
                 "text": ["text": "Hi", "fontFamily": "Inter, system-ui", "fontSize": 24,
                          "color": ["r": 0, "g": 0, "b": 1, "a": 1], "align": "left", "bold": true,
                          "italic": false, "lineHeight": 1.2]],
                ["id": "e1", "kind": "adjustment", "name": "Exposure", "visible": false, "opacity": 1,
                 "blendMode": "normal", "parentId": "g1", "adjustmentType": "exposure", "clipping": false,
                 "params": ["exposure": 1, "offset": 0, "gamma": 1]],
            ],
        ]
        return try! JSONSerialization.data(withJSONObject: json)
    }

    @Test func importsTreeAndProperties() throws {
        let state = try AipsImporter.importProject(sample())
        #expect(state.width == 300 && state.height == 200)
        #expect(state.layers.map(\.name) == ["Group", "Curves"])

        let curves = state.layers[1]
        #expect(curves.opacity == 0.5 && curves.blendMode == .overlay)
        guard case .adjustment(let a) = curves.content else { Issue.record("curves"); return }
        #expect(a.curve(.rgb).count == 3)

        let group = state.layers[0]
        guard case .group(let g) = group.content else { Issue.record("group"); return }
        #expect(!g.isExpanded)
        #expect(g.children.map(\.name) == ["Red", "Smart", "Title", "Exposure"])

        let red = g.children[0]
        #expect(red.blendMode == .multiply)
        #expect(state.activeLayerID == red.id)
        #expect(red.tiles[TileCoord(0, 0)] != nil)
        #expect(red.effects.dropShadow?.opacity == 0.6)
        #expect(red.effects.stroke?.position == .inside)
        #expect(red.mask?.tiles[TileCoord(0, 0)] != nil)

        guard case .smart(let smart) = g.children[1].content else { Issue.record("smart"); return }
        #expect(g.children[1].isClipped)
        #expect(smart.transform.apply(SIMD2(0, 0)) == SIMD2(50, 60))
        #expect(smart.transform.apply(SIMD2(10, 10)) == SIMD2(70, 80))

        #expect(!g.children[2].tiles.isEmpty)  // text rasterized

        guard case .adjustment(let exposure) = g.children[3].content else { Issue.record("exposure"); return }
        #expect(exposure.number("exposure") == 1)  // a number, not mistaken for a Bool
        #expect(!g.children[3].isVisible)
    }

    @Test func maskValues() throws {
        let state = try AipsImporter.importProject(sample())
        guard case .group(let g) = state.layers[0].content, let tile = g.children[0].mask?.tiles[TileCoord(0, 0)] else {
            Issue.record("mask"); return
        }
        let px = tile.pixels()
        func value(_ x: Int, _ y: Int) -> Float { Float(px[(y * 256 + x) * 4 + 3]) }
        #expect(value(25, 32) == 0)    // first half of the mask rows: hidden
        #expect(value(25, 37) == 1)    // second half: visible
        #expect(value(100, 100) == 1)  // outside the layer: reveal
    }

    @Test func rejectsOtherJSON() {
        #expect(throws: AipsImportError.self) {
            try AipsImporter.importProject(Data(#"{"magic": "nope"}"#.utf8))
        }
    }
}
