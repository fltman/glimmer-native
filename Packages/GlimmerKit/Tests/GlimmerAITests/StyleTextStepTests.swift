import Foundation
@testable import GlimmerAI
import GlimmerCore
import Testing

/// The agent's style_text step: grapheme-cluster ranges, matches and what it reports.
@Suite struct StyleTextStepTests {
    static func text(_ s: String) -> TextLayer {
        TextLayer(string: s, fontName: "HelveticaNeue", size: 40, color: .black, origin: SIMD2(0, 0))
    }
    static func step(_ params: [String: JSONValue]) -> AgentStep { AgentStep(op: "style_text", params: params) }
    static func ranges(_ info: [String: Any]) -> [[Int]] {
        (info["ranges"] as? [[String: Any]] ?? []).map { [$0["from"] as? Int ?? -1, $0["length"] as? Int ?? -1] }
    }

    @Test func matchStylesEveryOccurrenceAndReportsThem() throws {
        var t = Self.text("sale, sale, SALE")
        let info = try StyleTextStep.apply(Self.step(["match": .string("sale"), "color": .string("#E0303A")]), to: &t)
        #expect(info["matches"] as? Int == 2, "exact matches first; SALE only if nothing matched exactly")
        #expect(Self.ranges(info) == [[0, 4], [6, 4]])
        #expect(t.style(at: 7).color.hexString == "#E0303A" && t.style(at: 12).color == .black)
        var first = Self.text("sale, sale")
        let one = try StyleTextStep.apply(Self.step(["match": .string("sale"), "occurrence": .string("first"), "size": .number(80)]), to: &first)
        #expect(Self.ranges(one) == [[0, 4]] && first.style(at: 7).size == 40)
    }

    @Test func fromAndLengthCountGraphemeClusters() throws {
        // 👍🏽 is 4 UTF-16 units and 2 code points; "å" here is a + combining ring (2 units).
        let s = "👍🏽 la\u{030A}t bra"
        #expect(s.count == 9)
        var t = Self.text(s)
        let info = try StyleTextStep.apply(Self.step(["from": .number(2), "length": .number(3), "size": .number(60)]), to: &t)
        #expect(Self.ranges(info) == [[2, 3]])
        let ns = t.string as NSString
        let big = t.resolvedRuns().filter { $0.style.size == 60 }.map { ns.substring(with: $0.range) }
        #expect(big == ["la\u{030A}t"], "the combining ring stays with its a")
        // The emoji is one character: from 0, length 1 takes all of it.
        var e = Self.text(s)
        _ = try StyleTextStep.apply(Self.step(["from": .number(0), "length": .number(1), "color": .string("#00FF00")]), to: &e)
        let green = e.resolvedRuns().filter { $0.style.color.hexString == "#00FF00" }.map { (e.string as NSString).substring(with: $0.range) }
        #expect(green == ["👍🏽"])
        // The styles list reports the same units.
        let run = try #require(t.styles?.first)
        #expect(t.characterRange(of: run.range) == (2, 3))
    }

    @Test func matchNeverSplitsACharacter() throws {
        var t = Self.text("la\u{030A}t and lat")
        let info = try StyleTextStep.apply(Self.step(["match": .string("la"), "bold": .bool(true)]), to: &t)
        #expect(Self.ranges(info) == [[8, 2]], "“la” isn't inside “låt”, where the a carries a ring")
        #expect(t.style(at: 10).fontName.contains("Bold"))
    }

    @Test func refusalsHaveReasons() {
        func reason(_ s: String, _ p: [String: JSONValue]) -> String? {
            var t = Self.text(s)
            do { _ = try StyleTextStep.apply(Self.step(p), to: &t); return nil } catch let r as StyleTextStep.Refusal { return r.reason } catch { return "other" }
        }
        #expect(reason("Hello", ["match": .string("bye"), "bold": .bool(true)]) == "no_match")
        #expect(reason("Hello", ["from": .number(3), "length": .number(5), "bold": .bool(true)]) == "bad_range")
        #expect(reason("👍🏽", ["from": .number(1), "length": .number(1), "size": .number(9)]) == "bad_range", "one character only")
        #expect(reason("Hello", ["match": .string("Hello"), "fontName": .string("NoSuchFont-Bold")]) == "unknown_font")
        #expect(reason("Hello", ["match": .string("Hello")]) == "nothing_to_style")
        #expect(reason("Hello", ["color": .string("red")]) == "bad_color")
    }

    @Test func boldUsesTheFamilysBoldMember() throws {
        var t = Self.text("plain bold")
        _ = try StyleTextStep.apply(Self.step(["match": .string("bold"), "bold": .bool(true)]), to: &t)
        #expect(t.style(at: 7).fontName == "HelveticaNeue-Bold" && t.style(at: 0).fontName == "HelveticaNeue")
        _ = try StyleTextStep.apply(Self.step(["match": .string("bold"), "bold": .bool(false)]), to: &t)
        #expect(t.styles == nil, "back to the layer's own font")
    }

    @Test func theOperationIsListed() throws {
        let op = try #require(AgentAPI.operations.first { $0["name"] as? String == "style_text" })
        #expect(op["paid"] as? Bool == false && op["startsJob"] as? Bool == false)
        let props = try #require((op["params"] as? [String: Any])?["properties"] as? [String: Any])
        #expect((props["bold"] as? [String: Any])?["type"] as? String == "boolean")
        #expect(((props["from"] as? [String: Any])?["description"] as? String)?.contains("grapheme clusters") == true)
        let guide = AgentAPI.guide(port: 9001, appVersion: "1")
        #expect(guide.contains("👍🏽") && guide.contains("\"op\": \"style_text\""))
    }
}

@Suite struct OfflineMessageTests {
    @Test func aModelThatCantBeDownloadedSaysWhatToDo() {
        let e = ModelDownloadError(model: "Depth (Depth Anything V2 Small)", underlying: "The Internet connection appears to be offline.")
        let text = e.errorDescription ?? ""
        #expect(text.contains("Depth (Depth Anything V2 Small)") && text.contains("downloads once"))
        #expect(text.contains("offline. Connect to the internet and try again."), "one full stop, then what to do")
        #expect(text.contains("keeps working offline"))
        let net = OpenRouterError.network("The Internet connection appears to be offline.").errorDescription ?? ""
        #expect(net == "Glimmer couldn't reach the AI service: The Internet connection appears to be offline. Check your internet connection and try again. The tools that run on this Mac keep working.")
        let denied = ModelDownloadError(model: "Depth", underlying: "The operation couldn’t be completed. Operation not permitted").errorDescription ?? ""
        #expect(denied.contains("didn't work: Operation not permitted. Connect") && !denied.contains("couldn’t be completed"))
    }
}
