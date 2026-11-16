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
        #expect(LocalModelEvaluation.cases.count == 12)
        #expect(LocalModelEvaluation.cases.filter { $0.language == "sv" }.count == 6)
        for c in LocalModelEvaluation.cases {
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
            let report = await LocalModelEvaluation.run(OllamaTextModel(model: name)) { o in
                say("EVAL \(name) | \(o.passed ? "ok  " : "FAIL") | \(String(format: "%5.1f", o.seconds)) s | \(o.language) | \(o.goal) -> \(o.got)")
            }
            let en = report.passed(language: "en"), sv = report.passed(language: "sv")
            say("EVAL \(name): \(report.passed) of \(report.outcomes.count) (English \(en.0)/\(en.1), Swedish \(sv.0)/\(sv.1)), median \(String(format: "%.1f", report.median)) s, slowest \(String(format: "%.1f", report.slowest)) s: \(report.passes ? "PASSES" : "does not pass")")
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
