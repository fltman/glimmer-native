import Foundation
import GlimmerCore
import Testing
@testable import GlimmerAI

@Suite struct MorePipelineTests {
    @Test func relightPromptMatchesWeb() {
        let p = AIPipelines.relightInstruction(direction: .left, color: SRGBColor(1, 0.9, 0.75), intensity: 0.8,
                                               environment: "a neon alley")
        #expect(p.hasPrefix("Relight this image. Add a dominant key light coming from the LEFT side"))
        #expect(p.contains("warm (golden/amber) light, color hex #ffe6bf"))
        #expect(p.contains("DRAMATIC"))
        #expect(p.contains("\"a neon alley\""))
        #expect(p.hasSuffix("do not crop, rotate or resize the image."))
    }

    @Test func enhanceTilesCoverWithOverlap() {
        let tiles = AIPipelines.enhanceTiles(width: 2500, height: 900)
        #expect(tiles.count == 3)
        #expect(tiles.last!.maxX == 2500)
        #expect(AIPipelines.enhanceTiles(width: 800, height: 600) == [PixelRect(x: 0, y: 0, width: 800, height: 600)])
    }

    @Test func harmonizeKeepsSubjectAlpha() async throws {
        var fg = RGBAImage(width: 10, height: 10, fill: SIMD4(255, 0, 0, 0))
        for i in 0..<50 { fg.pixels[i * 4 + 3] = 255 }
        let bg = RGBAImage(width: 10, height: 10, fill: SIMD4(0, 0, 255, 255))
        let model = FakeModel { _ in RGBAImage(width: 20, height: 20, fill: SIMD4(0, 255, 0, 255)) }
        let r = try await AIPipelines.harmonize(foreground: fg, background: bg, strength: 0.5, model: model)
        #expect(r.image.pixels[3] == 255 && r.image.pixels[99 * 4 + 3] == 0)
        #expect(abs(r.image.pixels[1] - 127.5) < 1)  // halfway toward the model's green
        #expect(model.prompts[0].contains("Noticeably relight"))
    }

    @Test func reflectionsConfinedToPaddedROI() async throws {
        let img = RGBAImage(width: 200, height: 200, fill: SIMD4(100, 100, 100, 255))
        let model = FakeModel { $0[0] }
        let r = try await AIPipelines.removeReflections(img, roi: PixelRect(x: 50, y: 50, width: 50, height: 50),
                                                        strength: 0.9, model: model)
        #expect(r.origin == SIMD2(35, 35) && r.image.width == 80)
        #expect(model.prompts[0].hasPrefix("Work ONLY on the reflective surface in this crop."))
        #expect(model.prompts[0].contains("COMPLETELY"))
    }

    @Test func parsesAndSanitizesDistractions() {
        let reply = """
        ```json
        {"distractions": [
          {"id": "d1", "label": "power line", "severity": "high", "box": {"x": 0.1, "y": 0.2, "width": 0.5, "height": 0.1}},
          {"label": "edge", "box": {"x": 0.9, "y": 0.9, "width": 0.5, "height": 0.5}},
          {"label": "empty", "box": {"x": 0.5, "y": 0.5, "width": 0, "height": 0.2}}
        ], "message": "Found 2"}
        ```
        """
        let (items, message) = AIPipelines.parseDistractions(reply)
        #expect(items.count == 2)
        #expect(items[0].label == "power line")
        #expect(abs(items[1].box.width - 0.1) < 1e-9)  // clamped to stay inside
        #expect(items[1].id == "d2")
        #expect(message == "Found 2")
        #expect(items[0].pixelRect(width: 1000, height: 500) == PixelRect(x: 100, y: 100, width: 500, height: 50))
    }
}

@Suite struct PresetTests {
    @Test func presetsBuildAdjustmentGroups() {
        #expect(Preset.all.count == 10)
        let teal = Preset.all.first { $0.id == "teal_orange" }!
        let group = teal.makeGroup()
        #expect(group.blendMode == .passThrough)
        #expect(group.children.count == 3)
        #expect(teal.filterSteps.map(\.0) == ["clarity"])
        guard case .adjustment(let balance) = group.children[1].content else { Issue.record("balance"); return }
        #expect(balance.kind == .colorBalance && balance.number("shadowsB") == 0.24)
        let dreamy = Preset.all.first { $0.id == "dreamy_soft" }!.makeGroup()
        guard case .adjustment(let gm) = dreamy.children.last!.content else { Issue.record("gradient"); return }
        #expect(gm.gradient.count == 3 && gm.gradient[1].position == 0.5)
    }
}
