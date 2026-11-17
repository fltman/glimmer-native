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
    /// What arrives before the final text, piece by piece (each is everything so far).
    var streamed: [String] = []

    func reply(system: String?, user: String, images: [Data], imageType: String, json: Bool, temperature: Double) async throws -> TextReply {
        lock.withLock { _asked.append(("reply", temperature, json, images.count, [], false)) }
        return TextReply(text: text, cost: nil)
    }

    func callTools(messages: sending [[String: Any]], tools: sending [[String: Any]], temperature: Double,
                   onText: (@Sendable (String) -> Void)?) async throws -> TextToolReply {
        let names = tools.compactMap { ($0["function"] as? [String: Any])?["name"] as? String }
        lock.withLock { _asked.append(("tools", temperature, false, 0, names, onText != nil)) }
        for partial in streamed { onText?(partial) }
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
        #expect(Set(asked.tools) == Set(AgentPlanner.ops.map(\.name)).subtracting(["develop_raw"]))
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

/// Rules for the app's source that a past crash taught.
@Suite struct AppSourceRuleTests {
    /// Selectable text with an accessibility label of its own crashed the app (endless
    /// recursion inside SwiftUI) the moment VoiceOver or any assistive tool read it: the
    /// Assistant's messages, found 2026-11-16. The speaker is named by the enclosing group instead.
    @Test func selectableTextCarriesNoAccessibilityLabelOfItsOwn() throws {
        let app = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appending(path: "App")
        let files = try FileManager.default.contentsOfDirectory(at: app, includingPropertiesForKeys: nil).filter { $0.pathExtension == "swift" }
        #expect(files.count > 30)
        for file in files {
            let lines = try String(contentsOf: file, encoding: .utf8).components(separatedBy: "\n")
            for (i, line) in lines.enumerated() where line.contains(".textSelection(.enabled)") {
                // The modifiers chained on the same view: the lines before and after that start with a dot.
                // A chain goes on through comment lines and blank lines (the splash's label sat under a comment).
                func continues(_ line: String) -> Bool {
                    let t = line.trimmingCharacters(in: .whitespaces)
                    return t.hasPrefix(".") || t.hasPrefix("//") || t.isEmpty
                }
                var chain: [String] = []
                var j = i - 1
                while j >= 0, continues(lines[j]) { chain.append(lines[j]); j -= 1 }
                j = i + 1
                while j < lines.count, continues(lines[j]) { chain.append(lines[j]); j += 1 }
                let code = chain.filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
                #expect(!code.contains { $0.contains(".accessibilityLabel(") || $0.contains(".accessibilityValue(") },
                        "\(file.lastPathComponent):\(i + 1): selectable text with an accessibility label or value of its own")
            }
        }
    }
}

import NetworkGuard

/// The guard itself (Tests/Support/NetworkGuard).
@Suite struct NetworkGuardTests {
    @Test func itIsLoadedBeforeAnyTestAndFirstInLineEverywhere() {
        #expect(URLSessionConfiguration.default.protocolClasses?.first == NetworkGuard.self)
        #expect(URLSessionConfiguration.ephemeral.protocolClasses?.first == NetworkGuard.self)
    }

    @Test func itRefusesPublicHostsAndLeavesThisMacAlone() {
        guard !NetworkGuard.allowsPublicHosts else { return }
        #expect(NetworkGuard.canInit(with: URLRequest(url: URL(string: "https://api.berget.ai/v1/models")!)))
        #expect(NetworkGuard.canInit(with: URLRequest(url: URL(string: "http://192.168.1.10:11434/api/tags")!)))
        #expect(!NetworkGuard.canInit(with: URLRequest(url: URL(string: "http://127.0.0.1:11434/api/tags")!)))
        #expect(!NetworkGuard.canInit(with: URLRequest(url: URL(string: "http://localhost:9001/glimmer")!)))
        #expect(!NetworkGuard.canInit(with: URLRequest(url: URL(fileURLWithPath: "/tmp/x"))))
    }

