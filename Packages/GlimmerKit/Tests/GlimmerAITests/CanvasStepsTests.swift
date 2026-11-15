import Foundation
@testable import GlimmerAI
import GlimmerCore
import Testing

/// What crop, resize_image, select_rect, set_layer and add_image make of their parameters.
@Suite struct CanvasStepsTests {
    static let canvas = PixelRect(x: 0, y: 0, width: 1600, height: 1000)
    static func step(_ op: String, _ params: [String: JSONValue]) -> AgentStep { AgentStep(op: op, params: params) }
    static func reason(_ body: () throws -> Void) -> String? {
        do { try body() } catch let r as CanvasSteps.Refusal { return r.reason } catch { return "other" }
        return nil
    }

    @Test func cropFormsExcludeEachOther() {
        #expect(CanvasSteps.malformed(Self.step("crop", ["width": .number(10), "height": .number(10)])) == nil)
        #expect(CanvasSteps.malformed(Self.step("crop", ["aspect": .string("1:1")])) == nil)
        #expect(CanvasSteps.malformed(Self.step("crop", ["toSelection": .bool(true)])) == nil)
        #expect(CanvasSteps.malformed(Self.step("crop", ["aspect": .string("1:1"), "width": .number(10), "height": .number(10)])) != nil)
        #expect(CanvasSteps.malformed(Self.step("crop", ["aspect": .string("1:1"), "toSelection": .bool(true)])) != nil)
        #expect(CanvasSteps.malformed(Self.step("crop", [:])) != nil)
        #expect(CanvasSteps.malformed(Self.step("crop", ["width": .number(10)])) != nil, "a rectangle needs both sides")
        #expect(CanvasSteps.malformed(Self.step("crop", ["toSelection": .bool(false), "aspect": .string("1:1")])) == nil)
    }

