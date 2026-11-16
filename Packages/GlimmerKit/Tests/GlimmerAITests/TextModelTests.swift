import Foundation
import Testing
@testable import GlimmerAI

/// A text model that answers from a script and records what it was asked: what tests use
/// instead of a provider (no network, no key, no money).
final class ScriptedTextModel: TextModel, @unchecked Sendable {
    let providerName = "Scripted"
    let modelID = "scripted-1"
    private let lock = NSLock()
    private var _asked: [(kind: String, temperature: Double, json: Bool, images: Int, tools: [String], streamed: Bool)] = []
    var asked: [(kind: String, temperature: Double, json: Bool, images: Int, tools: [String], streamed: Bool)] { lock.withLock { _asked } }
    var text = ""
    var calls: [TextToolCall] = []

    func reply(system: String?, user: String, images: [Data], imageType: String, json: Bool, temperature: Double) async throws -> TextReply {
        lock.withLock { _asked.append(("reply", temperature, json, images.count, [], false)) }
        return TextReply(text: text, cost: nil)
    }

    func callTools(messages: sending [[String: Any]], tools: sending [[String: Any]], temperature: Double,
                   onText: (@Sendable (String) -> Void)?) async throws -> TextToolReply {
        let names = tools.compactMap { ($0["function"] as? [String: Any])?["name"] as? String }
        lock.withLock { _asked.append(("tools", temperature, false, 0, names, onText != nil)) }
        onText?(text)
        return TextToolReply(text: text, toolCalls: calls, cost: nil)
    }
}

@Suite struct TextModelTests {
    private let context = AgentContext(width: 800, height: 600, layerCount: 1, hasSelection: false, activeLayerKind: "pixel", activeLayerName: "Photo")

    @Test func thePlannerGoesThroughTheTextModel() async throws {
        let model = ScriptedTextModel()
        model.text = "Black and white."
        model.calls = [TextToolCall(name: "add_adjustment", arguments: #"{"type":"black_white"}"#)]
        let (plan, cost) = try await AgentPlanner.plan(goal: "Make it black and white", context: context, history: [], model: model)
        #expect(plan.steps.map(\.op) == ["add_adjustment"])
        #expect(plan.message == "Black and white.")
        #expect(cost == nil)
        let asked = try #require(model.asked.first)
        #expect(asked.kind == "tools" && asked.temperature == 0.2 && !asked.streamed)
        #expect(Set(asked.tools) == Set(AgentPlanner.ops.map(\.name)))
    }

    @Test func thePlannerStreamsWhenAsked() async throws {
        let model = ScriptedTextModel()
        model.text = "Done."
        let seen = NSLock()
        nonisolated(unsafe) var heard = ""
        _ = try await AgentPlanner.plan(goal: "Hello", context: context, history: [], model: model) { text in seen.withLock { heard = text } }
        #expect(seen.withLock { heard } == "Done.")
        #expect(model.asked.first?.streamed == true)
    }

    @Test func reviewOffersOnlyFreeTools() async throws {
        let model = ScriptedTextModel()
        model.text = "Looks right."
        _ = try await AgentPlanner.review(goal: "g", steps: [], before: Data([1]), after: Data([2]), model: model)
        let paid = Set(AgentPlanner.ops.filter(\.isAIJob).map(\.name))
        #expect(Set(model.asked[0].tools).isDisjoint(with: paid))
    }

    @Test func suggestionsAndDistractionsAskForJSONWithThePicture() async throws {
        let model = ScriptedTextModel()
        model.text = #"{"suggestions":[]}"#
        _ = try await AgentPlanner.suggestions(image: Data([1, 2, 3]), language: "en", model: model)
        #expect(model.asked[0].kind == "reply" && model.asked[0].json && model.asked[0].images == 1 && model.asked[0].temperature == 0.7)
        model.text = #"{"distractions":[]}"#
        _ = try await AIPipelines.findDistractions(RGBAImage(width: 8, height: 8, fill: SIMD4(1, 2, 3, 255)), model: model)
        #expect(model.asked[1].json && model.asked[1].images == 1 && model.asked[1].temperature == 0.2)
    }
}

/// No text request goes around the one door: the provider's client is spoken to only by its
/// adapter, and the app chooses a text model in exactly one place.
@Suite struct TextModelGuardTests {
    private static let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    private static func swiftFiles(_ folder: String) throws -> [(path: String, text: String)] {
        let root = repo.appending(path: folder)
        let found = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?.compactMap { $0 as? URL } ?? []
        return try found.filter { $0.pathExtension == "swift" }.map { ($0.path.replacingOccurrences(of: repo.path + "/", with: ""), try String(contentsOf: $0, encoding: .utf8)) }
    }

    @Test func onlyTheAdapterCallsTheClientsTextMethods() throws {
        let files = try Self.swiftFiles("Packages/GlimmerKit/Sources") + Self.swiftFiles("App")
        #expect(files.count > 50)
        for (path, text) in files where !path.hasSuffix("GlimmerAI/OpenRouterClient.swift") && !path.hasSuffix("GlimmerAI/TextModel.swift") {
            for call in [".textCompletion(", ".toolCompletion(", ".toolCompletionStreaming("] {
                #expect(!text.contains(call), "\(path) calls \(call) itself; go through a TextModel")
            }
        }
    }

    @Test func theAppBuildsATextModelInOnePlace() throws {
        let app = try Self.swiftFiles("App")
        // The app never names an adapter: it asks the register for the chosen service's model, in one place.
        for (path, text) in app {
            for adapter in ["OpenRouterTextModel(", "ResponsesTextModel(", "OllamaTextModel(", "AnthropicTextModel("] {
                #expect(!text.contains(adapter), "\(path) builds \(adapter) itself")
            }
        }
        let makers = app.filter { $0.text.contains(".textModel(key:") }.map(\.path)
        #expect(makers == ["App/AIController.swift"])
        // The text model setting is read there and nowhere else (Settings edits it through @AppStorage).
        for (path, text) in app where path != "App/AIController.swift" {
            #expect(!text.contains("forKey: AIDefaults.textModelKey"), "\(path) reads the text model setting itself")
        }
    }
}
