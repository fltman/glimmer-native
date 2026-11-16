import Foundation
import Testing
@testable import GlimmerAI

/// With the other adapter tests: they share the made-up provider, so they run one at a time.
extension ChatAdapterTests {
    /// An answer in the form of Ollama's /api/chat documentation: arguments as an object.
    static let ollamaAnswer = #"""
    {"model":"qwen3","created_at":"2026-11-16T00:00:00Z","message":{"role":"assistant","content":"","tool_calls":[{"type":"function","function":{"index":0,"name":"crop","arguments":{"aspect":"16:9"}}}]},"done":true}
    """#
    @Test func thePlannerRequestIsNativeShortAndStatesItsContext() async throws {
        FakeProvider.script([(200, Self.ollamaAnswer)])
        let model = OllamaTextModel(baseURL: URL(string: "http://127.0.0.1:11434/v1")!, model: "qwen3:8b", session: FakeProvider.session)
        let (plan, cost) = try await AgentPlanner.plan(goal: "Crop to 16:9", context: context, history: [], image: Data([1, 2, 3]), model: model)
        #expect(plan.steps.map(\.op) == ["crop"] && plan.steps[0].string("aspect") == "16:9" && cost == nil)
        let sent = try #require(FakeProvider.requests.first)
        #expect(sent.url.absoluteString == "http://127.0.0.1:11434/api/chat")
        #expect(sent.headers["Authorization"] == nil)
        #expect((sent.json["options"] as? [String: Any])?["num_ctx"] as? Int == 16_384)
        #expect(sent.json["stream"] as? Bool == false && sent.json["tool_choice"] == nil)
        // Only the everyday operations, and no sibling tools.
        let names = Set((sent.json["tools"] as? [[String: Any]] ?? []).compactMap { ($0["function"] as? [String: Any])?["name"] as? String })
        #expect(names == Set(AgentPlanner.ops.map(\.name)).intersection(AgentAPI.coreOps) && names.count >= 8 && names.count <= 15)
        // The picture travels as base64 in `images`, the text as a plain string.
        let user = try #require((sent.json["messages"] as? [[String: Any]])?.last)
        #expect(user["content"] is String && (user["images"] as? [String]) == [Data([1, 2, 3]).base64EncodedString()])
    }

    @Test func aModelWithoutToolsFailsWithOllamasOwnWords() async {
        FakeProvider.script([(400, #"{"error":"registry.ollama.ai/library/gemma3:4b does not support tools"}"#)])
        let model = OllamaTextModel(model: "gemma3:4b", session: FakeProvider.session)
        await #expect { _ = try await AgentPlanner.plan(goal: "g", context: context, history: [], model: model) } throws: {
            ($0 as? LocalizedError)?.errorDescription == "Ollama answered HTTP 400: registry.ollama.ai/library/gemma3:4b does not support tools"
        }
    }

    @Test func jsonRepliesAskForJSON() async throws {
        FakeProvider.script([(200, #"{"message":{"role":"assistant","content":"{\"suggestions\":[]}"},"done":true}"#)])
        let model = OllamaTextModel(model: "m", session: FakeProvider.session)
        let reply = try await model.reply(system: "s", user: "u", images: [], imageType: "image/png", json: true, temperature: 0.2)
        #expect(reply.text == #"{"suggestions":[]}"#)
        #expect(FakeProvider.requests.first?.json["format"] as? String == "json")
    }
}

@Suite struct LocalModelEvaluationTests {
    private func plan(_ steps: [(String, [String: JSONValue])], dropped: [String] = []) -> AgentPlan {
        AgentPlan(steps: steps.map { AgentStep(op: $0.0, params: $0.1) }, message: nil, droppedOps: dropped)
    }

    @Test func theCasesAreHalfSwedishAndUseOnlyTheShortList() {
        #expect(LocalModelEvaluation.scored.count == 14 && LocalModelEvaluation.cases.count == 15)   // one known gap, not counted
        #expect(LocalModelEvaluation.scored.filter { $0.language == "sv" }.count == 7)
        #expect(LocalModelEvaluation.scored.filter(\.answerOnly).count == 2)   // one in each language: no invented figures
        for c in LocalModelEvaluation.cases where !c.answerOnly {
            #expect(AgentAPI.coreOps.contains(c.op) && AgentPlanner.op(named: c.op) != nil, "\(c.op)")
        }
    }

    @Test func judging() {
        let crop = LocalModelEvaluation.cases[2]
        #expect(LocalModelEvaluation.judge(plan([("crop", ["aspect": .string("16:9")])]), crop))
        #expect(!LocalModelEvaluation.judge(plan([("crop", ["aspect": .string("4:3")])]), crop))
        #expect(!LocalModelEvaluation.judge(plan([("crop", ["aspect": .string("16:9"), "shape": .string("wide")])]), crop))   // a made-up parameter
        #expect(!LocalModelEvaluation.judge(plan([("crop", ["aspect": .string("16:9")])], dropped: ["make_wide"]), crop))       // a made-up tool
        #expect(!LocalModelEvaluation.judge(plan([]), crop))
        let half = LocalModelEvaluation.cases[9]
        #expect(LocalModelEvaluation.judge(plan([("resize_image", ["scale": .number(0.5)])]), half))
        #expect(!LocalModelEvaluation.judge(plan([("resize_image", ["scale": .number(2)])]), half))
        // The test document is 2400 × 1600: half of it is also a width of 1200, a height of 800, or both.
        #expect(LocalModelEvaluation.judge(plan([("resize_image", ["width": .number(1200)])]), half))
        #expect(LocalModelEvaluation.judge(plan([("resize_image", ["width": .number(1200), "height": .number(800)])]), half))
        #expect(!LocalModelEvaluation.judge(plan([("resize_image", ["width": .number(600)])]), half))
        #expect(!LocalModelEvaluation.judge(plan([("resize_image", ["width": .number(1200), "height": .number(1600)])]), half))
    }

    @Test func aModelThatAnswersRightPassesAndASlowOrWrongOneDoesNot() async {
        let good = ScriptedTextModel()
        good.calls = []   // answers nothing: fails every case
        let report = await LocalModelEvaluation.run(good, cases: Array(LocalModelEvaluation.cases.prefix(2)))
        #expect(report.passed == 0 && !report.passes)
        let outcomes = LocalModelEvaluation.cases.map { LocalModelEvaluation.Outcome(goal: $0.goal, language: $0.language, seconds: 5, passed: true, got: "") }
        #expect(LocalModelEvaluation.Report(model: "m", outcomes: outcomes).passes)
        var slow = outcomes; slow[0] = .init(goal: "g", language: "en", seconds: 61, passed: true, got: "")
        #expect(!LocalModelEvaluation.Report(model: "m", outcomes: slow).passes)
        var swedishWeak = outcomes
        for i in [1, 3] { swedishWeak[i] = .init(goal: "g", language: "sv", seconds: 5, passed: false, got: "") }
        #expect(!LocalModelEvaluation.Report(model: "m", outcomes: swedishWeak).passes)   // 10 of 12, but only 4 of 6 in Swedish
    }

    /// The real thing, against Ollama on this Mac: GLIMMER_LOCAL_EVAL=<model>[,<model>…]. Free; nothing leaves the Mac.
    /// Each outcome is appended to GLIMMER_LOCAL_EVAL_LOG as it comes.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["GLIMMER_LOCAL_EVAL"] != nil), .timeLimit(.minutes(60)))
    func evaluateInstalledModels() async throws {
        let env = ProcessInfo.processInfo.environment
        let log = env["GLIMMER_LOCAL_EVAL_LOG"].map { URL(fileURLWithPath: $0) }
        @Sendable func say(_ line: String) {
            print(line)
            guard let log else { return }
            let data = Data((line + "\n").utf8)
            if let h = try? FileHandle(forWritingTo: log) { h.seekToEndOfFile(); h.write(data); try? h.close() } else { try? data.write(to: log) }
        }
        for name in (env["GLIMMER_LOCAL_EVAL"] ?? "").split(separator: ",").map(String.init) {
            let abilities = try await OllamaTextModel.abilities(of: name)
            say("EVAL \(name): tools \(abilities.tools), vision \(abilities.vision), context length \(abilities.contextLength.map(String.init) ?? "?")")
            guard abilities.tools else { say("EVAL \(name): not evaluated, Ollama lists it without tools"); continue }
            let thinks = env["GLIMMER_LOCAL_EVAL_THINK"] == "1"
            say("EVAL \(name): think \(thinks)")
            let report = await LocalModelEvaluation.run(OllamaTextModel(model: name, thinks: thinks)) { o in
                say("EVAL \(name) | \(o.knownGap ? (o.passed ? "gap+" : "gap-") : o.passed ? "ok  " : "FAIL") | \(String(format: "%5.1f", o.seconds)) s | \(o.language) | \(o.goal) -> \(o.got)")
            }
            let en = report.passed(language: "en"), sv = report.passed(language: "sv")
            say("EVAL \(name): \(report.passed) of \(report.scored.count) (English \(en.0)/\(en.1), Swedish \(sv.0)/\(sv.1)), median \(String(format: "%.1f", report.median)) s, slowest \(String(format: "%.1f", report.slowest)) s: \(report.passes ? "PASSES" : "does not pass")")
            if !report.gapLine.isEmpty { say("EVAL \(name):\(report.gapLine)") }
            // Ollama keeps the model loaded (several GB) for minutes; Apple's on-device model then gets no memory. Unload it.
            await OllamaTextModel.unload(name)
        }
    }
}

/// OpenRouter's documented Image API, against answers in the documented form.
extension ChatAdapterTests {
    /// A 1×1 PNG.
    static let pixel = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="

    private func imageModel(_ route: OpenRouterImageModel.Route) -> OpenRouterImageModel {
        OpenRouterImageModel(client: OpenRouterClient(apiKey: "sk-or", configuration: AIProvider.openRouter.chatConfiguration(), session: FakeProvider.session),
                             model: "google/gemini-3-pro-image", route: route, cacheDirectory: nil)
    }

    @Test func theImageAPIGetsPromptAndReferencesAndReturnsThePictureAndItsCost() async throws {
        FakeProvider.script([(200, #"{"created":1,"data":[{"b64_json":"\#(Self.pixel)","media_type":"image/png"}],"usage":{"prompt_tokens":3,"completion_tokens":1120,"total_tokens":1123,"cost":0.134}}"#)])
        let input = RGBAImage(width: 4, height: 4, fill: SIMD4(10, 20, 30, 255))
        let result = try await imageModel(.images).generate(prompt: "Make it snowy", images: [input], seed: 7)
        #expect(result.image.width == 1 && result.image.height == 1 && result.cost == 0.134)
        let sent = try #require(FakeProvider.requests.first)
        #expect(sent.url.absoluteString == "https://openrouter.ai/api/v1/images")
        #expect(sent.headers["Authorization"] == "Bearer sk-or")
        #expect(sent.json["model"] as? String == "google/gemini-3-pro-image" && sent.json["prompt"] as? String == "Make it snowy")
        #expect(sent.json["seed"] as? Int == 7 && sent.json["modalities"] == nil && sent.json["messages"] == nil)
        let reference = try #require((sent.json["input_references"] as? [[String: Any]])?.first)
        #expect(reference["type"] as? String == "image_url")
        #expect(((reference["image_url"] as? [String: Any])?["url"] as? String)?.hasPrefix("data:image/png;base64,") == true)
    }

    @Test func plainGenerationSendsNoReferences() async throws {
        FakeProvider.script([(200, #"{"data":[{"b64_json":"\#(Self.pixel)","media_type":"image/png"}],"usage":{"cost":0.03}}"#)])
        _ = try await imageModel(.images).generate(prompt: "A red balloon", images: [], seed: nil)
        let sent = try #require(FakeProvider.requests.first)
        #expect(sent.json["input_references"] == nil && sent.json["seed"] == nil)
    }

    @Test func anAnswerWithoutAPictureSaysSo() async {
        FakeProvider.script([(200, #"{"data":[],"usage":{"cost":0}}"#)])
        await #expect { _ = try await imageModel(.images).generate(prompt: "p", images: [], seed: nil) } throws: {
            if case OpenRouterError.noImageInResponse = $0 { true } else { false }
        }
    }

    /// The route Glimmer has used so far is unchanged, and still the default.
    @Test func theOldRouteIsUntouchedAndTheDefault() async throws {
        FakeProvider.script([(200, #"{"choices":[{"message":{"role":"assistant","content":"","images":[{"type":"image_url","image_url":{"url":"data:image/png;base64,\#(Self.pixel)"}}]}}],"usage":{"cost":0.1}}"#)])
        let old = OpenRouterImageModel(client: OpenRouterClient(apiKey: "sk-or", configuration: AIProvider.openRouter.chatConfiguration(), session: FakeProvider.session),
                                       model: "google/gemini-3-pro-image-preview", cacheDirectory: nil)
        #expect(old.route == .chat)
        _ = try await old.generate(prompt: "p", images: [], seed: nil)
        let sent = try #require(FakeProvider.requests.first)
        #expect(sent.url.absoluteString == "https://openrouter.ai/api/v1/chat/completions")
        #expect(sent.json["modalities"] as? [String] == ["image", "text"])
    }
}

/// The Responses adapter (OpenAI, xAI) against answers in the form their documentation shows.
extension ChatAdapterTests {
    static let responsesAnswer = #"""
    {"id":"resp_1","object":"response","status":"completed","model":"m","output":[
      {"type":"reasoning","id":"rs_1","summary":[]},
      {"type":"message","id":"msg_1","role":"assistant","content":[{"type":"output_text","text":"Black and white, then cropped."}]},
      {"id":"fc_1","call_id":"call_1","type":"function_call","name":"add_adjustment","arguments":"{\"type\":\"black_white\"}"},
      {"id":"fc_2","call_id":"call_2","type":"function_call","name":"crop","arguments":"{\"aspect\":\"16:9\"}"}],
     "usage":{"input_tokens":900,"output_tokens":40,"total_tokens":940}}
    """#

    @Test func openAIGetsAResponsesRequestAndItsToolCallsBecomeThePlan() async throws {
        FakeProvider.script([(200, Self.responsesAnswer)])
        let model = try #require(AIProvider.named("openai")?.textModel(key: "sk-test", model: "some-model", session: FakeProvider.session))
        let heard = NSLock(); nonisolated(unsafe) var text = ""
        let (plan, cost) = try await AgentPlanner.plan(goal: "Black and white, 16:9", context: context, history: [("earlier", "done")], image: Data([7]), model: model) { t in heard.withLock { text = t } }
        #expect(plan.steps.map(\.op) == ["add_adjustment", "crop"] && plan.message == "Black and white, then cropped." && cost == nil)
        #expect(heard.withLock { text } == "Black and white, then cropped.")
        let sent = try #require(FakeProvider.requests.first)
        #expect(sent.url.absoluteString == "https://api.openai.com/v1/responses")
        #expect(sent.headers["Authorization"] == "Bearer sk-test")
        #expect(sent.json["messages"] == nil && sent.json["temperature"] == nil && sent.json["tool_choice"] == nil)
        // Tools in the flat form.
        let tool = try #require((sent.json["tools"] as? [[String: Any]])?.first)
        #expect(tool["type"] as? String == "function" && tool["name"] is String && tool["parameters"] != nil && tool["function"] == nil)
        // The conversation as input items; the picture as input_image with its data URL.
        let input = try #require(sent.json["input"] as? [[String: Any]])
        #expect(input.first?["role"] as? String == "system" && input.count == 4)
        let parts = try #require(input.last?["content"] as? [[String: Any]])
        #expect(parts.contains { $0["type"] as? String == "input_text" })
        #expect(parts.contains { $0["type"] as? String == "input_image" && ($0["image_url"] as? String)?.hasPrefix("data:image/") == true })
    }

    @Test func xAIGoesToItsOwnAddressInTheSameForm() async throws {
        FakeProvider.script([(200, Self.responsesAnswer)])
        let model = try #require(AIProvider.named("xai")?.textModel(key: "xai-test", model: "some-model", session: FakeProvider.session))
        let reply = try await model.reply(system: "s", user: "u", images: [Data([1])], imageType: "image/jpeg", json: true, temperature: 0.7)
        #expect(reply.text == "Black and white, then cropped.")
        let sent = try #require(FakeProvider.requests.first)
        #expect(sent.url.absoluteString == "https://api.x.ai/v1/responses" && sent.headers["Authorization"] == "Bearer xai-test")
        #expect(sent.json["temperature"] == nil && sent.json["response_format"] == nil && sent.json["text"] == nil)
        let user = try #require((sent.json["input"] as? [[String: Any]])?.last?["content"] as? [[String: Any]])
        #expect(user.last?["image_url"] as? String == "data:image/jpeg;base64," + Data([1]).base64EncodedString())
    }

    @Test func aRefusalFromTheResponsesAPIIsShownAsItCame() async throws {
        FakeProvider.script([(400, #"{"error":{"message":"The model `gpt-0` does not exist.","type":"invalid_request_error","code":"model_not_found"}}"#)])
        let model = try #require(AIProvider.named("openai")?.textModel(key: "k", model: "gpt-0", session: FakeProvider.session))
        await #expect { _ = try await AgentPlanner.plan(goal: "g", context: context, history: [], model: model) } throws: {
            ($0 as? LocalizedError)?.errorDescription == "OpenAI answered HTTP 400: The model `gpt-0` does not exist."
        }
    }

    @Test func theRegisterBuildsTheRightAdapterAndNothingForWhatIsNotBuilt() {
        #expect(AIProvider.named("openai")?.textModel(key: "k", model: "m") is ResponsesTextModel)
        #expect(AIProvider.named("xai")?.textModel(key: "k", model: "m") is ResponsesTextModel)
        #expect(AIProvider.named("berget")?.textModel(key: "k", model: "m") is OpenRouterTextModel)
        #expect(AIProvider.named("ollama")?.textModel(key: "", model: "m") is OllamaTextModel)
        #expect(AIProvider.named("anthropic")?.textModel(key: "k", model: "m") is AnthropicTextModel)
        #expect(AIProvider.named("mlx")?.textModel(key: "", model: "m") == nil)
        #expect(AIProvider.named("fal")?.textModel(key: "k", model: "m") == nil)
        #expect(AIProvider.named("openrouter")?.imageModel(key: "k", model: "m") == nil && AIProvider.named("berget")?.imageModel(key: "k", model: "m") == nil)
        // Still hidden: only what Anders has decided is offered.
        #expect(AIProvider.offering(.text).map(\.slug) == ["openrouter", "berget", "grunden", "ollama"])
    }
}

/// The Anthropic adapter against answers in the form of the Messages API.
extension ChatAdapterTests {
    static let claudeAnswer = #"""
    {"id":"msg_1","type":"message","role":"assistant","model":"m","stop_reason":"tool_use","content":[
      {"type":"thinking","thinking":"","signature":"x"},
      {"type":"text","text":"Black and white."},
      {"type":"tool_use","id":"toolu_1","name":"add_adjustment","input":{"type":"black_white"}}],
     "usage":{"input_tokens":900,"output_tokens":40}}
    """#

    @Test func claudeGetsAMessagesRequestAndItsToolUseBecomesThePlan() async throws {
        FakeProvider.script([(200, Self.claudeAnswer)])
        let model = try #require(AIProvider.named("anthropic")?.textModel(key: "sk-ant-test", model: "some-claude", session: FakeProvider.session))
        let (plan, cost) = try await AgentPlanner.plan(goal: "Black and white", context: context, history: [("earlier", "done")], image: Data([7]), model: model)
        #expect(plan.steps.map(\.op) == ["add_adjustment"] && plan.steps[0].string("type") == "black_white")
        #expect(plan.message == "Black and white." && cost == nil)
        let sent = try #require(FakeProvider.requests.first)
        #expect(sent.url.absoluteString == "https://api.anthropic.com/v1/messages")
        #expect(sent.headers["x-api-key"] == "sk-ant-test" && sent.headers["anthropic-version"] == "2026-10-21" && sent.headers["Authorization"] == nil)
        // What the current models refuse is not sent.
        #expect(sent.json["temperature"] == nil && sent.json["tool_choice"] == nil && sent.json["thinking"] == nil)
        #expect(sent.json["max_tokens"] as? Int == 16_000)
        // The system prompt is top-level; the turns are user/assistant only.
        #expect((sent.json["system"] as? String)?.isEmpty == false)
        let turns = try #require(sent.json["messages"] as? [[String: Any]])
        #expect(turns.map { $0["role"] as? String } == ["user", "assistant", "user"])
        let blocks = try #require(turns.last?["content"] as? [[String: Any]])
        let image = try #require(blocks.first { $0["type"] as? String == "image" }?["source"] as? [String: Any])
        #expect(image["type"] as? String == "base64" && image["media_type"] as? String == "image/jpeg" && image["data"] as? String == Data([7]).base64EncodedString())
        // Tools in Anthropic's form.
        let tool = try #require((sent.json["tools"] as? [[String: Any]])?.first)
        #expect(tool["name"] is String && tool["input_schema"] != nil && tool["function"] == nil && tool["type"] == nil)
    }

    @Test func aDeclinedRequestSaysSoAndChangesNothing() async throws {
        FakeProvider.script([(200, #"{"id":"msg_2","type":"message","role":"assistant","stop_reason":"refusal","stop_details":{"type":"refusal","category":"cyber"},"content":[]}"#)])
        let model = try #require(AIProvider.named("anthropic")?.textModel(key: "k", model: "m", session: FakeProvider.session))
        await #expect { _ = try await AgentPlanner.plan(goal: "g", context: context, history: [], model: model) } throws: {
            ($0 as? AnthropicTextModel.Refusal)?.errorDescription == "Claude declined this request (cyber). Nothing was changed."
        }
    }

    @Test func claudesErrorsAndModelListUseItsOwnHeaders() async throws {
        FakeProvider.script([(401, #"{"type":"error","error":{"type":"authentication_error","message":"invalid x-api-key"}}"#),
                             (200, #"{"data":[{"type":"model","id":"claude-example-1","display_name":"Example"}],"has_more":false}"#)])
        let provider = try #require(AIProvider.named("anthropic"))
        let model = try #require(provider.textModel(key: "bad", model: "m", session: FakeProvider.session))
        await #expect { _ = try await model.reply(system: nil, user: "u", images: [], imageType: "image/png", json: false, temperature: 0.2) } throws: {
            ($0 as? LocalizedError)?.errorDescription == "Anthropic answered HTTP 401: invalid x-api-key"
        }
        let models = try await ModelCatalog.fetchTextModels(provider, key: "sk-ant-test", session: FakeProvider.session)
        #expect(models.map(\.id) == ["claude-example-1"])
        let list = try #require(FakeProvider.requests.last)
        #expect(list.url.absoluteString == "https://api.anthropic.com/v1/models" && list.headers["x-api-key"] == "sk-ant-test" && list.headers["anthropic-version"] == "2026-10-21")
    }
}

/// What Ollama has installed, in the form of its /api/tags and /api/show.
extension ChatAdapterTests {
    @Test func installedModelsComeWithWhatOllamaSaysTheyCanDo() async throws {
        FakeProvider.script([
            (200, #"{"models":[{"name":"qwen3:8b","model":"qwen3:8b","size":5225388164},{"name":"gemma3:4b","model":"gemma3:4b","size":3338801804}]}"#),
            (200, #"{"capabilities":["completion","tools","thinking"],"model_info":{"qwen3.context_length":40960}}"#),
            (200, #"{"capabilities":["completion","vision"],"model_info":{"gemma3.context_length":131072}}"#)])
        let models = try await OllamaTextModel.installed(session: FakeProvider.session)
        #expect(models == [OllamaTextModel.Installed(name: "gemma3:4b", tools: false, vision: true, size: 3_338_801_804),
                           OllamaTextModel.Installed(name: "qwen3:8b", tools: true, vision: false, size: 5_225_388_164)])
        #expect(FakeProvider.requests.first?.url.absoluteString == "http://127.0.0.1:11434/api/tags")
    }

    @Test func noServerMeansNoList() async {
        FakeProvider.script([(404, "not found")])
        await #expect(throws: OllamaTextModel.OllamaError.self) { _ = try await OllamaTextModel.installed(session: FakeProvider.session) }
    }
}

/// The image adapters against answers in the form each service's documentation shows.
extension ChatAdapterTests {
    private var input: RGBAImage { RGBAImage(width: 4, height: 4, fill: SIMD4(10, 20, 30, 255)) }
    private func provider(_ slug: String) throws -> AIProvider { try #require(AIProvider.named(slug)) }
    private func dataURL(_ any: Any?) -> Bool { (any as? String)?.hasPrefix("data:image/png;base64,") == true }

    @Test func openAIGeneratesAndEditsWithThePicturesInTheRequest() async throws {
        FakeProvider.script([(200, #"{"created":1,"data":[{"b64_json":"\#(Self.pixel)"}],"usage":{"input_tokens":10,"output_tokens":272}}"#),
                             (200, #"{"created":1,"data":[{"b64_json":"\#(Self.pixel)"}]}"#)])
        let model = try #require(try provider("openai").imageModel(key: "sk-test", model: "some-image-model", session: FakeProvider.session))
        #expect(try await model.generate(prompt: "A red balloon", images: [], seed: nil).image.width == 1)
        _ = try await model.generate(prompt: "Make it snowy", images: [input], seed: nil)
        let sent = FakeProvider.requests
        #expect(sent[0].url.absoluteString == "https://api.openai.com/v1/images/generations" && sent[0].headers["Authorization"] == "Bearer sk-test")
        #expect(sent[0].json["prompt"] as? String == "A red balloon" && sent[0].json["images"] == nil)
        #expect(sent[1].url.absoluteString == "https://api.openai.com/v1/images/edits")
        #expect(dataURL(((sent[1].json["images"] as? [[String: Any]])?.first)?["image_url"]))
    }

    @Test func googleSendsInlinePartsAndReadsThePictureFromTheAnswer() async throws {
        FakeProvider.script([(200, #"{"candidates":[{"content":{"parts":[{"text":"Here you are."},{"inlineData":{"mimeType":"image/png","data":"\#(Self.pixel)"}}]}}]}"#),
                             (200, #"{"candidates":[{"content":{"parts":[{"text":"I can't make that picture."}]}}]}"#)])
        let model = try #require(try provider("google").imageModel(key: "gk", model: "some-image-model", session: FakeProvider.session))
        #expect(try await model.generate(prompt: "Make it snowy", images: [input], seed: nil).image.height == 1)
        let sent = try #require(FakeProvider.requests.first)
        #expect(sent.url.absoluteString == "https://generativelanguage.googleapis.com/v1/models/some-image-model:generateContent")
        #expect(sent.headers["x-goog-api-key"] == "gk" && sent.headers["Authorization"] == nil)
        let parts = try #require(((sent.json["contents"] as? [[String: Any]])?.first)?["parts"] as? [[String: Any]])
        #expect(parts.first?["text"] as? String == "Make it snowy")
        #expect(((parts.last?["inline_data"] as? [String: Any])?["mime_type"] as? String) == "image/png")
        // An answer with words and no picture says what the model said.
        await #expect { _ = try await model.generate(prompt: "p", images: [], seed: nil) } throws: {
            ($0 as? LocalizedError)?.errorDescription?.contains("I can't make that picture.") == true
        }
    }

    @Test func falGetsDataURIsAndNeverAStoredResult() async throws {
        FakeProvider.script([(200, #"{"images":[{"url":"data:image/png;base64,\#(Self.pixel)","content_type":"image/png"}]}"#),
                             (200, #"{"images":[{"url":"data:image/png;base64,\#(Self.pixel)"}]}"#),
                             (200, #"{"images":[{"url":"https://v3.fal.media/files/x/out.png"}]}"#)])
        let model = try #require(try provider("fal").imageModel(key: "fk", model: "fal-ai/some-model", session: FakeProvider.session))
        _ = try await model.generate(prompt: "A red balloon", images: [], seed: 3)
        _ = try await model.generate(prompt: "Make it snowy", images: [input], seed: nil)
        let sent = FakeProvider.requests
        #expect(sent[0].url.absoluteString == "https://fal.run/fal-ai/some-model" && sent[0].headers["Authorization"] == "Key fk")
        #expect(sent[0].json["sync_mode"] as? Bool == true && sent[0].json["seed"] as? Int == 3 && sent[0].json["image_urls"] == nil)
        #expect(sent[1].url.absoluteString == "https://fal.run/fal-ai/some-model/edit")
        #expect(dataURL((sent[1].json["image_urls"] as? [Any])?.first))
        // A link instead of the picture means it was stored at fal: not fetched, and said plainly.
        await #expect { _ = try await model.generate(prompt: "p", images: [], seed: nil) } throws: {
            ($0 as? ProviderHTTPError)?.message.contains("doesn't fetch stored results") == true
        }
        #expect(FakeProvider.requests.count == 3)   // three calls to fal.run, and no request to the stored file
    }

    @Test func hedraUploadsSubmitsWaitsAndDownloads() async throws {
        FakeProvider.script([
            (200, #"{"url":"https://uploads.hedra.example/handle?sig=abc","content_type":"image/png","expires_at":"2026-11-16T09:00:00Z"}"#),
            (202, #"{"job_id":"job_1"}"#),
            (200, #"{"status":"IN_PROGRESS"}"#),
            (200, #"{"status":"COMPLETED"}"#),
            (200, #"{"status":"COMPLETED","outputs":[{"status":"COMPLETED","url":"https://outputs.hedra.example/signed?x=1","asset_id":"asset_1"}]}"#),
            (200, "base64:" + Self.pixel)])
        let model = HedraImageModel(key: "id:secret", model: "some-image-model", session: FakeProvider.session, pollInterval: .milliseconds(5))
        let result = try await model.generate(prompt: "Make it snowy", images: [input], seed: nil)
        #expect(result.image.width == 1)
        let sent = FakeProvider.requests
        #expect(sent.map(\.url.absoluteString) == ["https://api.hedra.com/v3/files", "https://api.hedra.com/v3/models/some-image-model",
                                                  "https://api.hedra.com/v3/jobs/job_1/status", "https://api.hedra.com/v3/jobs/job_1/status",
                                                  "https://api.hedra.com/v3/jobs/job_1", "https://outputs.hedra.example/signed?x=1"])
        // The upload is the picture's bytes in a multipart body.
        #expect(sent[0].headers["Content-Type"]?.hasPrefix("multipart/form-data; boundary=") == true && sent[0].headers["Authorization"] == "Key id:secret")
        #expect(FakeProvider.rawBodies[0].range(of: Data([0x89, 0x50, 0x4E, 0x47])) != nil)
        // The job refers to the upload by its handle, unchanged.
        let image = try #require((((sent[1].json["input"] as? [String: Any])?["images"]) as? [[String: Any]])?.first)
        #expect(image["source"] as? String == "url" && image["url"] as? String == "https://uploads.hedra.example/handle?sig=abc")
        // The key is not sent with the signed download.
        #expect(sent[5].headers["Authorization"] == nil)
    }

    @Test func aFailedHedraJobSaysSoAndAnErrorIsShownAsItCame() async throws {
        FakeProvider.script([(202, #"{"job_id":"job_2"}"#), (200, #"{"status":"FAILED"}"#)])
        let model = HedraImageModel(key: "k", model: "m", session: FakeProvider.session, pollInterval: .milliseconds(5))
        await #expect { _ = try await model.generate(prompt: "p", images: [], seed: nil) } throws: {
            ($0 as? LocalizedError)?.errorDescription == "Hedra answered HTTP 200: The job failed at Hedra."
        }
        FakeProvider.script([(402, #"{"error":"Insufficient wallet balance"}"#)])
        await #expect { _ = try await model.generate(prompt: "p", images: [], seed: nil) } throws: {
            ($0 as? LocalizedError)?.errorDescription == "Hedra answered HTTP 402: Insufficient wallet balance"
        }
    }

    @Test func everyNewImageServiceIsBuiltAndHidden() {
        for slug in ["openai", "google", "fal", "hedra"] {
            #expect(AIProvider.named(slug)?.built.contains(.image) == true && AIProvider.named(slug)?.offers(.image) == false, "\(slug)")
        }
        #expect(AIProvider.offering(.image).map(\.slug) == ["openrouter"])
    }
}

/// The Assistant states no figure it wasn't given.
@Suite struct AssistantNumbersTests {
    let given = ["How big is it?", "2400 1600 1", "Photo"]

    @Test func readsNumbersHoweverTheyAreWritten() {
        #expect(AssistantNumbers.numbers(in: "It is 2,400 by 1 600 px, zoom 0,5 and 12.5 %") == [2400, 1600, 0.5, 12.5])
        #expect(AssistantNumbers.numbers(in: "No figures here.") == [])
    }

    @Test func aGivenFigureStaysAndAnInventedOneGoesWithItsSentence() {
        let right = AssistantNumbers.checked("The document is 2400 × 1600 pixels.", given: given)
        #expect(right.text == "The document is 2400 × 1600 pixels." && right.removed.isEmpty)
        let wrong = AssistantNumbers.checked("Sure. The document is 3000 × 2000 pixels. Anything else?", given: given)
        #expect(wrong.text == "Sure. Anything else?" && wrong.removed == ["number 3000", "number 2000"])
    }

    @Test func aPriceIsNeverTheModelsOwn() {
        let result = AssistantNumbers.checked("Upscaling costs about $0.04 per image. It has 1 layer.", given: given)
        #expect(result.text == "It has 1 layer." && result.removed == ["price 0.04"])
    }

    @Test func stepNumbersAndSharesAreAllowed() {
        let result = AssistantNumbers.checked("Step 2 sets the layer to 50 % opacity.", given: given + [#"{"opacity":0.5}"#], steps: 3)
        #expect(result.removed.isEmpty)
    }

    @Test func whenNothingIsLeftGlimmerStatesWhatItKnows() {
        let context = AgentContext(width: 2400, height: 1600, layerCount: 1, hasSelection: false, activeLayerKind: "pixel", activeLayerName: "Photo")
        var plan = AgentPlan(steps: [], message: "It is 4000 by 3000 pixels.")
        AgentPlanner.checkFigures(&plan, goal: "How big is it?", context: context, history: [], siblingContext: nil)
        #expect(plan.message == "The document is 2400 × 1600 pixels and has 1 layer.")
        #expect(plan.removedFigures == ["number 4000", "number 3000"])
        // The evaluation fails such an answer, and passes one that matches or has no figure.
        let test = LocalModelEvaluation.cases.first { $0.answerOnly }!
        #expect(!LocalModelEvaluation.judge(plan, test))
        #expect(LocalModelEvaluation.judge(AgentPlan(steps: [], message: "2400 × 1600 pixels."), test))
        #expect(!LocalModelEvaluation.judge(AgentPlan(steps: [AgentStep(op: "resize_image")], message: nil), test))
    }
}

extension AssistantNumbersTests {
    @Test func anAnswerThatLostASentenceSaysSoOnce() {
        #expect(AssistantNumbers.noted("Sure.", removed: true) == "Sure. Glimmer left out a figure it could not verify.")
        #expect(AssistantNumbers.noted(nil, removed: true) == AssistantNumbers.notice && AssistantNumbers.noted("Sure.", removed: false) == "Sure.")
        let reply = #"{"distractions":[{"id":"a","label":"sign","rationale":"It takes 40 % of the frame. It is bright.","severity":"high","box":{"x":0.1,"y":0.1,"width":0.2,"height":0.2}}],"message":"Removing it costs $0.02. Found one."}"#
        let parsed = AIPipelines.parseDistractions(reply)
        #expect(parsed.items.first?.rationale == "It is bright.")
        #expect(parsed.message == "Found one. Glimmer left out a figure it could not verify.")
    }

    @Test func aSuggestionKeepsItsProposalButNeverAPrice() {
        let reply = #"{"suggestions":[{"title":"Crop 4:5","goal":"Crop to 4:5 around the face."},{"title":"Upscale","goal":"Upscale it for only $0.05."}]}"#
        #expect(AgentPlanner.parseSuggestions(reply).map(\.title) == ["Crop 4:5"])
    }

    @Test func aCostClaimWithoutAFigureIsTheKnownGap() {
        let gap = LocalModelEvaluation.cases.first(where: \.knownGap)!
        #expect(!LocalModelEvaluation.judge(AgentPlan(steps: [], message: "Yes, generating is free."), gap))
        #expect(LocalModelEvaluation.judge(AgentPlan(steps: [], message: "The `generate_layer` function is an AI job that costs money."), gap))
        #expect(LocalModelEvaluation.judge(AgentPlan(steps: [], message: "No, it is not free."), gap))
        #expect(LocalModelEvaluation.judge(AgentPlan(steps: [], message: "Prices are the service's; the model and its price are shown in Settings › AI."), gap))
        // The verdict leaves it out.
        let outcomes = (0..<12).map { _ in LocalModelEvaluation.Outcome(goal: "g", language: "en", seconds: 1, passed: true, got: "") }
            + [LocalModelEvaluation.Outcome(goal: "gap", language: "en", seconds: 1, passed: false, got: "", knownGap: true)]
        let report = LocalModelEvaluation.Report(model: "m", outcomes: outcomes)
        #expect(report.passed == 12 && report.scored.count == 12 && report.gapLine.contains("0 of 1"))
    }
}

extension AssistantNumbersTests {
    @Test func anInventedFigureNeverShowsWhileTheAnswerArrives() {
        let answer = "Sure, here it is. The document is 3000 × 2000 pixels. It costs $0.04 to enlarge. It has 1 layer and is 2400 wide. Anything else?"
        var everShown: [String] = []
        for end in answer.indices {
            everShown.append(AssistantNumbers.shownWhileArriving(String(answer[...end]), given: given))
        }
        for shown in everShown {
            #expect(!shown.contains("3") && !shown.contains("2000") && !shown.contains("0.04") && !shown.contains("$"), "\(shown)")
        }
        // Text without figures flows as it arrives, and a given figure shows once its sentence is finished.
        #expect(everShown.contains("Sure, he"))
        #expect(everShown.last == "Sure, here it is. It has 1 layer and is 2400 wide. Anything else?")
        #expect(!everShown.contains { $0.hasSuffix("is 24") })   // never half a number
    }

    @Test func thePlannerHandsOnOnlyCheckedTextWhileItArrives() async throws {
        let model = ScriptedTextModel()
        model.streamed = ["The document is 99", "The document is 9999 pixels wide. ", "The document is 9999 pixels wide. Done"]
        model.text = "The document is 9999 pixels wide. Done."
        let seen = ShownTexts()
        let context = AgentContext(width: 2400, height: 1600, layerCount: 1, hasSelection: false, activeLayerKind: "pixel", activeLayerName: "Photo")
        let (plan, _) = try await AgentPlanner.plan(goal: "How wide is it?", context: context, history: [], model: model) { seen.add($0) }
        #expect(!seen.all.contains { $0.contains("9") }, "\(seen.all)")
        #expect(plan.message == "Done." && plan.removedFigures == ["number 9999"])
    }
}

final class ShownTexts: @unchecked Sendable {
    private let lock = NSLock(); private var texts: [String] = []
    func add(_ text: String) { lock.withLock { texts.append(text) } }
    var all: [String] { lock.withLock { texts } }
}