    @Test func aRectangleIsClippedToTheCanvas() throws {
        let box = try CanvasSteps.cropBox(Self.step("crop", ["x": .number(-100), "y": .number(900), "width": .number(500), "height": .number(500)]),
                                          canvas: Self.canvas, selection: nil)
        #expect(box == PixelRect(x: 0, y: 900, width: 400, height: 100))
        #expect(Self.reason { _ = try CanvasSteps.cropBox(Self.step("crop", ["x": .number(2000), "width": .number(50), "height": .number(50)]),
                                                         canvas: Self.canvas, selection: nil) } == "bad_rect")
        #expect(Self.reason { _ = try CanvasSteps.rect(Self.step("select_rect", ["width": .number(0), "height": .number(50)]), canvas: Self.canvas) } == "bad_rect")
    }

    @Test func aspectGivesTheLargestCentredBox() throws {
        let wide = try CanvasSteps.cropBox(Self.step("crop", ["aspect": .string("16:9")]), canvas: Self.canvas, selection: nil)
        #expect(wide == PixelRect(x: 0, y: 50, width: 1600, height: 900))
        let square = try CanvasSteps.cropBox(Self.step("crop", ["aspect": .string("1:1")]), canvas: Self.canvas, selection: nil)
        #expect(square == PixelRect(x: 300, y: 0, width: 1000, height: 1000))
        for bad in ["16", "16:0", "-4:3", "a:b", "16:9:1", ""] {
            #expect(Self.reason { _ = try CanvasSteps.cropBox(Self.step("crop", ["aspect": .string(bad)]), canvas: Self.canvas, selection: nil) } == "bad_aspect", "\(bad)")
        }
        #expect(CanvasSteps.aspect(" 4 : 3 ") == 4.0 / 3)
    }

    @Test func cropToSelectionNeedsOne() throws {
        let sel = PixelRect(x: 100, y: 100, width: 300, height: 200)
        #expect(try CanvasSteps.cropBox(Self.step("crop", ["toSelection": .bool(true)]), canvas: Self.canvas, selection: sel) == sel)
        #expect(Self.reason { _ = try CanvasSteps.cropBox(Self.step("crop", ["toSelection": .bool(true)]), canvas: Self.canvas, selection: nil) } == "no_selection")
    }

    @Test func resizeKeepsProportionsUnlessBothSidesAreGiven() throws {
        #expect(CanvasSteps.malformed(Self.step("resize_image", ["scale": .number(0.5), "width": .number(10)])) != nil)
        #expect(CanvasSteps.malformed(Self.step("resize_image", [:])) != nil)
        #expect(try CanvasSteps.newSize(Self.step("resize_image", ["width": .number(800)]), width: 1600, height: 1000) == (800, 500))
        #expect(try CanvasSteps.newSize(Self.step("resize_image", ["height": .number(250)]), width: 1600, height: 1000) == (400, 250))
        #expect(try CanvasSteps.newSize(Self.step("resize_image", ["width": .number(300), "height": .number(300)]), width: 1600, height: 1000) == (300, 300))
        #expect(try CanvasSteps.newSize(Self.step("resize_image", ["scale": .number(2)]), width: 1600, height: 1000) == (3200, 2000))
        #expect(Self.reason { _ = try CanvasSteps.newSize(Self.step("resize_image", ["scale": .number(0)]), width: 1600, height: 1000) } == "bad_size")
        #expect(Self.reason { _ = try CanvasSteps.newSize(Self.step("resize_image", ["width": .number(40_000)]), width: 1600, height: 1000) } == "bad_size")
    }

    @Test func setLayerChecksItsValues() throws {
        let c = try CanvasSteps.layerChange(Self.step("set_layer", ["opacity": .number(0.5), "blendMode": .string("soft-light"), "visible": .bool(false), "name": .string(" Sky ")]), isGroup: false)
        #expect(c == CanvasSteps.LayerChange(opacity: 0.5, blendMode: .softLight, visible: false, name: "Sky"))
        #expect(Self.reason { _ = try CanvasSteps.layerChange(Self.step("set_layer", ["opacity": .number(50)]), isGroup: false) } == "bad_opacity")
        #expect(Self.reason { _ = try CanvasSteps.layerChange(Self.step("set_layer", ["blendMode": .string("glow")]), isGroup: false) } == "unknown_blend_mode")
        #expect(Self.reason { _ = try CanvasSteps.layerChange(Self.step("set_layer", ["blendMode": .string("pass-through")]), isGroup: false) } == "unknown_blend_mode")
        #expect(try CanvasSteps.layerChange(Self.step("set_layer", ["blendMode": .string("pass-through")]), isGroup: true).blendMode == .passThrough)
        #expect(Self.reason { _ = try CanvasSteps.layerChange(Self.step("set_layer", [:]), isGroup: false) } == "nothing_to_set")
    }

    @Test func aTargetIsAnIdOrAnUnambiguousName() throws {
        let a = UUID(), b = UUID(), c = UUID()
        let layers = [(id: a, name: "Sky"), (id: b, name: "Title"), (id: c, name: "title")]
        #expect(try CanvasSteps.target("sky", in: layers) == a)
        #expect(try CanvasSteps.target(b.uuidString.lowercased(), in: layers) == b)
        do {
            _ = try CanvasSteps.target("Title", in: layers)
            Issue.record("two layers share the name")
        } catch let r as CanvasSteps.Refusal {
            #expect(r.reason == "ambiguous_target" && r.message.contains(b.uuidString) && r.message.contains(c.uuidString))
        }
        #expect(Self.reason { _ = try CanvasSteps.target("Nope", in: layers) } == "unknown_layer")
    }

    @Test func anAddedImageFitsTheCanvas() {
        let big = CanvasSteps.placement(image: (4000, 2000), canvas: (1000, 1000), fit: .contain, x: nil, y: nil)
        #expect(big.width == 1000 && big.height == 500 && big.x == 0 && big.y == 250)
        let small = CanvasSteps.placement(image: (200, 100), canvas: (1000, 1000), fit: .contain, x: nil, y: nil)
        #expect(small.width == 200 && small.x == 400 && small.y == 450, "contain never scales up")
        let cover = CanvasSteps.placement(image: (200, 100), canvas: (1000, 1000), fit: .cover, x: nil, y: nil)
        #expect(cover.width == 2000 && cover.height == 1000 && cover.x == -500 && cover.y == 0)
        let placed = CanvasSteps.placement(image: (200, 100), canvas: (1000, 1000), fit: .none, x: 10, y: 20)
        #expect(placed.x == 10 && placed.y == 20 && placed.width == 200)
    }

    @Test func theOperationsListHasTheNewOnes() throws {
        let ops = AgentAPI.operations
        func op(_ name: String) throws -> [String: Any] { try #require(ops.first { $0["name"] as? String == name }) }
        for name in ["crop", "resize_image", "set_layer", "add_image"] { #expect(try op(name)["tier"] as? String == "core") }
        #expect(try op("select_rect")["tier"] as? String == "advanced")
        let add = try op("add_image")
        #expect((add["call"] as? [String: String]) == ["method": "POST", "path": "/api/v1/documents/{id}/layers"])
        #expect(add["undoable"] as? Bool == true && add["startsJob"] as? Bool == false)
        let props = try #require((add["params"] as? [String: Any])?["properties"] as? [String: [String: Any]])
        for q in ["name", "fit", "x", "y", "smartObject"] { #expect(props[q]?["x-in"] as? String == "query") }
        let crop = try #require((try op("crop")["params"] as? [String: Any])?["required"] as? [String])
        #expect(crop.isEmpty)
        let sel = try #require((try op("select_rect")["params"] as? [String: Any])?["required"] as? [String])
        #expect(Set(sel) == ["x", "y", "width", "height"])
    }
}

@Suite struct ScaledEffectsTests {
    @Test func layerStylesFollowTheImageSize() {
        var e = LayerEffects()
        e.dropShadow = ShadowEffect()
        e.stroke = StrokeEffect()
        let half = e.scaled(by: 0.5)
        #expect(half.dropShadow?.distance == 5 && half.dropShadow?.size == 5 && half.stroke?.width == 1.5)
        #expect(half.dropShadow?.opacity == e.dropShadow?.opacity && half.outerGlow == nil)
    }
}

@Suite struct CanvasSizeTests {
    static func step(_ params: [String: JSONValue]) -> AgentStep { AgentStep(op: "resize_canvas", params: params) }

    @Test func resizeCanvasTakesASizeOrAShape() throws {
        #expect(CanvasSteps.malformed(Self.step([:])) != nil)
        #expect(CanvasSteps.malformed(Self.step(["aspect": .string("16:9"), "width": .number(10)])) != nil)
        #expect(CanvasSteps.malformed(Self.step(["height": .number(10)])) == nil)
        // One side alone keeps the other.
        #expect(try CanvasSteps.canvasBox(Self.step(["width": .number(1200)]), width: 1000, height: 600) == PixelRect(x: -100, y: 0, width: 1200, height: 600))
        // The smallest 16:9 canvas that holds a square image, the image on the right.
        let wide = try CanvasSteps.canvasBox(Self.step(["aspect": .string("16:9"), "anchor": .string("right")]), width: 900, height: 900)
        #expect(wide == PixelRect(x: -700, y: 0, width: 1600, height: 900))
        // A wide image made square grows in height.
        #expect(try CanvasSteps.canvasBox(Self.step(["aspect": .string("1:1"), "anchor": .string("top")]), width: 1000, height: 600) == PixelRect(x: 0, y: 0, width: 1000, height: 1000))
        func reason(_ p: [String: JSONValue]) -> String? {
            do { _ = try CanvasSteps.canvasBox(Self.step(p), width: 1000, height: 600) } catch let r as CanvasSteps.Refusal { return r.reason } catch { return "other" }
            return nil
        }
        #expect(reason(["width": .number(0)]) == "bad_size" && reason(["width": .number(99_999)]) == "bad_size")
        #expect(reason(["width": .number(10), "anchor": .string("middle")]) == "bad_anchor")
        #expect(reason(["aspect": .string("wide")]) == "bad_aspect")
    }

    @Test func theAnchorDecidesWhereTheNewRoomGoes() {
        let old = (width: 1000, height: 600)
        // Wider, anchored in the middle: the room is shared between left and right.
        #expect(CanvasSteps.canvasBox(old: old, new: (1200, 600), anchor: (1, 1)) == PixelRect(x: -100, y: 0, width: 1200, height: 600))
        // Anchored top-left: everything is added to the right and below.
        #expect(CanvasSteps.canvasBox(old: old, new: (1200, 800), anchor: (0, 0)) == PixelRect(x: 0, y: 0, width: 1200, height: 800))
        // Anchored bottom-right, smaller: the top-left is cut away.
        #expect(CanvasSteps.canvasBox(old: old, new: (500, 300), anchor: (2, 2)) == PixelRect(x: 500, y: 300, width: 500, height: 300))
        #expect(CanvasSteps.canvasBox(old: old, new: (1001, 600), anchor: (1, 1)).x == -1)
    }
}
