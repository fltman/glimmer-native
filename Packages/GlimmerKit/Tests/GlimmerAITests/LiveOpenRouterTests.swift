import Foundation
import ImageIO
import Testing
@testable import GlimmerAI

/// Real OpenRouter calls. Opt in with GLIMMER_LIVE_AI=1 and OPENROUTER_API_KEY;
/// each run costs a few cents.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["GLIMMER_LIVE_AI"] == "1"))
struct LiveOpenRouterTests {
    let key = ProcessInfo.processInfo.environment["OPENROUTER_API_KEY"] ?? ""

    @Test func keyIsValid() async throws {
        let info = try await OpenRouterClient(apiKey: key).keyInfo()
        print("OpenRouter key OK, usage: \(info.usage ?? -1)")
    }

    @Test func generatesAnImage() async throws {
        let model = OpenRouterImageModel(client: OpenRouterClient(apiKey: key), model: AIDefaults.imageModel,
                                         cacheDirectory: nil)
        let result = try await AIPipelines.generate(prompt: "A single red apple on a white table, studio photo",
                                                    width: 512, height: 512, model: model)
        print("Generated \(result.image.width)×\(result.image.height), cost \(result.cost ?? -1)")
        #expect(result.image.width > 64 && result.image.height > 64)
    }

    @Test func badKeyIsFatalNotRetried() async {
        let client = OpenRouterClient(apiKey: "sk-or-v1-invalid")
        await #expect(throws: OpenRouterError.invalidAPIKey) {
            _ = try await client.keyInfo()
        }
    }

    /// The Assistant's evaluation (LocalModelEvaluation, the set every Assistant model is judged by) against
    /// OpenRouter models: GLIMMER_OPENROUTER_EVAL=<id>[,<id>…], with GLIMMER_LIVE_AI=1. Paid: only with Anders's
    /// yes. Prints each case, the score as the model planned and as the person gets it, and what the run cost
    /// (OpenRouter's own usage figure for the key, read before and after each model).
    @Test(.enabled(if: ProcessInfo.processInfo.environment["GLIMMER_OPENROUTER_EVAL"] != nil), .timeLimit(.minutes(30)))
    func evaluateOpenRouterModels() async throws {
        let client = OpenRouterClient(apiKey: ProcessInfo.processInfo.environment["OPENROUTER_API_KEY"] ?? "")
        for id in (ProcessInfo.processInfo.environment["GLIMMER_OPENROUTER_EVAL"] ?? "").split(separator: ",").map(String.init) {
            let before = try await client.keyInfo().usage ?? 0
            let report = await LocalModelEvaluation.run(OpenRouterTextModel(client: client, model: id)) { o in
                print("EVAL \(id) | \(o.knownGap ? (o.passed ? "gap+" : "gap-") : o.passed ? "ok  " : "FAIL") | \(String(format: "%5.1f", o.seconds)) s | \(o.language) | \(o.goal) -> \(o.got)")
            }
            try await Task.sleep(for: .seconds(5))  // OpenRouter's usage figure catches up
            let after = try await client.keyInfo().usage ?? 0
            let en = report.passed(language: "en"), sv = report.passed(language: "sv")
            print("EVAL \(id): \(report.passed) of \(report.scored.count) (English \(en.0)/\(en.1), Swedish \(sv.0)/\(sv.1)), median \(String(format: "%.1f", report.median)) s, slowest \(String(format: "%.1f", report.slowest)) s: \(report.passes ? "PASSES" : "does not pass")")
            print("EVAL \(id): as the model planned: \(report.passedAsWritten) of \(report.scored.count); as the person gets it: \(report.passed) of \(report.scored.count)")
            if !report.gapLine.isEmpty { print("EVAL \(id):\(report.gapLine)") }
            print("EVAL \(id): cost USD \(String(format: "%.4f", after - before)) (OpenRouter's usage for the key, before \(before), after \(after))")
        }
    }

    @Test func plansWithToolCalls() async throws {
        let context = AgentContext(width: 1600, height: 1200, layerCount: 1, hasSelection: false,
                                   activeLayerKind: "raster", activeLayerName: "Photo")
        let (plan, cost) = try await AgentPlanner.plan(goal: "Make it black and white and add a vignette",
                                                       context: context, history: [],
                                                       model: OpenRouterTextModel(client: OpenRouterClient(apiKey: key), model: AIDefaults.textModel))
        print("Plan: \(plan.steps.map { "\($0.op) \($0.params)" }), message: \(plan.message ?? "-"), cost \(cost ?? -1)")
        #expect(plan.steps.contains { $0.op == "add_adjustment" && $0.string("type") == "black_white" })
        #expect(plan.steps.contains { ($0.op == "apply_filter" && $0.string("type") == "vignette") || $0.op == "apply_preset" })
        #expect(plan.droppedOps.isEmpty)
    }

    /// A flat JPEG of one colour.
    private func jpeg(_ r: Float, _ g: Float, _ b: Float) throws -> Data {
        let image = RGBAImage(width: 64, height: 64, fill: SIMD4(r, g, b, 255)).cgImage
        let data = NSMutableData()
        let dest = try #require(CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil))
        CGImageDestinationAddImage(dest, image, nil)
        #expect(CGImageDestinationFinalize(dest))
        return data as Data
    }

    @Test func streamsAPlanAndSeesTheImage() async throws {
        let context = AgentContext(width: 64, height: 64, layerCount: 1, hasSelection: false,
                                   activeLayerKind: "raster", activeLayerName: "Photo")
        let seen = Seen()
        let (plan, _) = try await AgentPlanner.plan(
            goal: "What single colour fills this image? Answer with the colour name only, call no tools.",
            context: context, history: [], image: try jpeg(230, 20, 20),
            model: OpenRouterTextModel(client: OpenRouterClient(apiKey: key), model: AIDefaults.textModel)) { text in seen.add(text) }
        print("Vision answer: \(plan.message ?? "-"), streamed updates: \(seen.count)")
        #expect(plan.steps.isEmpty)
        #expect(plan.message?.localizedCaseInsensitiveContains("red") == true)
        #expect(seen.count >= 1)
    }

    @Test func suggestsEditsForAnImage() async throws {
        let s = try await AgentPlanner.suggestions(image: try jpeg(40, 40, 60), language: "sv",
                                                   model: OpenRouterTextModel(client: OpenRouterClient(apiKey: key), model: AIDefaults.textModel))
        print("Suggestions: \(s.map { "\($0.title): \($0.goal)" })")
        #expect(s.count == 3)
    }

    @Test func reviewCorrectsAResultThatMissed() async throws {
        // Asked for much darker; "after" is brighter than "before".
        let steps = [AgentStep(op: "add_adjustment", params: ["type": .string("exposure"), "params": .object(["exposure": .number(1)])])]
        let plan = try await AgentPlanner.review(goal: "Make the image much darker", steps: steps,
                                                 before: try jpeg(120, 120, 120), after: try jpeg(220, 220, 220),
                                                 model: OpenRouterTextModel(client: OpenRouterClient(apiKey: key), model: AIDefaults.textModel))
        print("Review: \(plan.steps.map { "\($0.op) \($0.params)" }) — \(plan.message ?? "-")")
        #expect(!plan.steps.isEmpty)
        let ok = try await AgentPlanner.review(goal: "Make the image much darker", steps: steps,
                                               before: try jpeg(220, 220, 220), after: try jpeg(60, 60, 60),
                                               model: OpenRouterTextModel(client: OpenRouterClient(apiKey: key), model: AIDefaults.textModel))
        print("Review of a good result: \(ok.steps.count) steps — \(ok.message ?? "-")")
        #expect(ok.steps.isEmpty)
    }
}

private final class Seen: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func add(_ text: String) { lock.lock(); n += 1; lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return n }
}
