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
