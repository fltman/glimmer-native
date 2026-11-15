import Foundation
import Testing
@testable import GlimmerCore

@Suite struct CommandSearchTests {
    let items: [PaletteItem] = [
        PaletteItem(id: "a", title: "Gaussian Blur…", subtitle: "Filter", keywords: ["soften"], action: .command(.filter(.gaussianBlur))),
        PaletteItem(id: "b", title: "Group Layer", subtitle: "Layer", action: .command(.groupLayers)),
        PaletteItem(id: "c", title: "Hue/Saturation", subtitle: "Adjustment", keywords: ["color"], action: .command(.newAdjustment(.hueSaturation))),
        PaletteItem(id: "d", title: "Brush", subtitle: "Tool", action: .tool("brush")),
    ]

    @Test func subsequenceMatching() {
        #expect(FuzzyMatch.score("gb", "Gaussian Blur") != nil)
        #expect(FuzzyMatch.score("xyz", "Gaussian Blur") == nil)
        #expect(FuzzyMatch.score("blur", "Gaussian Blur")! > FuzzyMatch.score("blur", "Bring Layer Up Right")!)
    }

    @Test func rankingAndKeywords() {
        #expect(CommandSearch.search("gaus", in: items).first?.item.id == "a")
        #expect(CommandSearch.search("hue", in: items).first?.item.id == "c")
        #expect(CommandSearch.search("soften", in: items).first?.item.id == "a")
        #expect(CommandSearch.search("br", in: items).first?.item.id == "d")
        #expect(CommandSearch.search("", in: items).count == 4)
    }

    @Test func assistantRouting() {
        #expect(CommandSearch.looksLikeAssistantRequest("make the sky more dramatic", bestScore: 5))
        #expect(!CommandSearch.looksLikeAssistantRequest("blur", bestScore: 20))
        #expect(CommandSearch.looksLikeAssistantRequest("remove person", bestScore: nil))
    }

    @Test func candidatesComeFromWordsToo() {
        // The whole sentence matches nothing; its words do.
        #expect(CommandSearch.search("please soften the photo a bit", in: items).isEmpty)
        let c = CommandSearch.candidates(for: "please soften the photo a bit", in: items)
        #expect(c.first?.id == "a")
        #expect(CommandSearch.candidates(for: "pick the brush", in: items).contains { $0.id == "d" })
    }
}

@Suite struct CommandUsageTests {
    let items = [
        PaletteItem(id: "sharpen", title: "Sharpen", subtitle: "Filter", action: .command(.filter(.sharpen))),
        PaletteItem(id: "shadow", title: "Shadows", subtitle: "Adjustment", action: .command(.groupLayers)),
    ]

    @Test func frequentlyUsedItemWinsAnEvenMatch() {
        let now = Date()
        let plain = CommandSearch.search("sha", in: items, now: now)
        #expect(plain.first?.item.id == "sharpen")
        var usage: [String: CommandUsage] = [:]
        for _ in 0..<5 { CommandUsage.record("shadow", in: &usage, now: now) }
        let ranked = CommandSearch.search("sha", in: items, usage: usage, now: now)
        #expect(ranked.first?.item.id == "shadow")
    }

    @Test func boostFadesWithoutUse() {
        let now = Date()
        let fresh = CommandUsage(count: 8, last: now)
        let stale = CommandUsage(count: 8, last: now.addingTimeInterval(-60 * 86_400))
        #expect(fresh.boost(now: now) > 2)
        #expect(stale.boost(now: now) < 0.3)
        #expect(CommandUsage().boost(now: now) == 0)
    }

    @Test func boostNeverBeatsAMuchBetterMatch() {
        var usage: [String: CommandUsage] = [:]
        for _ in 0..<100 { CommandUsage.record("shadow", in: &usage) }
        #expect(CommandSearch.search("sharpen", in: items, usage: usage).first?.item.id == "sharpen")
    }

    @Test func tableStaysBounded() {
        var usage: [String: CommandUsage] = [:]
        for i in 0..<30 { CommandUsage.record("id\(i)", in: &usage, limit: 10) }
        #expect(usage.count == 10)
        #expect(usage["id29"] != nil)
    }
}