    /// The fakes are the only sessions the tests build: a session with its own protocol
    /// classes goes around the guard, so each one must answer everything itself.
    @Test func onlyTheFakesBuildSessionsOfTheirOwn() throws {
        let tests = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        var found: [String] = []
        for case let file as URL in FileManager.default.enumerator(at: tests, includingPropertiesForKeys: nil)! where file.pathExtension == "swift" {
            guard !file.path.contains("/Support/"), file.lastPathComponent != "TextModelTests.swift" else { continue }
            let source = try String(contentsOf: file, encoding: .utf8)
            for (i, line) in source.split(separator: "\n", omittingEmptySubsequences: false).enumerated() where line.contains("URLSession(") {
                found.append("\(file.lastPathComponent):\(i + 1)")
            }
        }
        #expect(found.sorted() == ["ProviderTests.swift:20", "SiblingTests.swift:94"], "\(found)")
    }
}

/// A key never follows an address that came in a service's answer.
@Suite struct KeyStaysHomeTests {
    @Test func aRedirectToAnotherHostIsNotFollowed() async {
        let delegate = KeyStaysHome.shared
        var original = URLRequest(url: URL(string: "https://api.hedra.com/v3/jobs/j1")!)
        original.setValue("Key secret", forHTTPHeaderField: "Authorization")
        let task = FakeProvider.session.dataTask(with: original)   // never resumed
        let response = HTTPURLResponse(url: original.url!, statusCode: 302, httpVersion: nil, headerFields: nil)!
        func follows(_ to: String) async -> Bool {
            await delegate.urlSession(FakeProvider.session, task: task, willPerformHTTPRedirection: response, newRequest: URLRequest(url: URL(string: to)!)) != nil
        }
        #expect(await follows("https://api.hedra.com/v3/jobs/j1/"))
        #expect(await !follows("https://evil.example/collect"))
        #expect(await !follows("http://api.hedra.com/v3/jobs/j1"))        // not down to plain http
        #expect(await !follows("https://api.hedra.com.evil.example/x"))
    }

    @Test func linksAndIdentifiersFromAnAnswerAreNarrow() {
        #expect(KeyStaysHome.fetchable("https://outputs.hedra.example/signed?x=1") != nil)
        #expect(KeyStaysHome.fetchable("http://outputs.hedra.example/x") == nil && KeyStaysHome.fetchable("file:///etc/passwd") == nil && KeyStaysHome.fetchable(nil) == nil)
        #expect(KeyStaysHome.pathSafe("job_1-A9") == "job_1-A9")
        #expect(KeyStaysHome.pathSafe("../../files") == nil && KeyStaysHome.pathSafe("a/b") == nil && KeyStaysHome.pathSafe("j?x=1") == nil && KeyStaysHome.pathSafe("") == nil)
    }

    /// Every call that sends a key goes through the delegate: no plain `session.data(for: request)` in the adapters.
    @Test func everyKeyedCallRefusesForeignRedirects() throws {
        let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appending(path: "Sources/GlimmerAI")
        for name in ["AnthropicTextModel.swift", "ImageProviders.swift", "ResponsesTextModel.swift", "Providers.swift", "OpenRouterClient.swift"] {
            let source = try String(contentsOf: sources.appending(path: name), encoding: .utf8)
            #expect(!source.contains("session.data(for: request)") && !source.contains("session.bytes(for: request)"), "\(name)")
            #expect(source.contains("delegate: KeyStaysHome.shared"), "\(name)")
        }
    }
}

/// With the fake provider, so in the serialized suite that owns it.
extension ChatAdapterTests {
    @Test func hedraRefusesAJobIdThatWouldChangeThePathAndALinkThatIsNotHttps() async throws {
        let model = HedraImageModel(key: "k", model: "m", session: FakeProvider.session, pollInterval: .milliseconds(5))
        FakeProvider.script([(202, #"{"job_id":"../files"}"#)])
        await #expect(throws: (any Error).self) { _ = try await model.generate(prompt: "p", images: [], seed: nil) }
        #expect(FakeProvider.requests.count == 1)   // nothing was asked with that id
        FakeProvider.script([(202, #"{"job_id":"job_3"}"#), (200, #"{"status":"COMPLETED"}"#),
                             (200, #"{"outputs":[{"status":"COMPLETED","url":"http://127.0.0.1:9001/api/v1/status"}]}"#)])
        await #expect(throws: (any Error).self) { _ = try await model.generate(prompt: "p", images: [], seed: nil) }
        #expect(FakeProvider.requests.count == 3)   // the link was not fetched
    }
}
