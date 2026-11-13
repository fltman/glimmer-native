import Foundation
import GlimmerCore
import Testing
@testable import GlimmerAI

@Suite struct AgentPlannerTests {
    @Test func promptListsEveryOpAndItsOptions() {
        let prompt = AgentPlanner.systemPrompt()
        for op in AgentPlanner.ops { #expect(prompt.contains("- \(op.name)")) }
        #expect(prompt.contains("gaussian_blur"))
        #expect(prompt.contains("hue_saturation"))
        #expect(prompt.contains(Preset.all[0].name))
        #expect(prompt.contains("layer.duplicate") || prompt.contains(AgentPlanner.runnableCommands[0].id.rawValue))
    }

    @Test func parsesFencedJSONAndDropsUnknownOps() throws {
        let reply = """
        Sure! Here is the plan:
        ```json
        {"steps": [
          {"op": "add_adjustment", "params": {"type": "black_white", "params": {}}, "rationale": "Mono look."},
          {"op": "teleport", "params": {}},
          "garbage",
          {"op": "apply_filter", "params": {"type": "vignette", "params": {"amount": 0.4}}}
        ], "message": "Black & white with a vignette {braces in strings are fine}."}
        ```
        """
        let plan = try AgentPlanner.parsePlan(reply)
        #expect(plan.steps.map(\.op) == ["add_adjustment", "apply_filter"])
        #expect(plan.droppedOps == ["teleport"])
        #expect(plan.steps[1].object("params")["amount"]?.number == 0.4)
        #expect(plan.steps[0].string("type") == "black_white")
        #expect(plan.message?.contains("braces") == true)
        #expect(!plan.usesAI)
    }

    @Test func proseBecomesAChatAnswer() throws {
        let plan = try AgentPlanner.parsePlan("Curves lets you shape tones.")
        #expect(plan.steps.isEmpty && plan.message == "Curves lets you shape tones.")
    }

    @Test func aiStepsAreFlagged() throws {
        let plan = try AgentPlanner.parsePlan(#"{"steps":[{"op":"generate_layer","params":{"prompt":"a fox"}}]}"#)
        #expect(plan.usesAI)
    }

    @Test func userPromptCarriesContextAndHistory() {
        let ctx = AgentContext(width: 800, height: 600, layerCount: 3, hasSelection: true, activeLayerKind: "raster", activeLayerName: "Photo")
        let p = AgentPlanner.userPrompt(goal: "warmer", context: ctx, history: [("make it b&w", "Added Black & White.")])
        #expect(p.contains("800×600") && p.contains("hasSelection: true") && p.contains("make it b&w") && p.hasSuffix("Return the JSON plan now."))
    }

    @Test func hexColours() {
        #expect(parseHexColor("#ff8000") == SRGBColor(1, 128.0 / 255, 0))
        #expect(parseHexColor("00ff00cc") == SRGBColor(0, 1, 0))
        #expect(parseHexColor("red") == nil)
    }

    @Test func toolSchemasCoverEveryOp() throws {
        let tools = AgentPlanner.toolSchemas()
        #expect(tools.count == AgentPlanner.ops.count)
        let data = try JSONSerialization.data(withJSONObject: tools)
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains("\"enum\""))
        let filter = tools.compactMap { $0["function"] as? [String: Any] }.first { $0["name"] as? String == "apply_filter" }
        let params = filter?["parameters"] as? [String: Any]
        #expect((params?["required"] as? [String])?.contains("type") == true)
        let text_ = tools.compactMap { $0["function"] as? [String: Any] }.first { $0["name"] as? String == "add_text" }
        let required = ((text_?["parameters"] as? [String: Any])?["required"] as? [String]) ?? []
        #expect(required.contains("text") && !required.contains("color") && !required.contains("size"))
    }

    @Test func toolCallsBecomeSteps() throws {
        let response = OpenRouterClient.ToolResponse(text: "Black and white with a vignette.", toolCalls: [
            .init(name: "add_adjustment", arguments: #"{"type":"black_white","params":{},"rationale":"Monochrome."}"#),
            .init(name: "apply_filter", arguments: #"{"type":"vignette","params":"{\"amount\":0.4}"}"#),
            .init(name: "teleport", arguments: "{}"),
        ], cost: nil)
        let plan = try AgentPlanner.plan(from: response)
        #expect(plan.steps.map(\.op) == ["add_adjustment", "apply_filter"])
        #expect(plan.steps[0].rationale == "Monochrome.")
        #expect(plan.steps[0].params["rationale"] == nil)
        #expect(plan.steps[1].object("params")["amount"]?.number == 0.4)
        #expect(plan.droppedOps == ["teleport"])
        #expect(plan.message == "Black and white with a vignette.")
    }

    @Test func toolReplyWithoutCallsIsAChatAnswer() throws {
        let plan = try AgentPlanner.plan(from: .init(text: "Which layer do you mean?", toolCalls: [], cost: nil))
        #expect(plan.steps.isEmpty && plan.message == "Which layer do you mean?")
        #expect(throws: AgentError.self) { try AgentPlanner.plan(from: .init(text: " ", toolCalls: [], cost: nil)) }
    }

    @Test func toolMessagesCarryHistoryAndState() {
        let context = AgentContext(width: 800, height: 600, layerCount: 2, hasSelection: true,
                                   activeLayerKind: "raster", activeLayerName: "Photo")
        let messages = AgentPlanner.toolMessages(goal: "warmer", context: context, history: [("hi", "Hello!")])
        #expect(messages.count == 4)
        #expect(messages[1]["content"] as? String == "hi" && messages[2]["role"] as? String == "assistant")
        let last = messages[3]["content"] as? String ?? ""
        #expect(last.contains("800×600") && last.contains("there is a selection") && last.hasSuffix("warmer"))
    }

    @Test func extractsToolCallsFromAResponse() {
        let json: [String: Any] = ["choices": [["message": [
            "content": NSNull(),
            "tool_calls": [["id": "1", "type": "function",
                            "function": ["name": "select_all", "arguments": "{}"]],
                           ["id": "2", "type": "function",
                            "function": ["name": "fill", "arguments": ["color": "#ff0000"]]]],
        ]]]]
        let calls = OpenRouterClient.extractToolCalls(from: json)
        #expect(calls.map(\.name) == ["select_all", "fill"])
        #expect(calls[1].arguments.contains("#ff0000"))
    }
}

@Suite struct AgentVisionAndStreamingTests {
    @Test func imageRidesAlongWithTheGoal() throws {
        let context = AgentContext(width: 8, height: 8, layerCount: 1, hasSelection: false, activeLayerKind: "raster", activeLayerName: "A")
        let messages = AgentPlanner.toolMessages(goal: "warmer", context: context, history: [], image: Data([1, 2, 3]))
        let parts = try #require(messages.last?["content"] as? [[String: Any]])
        #expect(parts.count == 2 && (parts[0]["text"] as? String)?.hasSuffix("warmer") == true)
        #expect(((parts[1]["image_url"] as? [String: Any])?["url"] as? String) == "data:image/jpeg;base64,AQID")
    }

    @Test func reviewGetsBothPicturesAndNoPaidTools() throws {
        let m = AgentPlanner.reviewMessages(goal: "darker", steps: [AgentStep(op: "add_adjustment", params: ["type": .string("exposure")])],
                                            before: Data([1]), after: Data([2]))
        let parts = try #require(m[1]["content"] as? [[String: Any]])
        #expect(parts.count == 3 && (parts[0]["text"] as? String)?.contains("add_adjustment") == true)
        let names = AgentPlanner.reviewToolSchemas().compactMap { ($0["function"] as? [String: Any])?["name"] as? String }
        #expect(names.contains("add_adjustment") && !names.contains("generate_layer") && !names.contains("upscale"))
    }

    @Test func streamedChunksAreMerged() throws {
        var acc = OpenRouterClient.StreamAccumulator()
        func chunk(_ delta: [String: Any]) -> [String: Any] { ["choices": [["delta": delta]]] }
        #expect(acc.consume(chunk(["content": "Black "])) == "Black ")
        #expect(acc.consume(chunk(["tool_calls": [["index": 0, "function": ["name": "add_adjustment", "arguments": "{\"type\":"]]]])) == nil)
        _ = acc.consume(chunk(["tool_calls": [["index": 0, "function": ["arguments": "\"black_white\"}"]],
                                              ["index": 1, "function": ["name": "deselect", "arguments": ""]]]]))
        _ = acc.consume(chunk(["content": "and white."]))
        _ = acc.consume(["choices": [], "usage": ["cost": 0.002]])
        let r = acc.response
        #expect(r.text == "Black and white." && r.cost == 0.002)
        #expect(r.toolCalls == [.init(name: "add_adjustment", arguments: "{\"type\":\"black_white\"}"), .init(name: "deselect", arguments: "{}")])
    }
}

@Suite struct SuggestionTests {
    @Test func parsesAndLimitsSuggestions() {
        let text = """
        ```json
        {"suggestions": [{"title": "Warm Glow", "goal": "Warm the sunset tones."}, {"title": "Warm Glow", "goal": "dup"},
         {"title": "", "goal": "x"}, {"title": "Moody B&W", "goal": "Convert to high-contrast black and white."},
         {"title": "Sharpen Bridge", "goal": "Sharpen the bridge."}, {"title": "Fourth", "goal": "no"}]}
        ```
        """
        let s = AgentPlanner.parseSuggestions(text)
        #expect(s.map(\.title) == ["Warm Glow", "Moody B&W", "Sharpen Bridge"])
        #expect(AgentPlanner.parseSuggestions("sorry").isEmpty)
    }
}
