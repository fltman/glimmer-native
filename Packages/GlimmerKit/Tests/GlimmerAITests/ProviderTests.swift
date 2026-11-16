import Foundation
import Testing
@testable import GlimmerAI

/// A made-up provider behind a URLProtocol: answers in the form the service's documentation
/// shows, and records what it was sent. No sockets, no keys, no money.
final class FakeProvider: URLProtocol, @unchecked Sendable {
    struct Seen: Sendable { var url: URL; var headers: [String: String]; var body: [String: String] }
    nonisolated(unsafe) static var seen: [(url: URL, headers: [String: String], json: [String: Any])] = []
    nonisolated(unsafe) static var answers: [(status: Int, body: String)] = []
    static let lock = NSLock()

    static func script(_ answers: [(Int, String)]) { lock.withLock { seen = []; self.answers = answers.map { ($0.0, $0.1) } } }
    static var requests: [(url: URL, headers: [String: String], json: [String: Any])] { lock.withLock { seen } }
    static var session: URLSession {
        let c = URLSessionConfiguration.ephemeral
        c.protocolClasses = [FakeProvider.self]
        return URLSession(configuration: c)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        var body = request.httpBody ?? Data()
        if body.isEmpty, let stream = request.httpBodyStream {
            stream.open(); var buf = [UInt8](repeating: 0, count: 65536)
            while stream.hasBytesAvailable { let n = stream.read(&buf, maxLength: buf.count); if n <= 0 { break }; body.append(buf, count: n) }
            stream.close()
        }
        let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
        let answer = Self.lock.withLock { () -> (status: Int, body: String) in
            Self.seen.append((request.url!, request.allHTTPHeaderFields ?? [:], json))
            return Self.answers.isEmpty ? (500, "{}") : Self.answers.removeFirst()
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: answer.status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(answer.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}

@Suite struct ProviderRegisterTests {
    /// The slugs the series agreed on (the-apps/PROVIDERS.md, rule 1), for what Glimmer uses.
    @Test func slugsAreTheSeriesOwn() {
        #expect(AIProvider.all.map(\.slug) == ["openrouter", "openai", "anthropic", "xai", "google", "berget", "grunden", "fal", "hedra", "ollama", "mlx"])
        #expect(Set(AIProvider.all.map(\.slug)).count == AIProvider.all.count)
        for p in AIProvider.all {
            #expect(p.slug == p.slug.lowercased() && !p.slug.contains(" "))
            #expect(URL(string: p.baseURL)?.host() != nil, "\(p.slug)")
            #expect(p.serves.contains(.text) == (p.textAdapter != nil), "\(p.slug)")
        }
    }

    /// Hidden until tried: only OpenRouter (in use), and Berget and Grunden (Anders's exception) are offered.
    @Test func onlyWhatIsDecidedIsOffered() {
        #expect(AIProvider.offering(.text).map(\.slug) == ["openrouter", "berget", "grunden"])
        #expect(AIProvider.offering(.image).map(\.slug) == ["openrouter"])
        for p in AIProvider.all {
            #expect(p.offered.isSubset(of: p.built), "\(p.slug) is offered for something that isn't built")
            #expect(p.built.isSubset(of: Set(p.serves)), "\(p.slug)")
        }
        // Local servers are never offered before a model has passed the evaluation.
        #expect(AIProvider.all.filter { $0.kind == .localServer }.allSatisfy { $0.offered.isEmpty })
    }

    @Test func aLocalServerNeedsNoKeyAndFalIsUntouched() {
        #expect(AIProvider.named("ollama")?.needsKey == false)
        #expect(AIProvider.named("ollama")?.dialect.toolChoice == false)
        #expect(AIProvider.named("fal")?.built.isEmpty == true)   // nothing new for fal until its terms are settled
        #expect(AIProvider.named("hedra")?.termsNote?.contains("yourself") == true)
    }

    @Test func theManualTableListsWhatIsOfferedAndSaysWhatIsUntried() {
        let table = AIProvider.manualTable()
        #expect(table.contains("| OpenRouter |") && table.contains("| Berget |") && table.contains("| Grunden |"))
        #expect(!table.contains("Ollama") && !table.contains("Hedra") && !table.contains("OpenAI"))
        #expect(table.contains("Built from Berget's documentation; not yet tried with a real call."))
        #expect(table.contains("Stockholm, Sweden"))
    }
}

@Suite struct ProviderKeyTests {
    /// A keychain made of a dictionary; `failing` makes one account's write or delete throw.
    final class Box: @unchecked Sendable {
        let lock = NSLock()
        var items: [String: String] = [:]
        var failWrite: Set<String> = [], failDelete: Set<String> = [], dropWrite: Set<String> = []
        struct Failure: Error {}
    }
    struct Item: SecretStore {
        let box: Box, account: String
        func read() throws -> String? { box.lock.withLock { box.items[account] } }
        func write(_ value: String) throws {
            try box.lock.withLock {
                if box.failWrite.contains(account) { throw Box.Failure() }
                if !box.dropWrite.contains(account) { box.items[account] = value }
            }
        }
        func delete() throws {
            try box.lock.withLock {
                if box.failDelete.contains(account) { throw Box.Failure() }
                box.items[account] = nil
            }
        }
    }
    private func keys(_ box: Box) -> ProviderKeys { ProviderKeys { Item(box: box, account: $0) } }

    @Test func theOldOpenRouterItemMovesToTheSlug() throws {
        let box = Box(); box.items = [ProviderKeys.oldOpenRouterAccount: "sk-or-test"]
        #expect(try keys(box).key(for: "openrouter") == "sk-or-test")
        #expect(box.items == ["openrouter": "sk-or-test"])
        #expect(try keys(box).key(for: "openrouter") == "sk-or-test")
    }

    @Test func aKeyIsStoredUnderItsSlugAndOthersAreUntouched() throws {
        let box = Box(); box.items = ["openrouter": "a"]
        try keys(box).store(for: "berget").write("b")
        #expect(try keys(box).key(for: "berget") == "b" && keys(box).key(for: "grunden") == nil)
        #expect(box.items == ["openrouter": "a", "berget": "b"])
        #expect(keys(box).status() == ["openrouter": true, "berget": true, "grunden": false])
    }

    /// Interrupted before the new item is written: the key is still under the old account and is found.
    @Test func interruptedBeforeTheNewItemIsWritten() throws {
        let box = Box(); box.items = [ProviderKeys.oldOpenRouterAccount: "k"]; box.failWrite = ["openrouter"]
        #expect(throws: Box.Failure.self) { try keys(box).key(for: "openrouter") }
        #expect(box.items == [ProviderKeys.oldOpenRouterAccount: "k"])
        box.failWrite = []
        #expect(try keys(box).key(for: "openrouter") == "k")
        #expect(box.items == ["openrouter": "k"])
    }

    /// The write seemed to work but the item isn't there: the old one is kept.
    @Test func theOldItemStaysWhenTheNewOneCantBeReadBack() throws {
        let box = Box(); box.items = [ProviderKeys.oldOpenRouterAccount: "k"]; box.dropWrite = ["openrouter"]
        #expect(try keys(box).key(for: "openrouter") == "k")
        #expect(box.items == [ProviderKeys.oldOpenRouterAccount: "k"])
    }

    /// Interrupted between writing the new item and removing the old: the key works, and the leftover goes at the next start.
    @Test func interruptedBeforeTheOldItemIsRemoved() throws {
        let box = Box(); box.items = [ProviderKeys.oldOpenRouterAccount: "k"]; box.failDelete = [ProviderKeys.oldOpenRouterAccount]
        #expect(throws: Box.Failure.self) { try keys(box).key(for: "openrouter") }
        #expect(box.items == [ProviderKeys.oldOpenRouterAccount: "k", "openrouter": "k"])
        box.failDelete = []
        #expect(try keys(box).key(for: "openrouter") == "k")
        keys(box).removeLeftoverOpenRouterItem()
        #expect(box.items == ["openrouter": "k"])
    }

    /// A leftover old item that differs from the new key is someone's other key: it is not removed.
    @Test func aDifferentOldItemIsLeftAlone() {
        let box = Box(); box.items = [ProviderKeys.oldOpenRouterAccount: "old", "openrouter": "new"]
        keys(box).removeLeftoverOpenRouterItem()
        #expect(box.items.count == 2)
    }
}

@Suite struct ModelCatalogTests {
    /// Entries as api.berget.ai/v1/models returned them on 2026-11-16 (shortened to the fields read).
    static let berget = #"""
    {"object":"list","data":[
     {"id":"mistralai/Mistral-Small-3.2-24B-Instruct-2506","object":"model","owned_by":"mistralai","pricing":{"currency":"EUR","input":0.3,"output":0.3,"unit":"€ / M Token"},"capabilities":{"embeddings":false,"function_calling":true,"json_mode":true,"streaming":true,"vision":false},"model_type":"text"},
     {"id":"zai-org/GLM-5.3-Flash","object":"model","pricing":{"currency":"EUR","input":0.25,"output":0.5,"unit":"€ / M Token"},"capabilities":{"function_calling":true,"json_mode":true,"streaming":true,"vision":true},"model_type":"text"},
     {"id":"KBLab/kb-whisper-large","object":"model","pricing":{"currency":"EUR","input":3.3e-05,"output":3.3e-05,"unit":"€ / second"},"capabilities":{"function_calling":false,"streaming":true,"vision":false},"model_type":"speech-to-text"},
     {"id":"intfloat/multilingual-e5-large","object":"model","pricing":{"currency":"EUR","input":0.03,"output":0},"capabilities":{"embeddings":true,"function_calling":false},"model_type":"embedding"}]}
    """#
    /// Entries as api.grunden.ai/v1/models returned them on 2026-11-16.
    static let grunden = #"""
    {"object":"list","data":[
     {"id":"glm-5.3","object":"model","owned_by":"grunden.ai","type":"chat","endpoint":"/v1/chat/completions","context_window":1048576,"capabilities":["chat","reasoning","tools"],"reasoning_levels":["low","high","max"],"input_modalities":["text"],"tool_calling":true,"pricing":{"input_per_1m_tokens":{"amount":"0.90","currency":"EUR"},"output_per_1m_tokens":{"amount":"1.80","currency":"EUR"}}},
     {"id":"gemma-4-26b","object":"model","type":"chat","capabilities":["chat","thinking_toggle","tools","vision"],"input_modalities":["text","image"],"tool_calling":true,"pricing":{"input_per_1m_tokens":{"amount":"0.15","currency":"EUR"},"output_per_1m_tokens":{"amount":"0.45","currency":"EUR"}}},
     {"id":"bge-m3","object":"model","type":"embedding","capabilities":["embeddings"]},
     {"id":"kb-whisper-large","object":"model","type":"stt","capabilities":["audio_transcription"]}]}
    """#

    @Test func bergetsListGivesToolsVisionAndPrice() throws {
        let models = try ModelCatalog.textModels(slug: "berget", data: Data(Self.berget.utf8))
        #expect(models.map(\.id) == ["mistralai/Mistral-Small-3.2-24B-Instruct-2506", "zai-org/GLM-5.3-Flash"])
        #expect(models[0].tools == true && models[0].vision == false)
        #expect(models[1].vision == true)
        #expect(models[1].priceLine == "€0.25 in, €0.50 out per million tokens")
    }

    @Test func grundensListGivesToolsVisionAndPrice() throws {
        let models = try ModelCatalog.textModels(slug: "grunden", data: Data(Self.grunden.utf8))
        #expect(models.map(\.id) == ["gemma-4-26b", "glm-5.3"])
        #expect(models[0].vision == true && models[1].vision == false && models[1].tools == true)
        #expect(models[1].priceLine == "€0.90 in, €1.80 out per million tokens")
    }

    @Test func aPlainListGivesIdsOnlyAndNoPrice() throws {
        let models = try ModelCatalog.textModels(slug: "ollama", data: Data(#"{"object":"list","data":[{"id":"qwen3:8b","object":"model"}]}"#.utf8))
        #expect(models == [ProviderModel(id: "qwen3:8b")])
        #expect(models[0].priceLine == nil && models[0].tools == nil)
    }

    @Test func somethingThatIsNotAListSaysSo() {
        #expect { try ModelCatalog.textModels(slug: "berget", data: Data("<html>".utf8)) } throws: {
            ($0 as? ModelCatalog.ListError)?.errorDescription == "Couldn't read Berget's model list: the answer isn't a model list."
        }
    }
}

/// The chat adapter against answers in the documented form.
@Suite(.serialized) struct ChatAdapterTests {
    static let toolAnswer = #"""
    {"id":"x","object":"chat.completion","model":"m","choices":[{"index":0,"finish_reason":"tool_calls","message":{"role":"assistant","content":"Black and white.","tool_calls":[{"id":"call_1","type":"function","function":{"name":"add_adjustment","arguments":"{\"type\":\"black_white\"}"}}]}}],"usage":{"prompt_tokens":10,"completion_tokens":5,"total_tokens":15}}
    """#
    let context = AgentContext(width: 800, height: 600, layerCount: 1, hasSelection: false, activeLayerKind: "pixel", activeLayerName: "Photo")

    private func model(_ slug: String, key: String) -> OpenRouterTextModel {
        let p = AIProvider.named(slug)!
        return OpenRouterTextModel(client: OpenRouterClient(apiKey: key, configuration: p.chatConfiguration(), session: FakeProvider.session),
                                   model: "some-model", providerName: p.name)
    }

    @Test func bergetGetsAPlainRequestWithItsKey() async throws {
        FakeProvider.script([(200, Self.toolAnswer)])
        let (plan, cost) = try await AgentPlanner.plan(goal: "Make it black and white", context: context, history: [], model: model("berget", key: "bk"))
        #expect(plan.steps.map(\.op) == ["add_adjustment"] && plan.message == "Black and white." && cost == nil)
        let sent = try #require(FakeProvider.requests.first)
        #expect(sent.url.absoluteString == "https://api.berget.ai/v1/chat/completions")
        #expect(sent.headers["Authorization"] == "Bearer bk")
        #expect(sent.json["usage"] == nil)                       // OpenRouter's own field
        #expect(sent.json["tool_choice"] as? String == "auto" && sent.json["reasoning_effort"] == nil)
        #expect((sent.json["tools"] as? [Any])?.count == AgentPlanner.ops.count)
    }

    @Test func grundenIsAskedToReasonLittle() async throws {
        FakeProvider.script([(200, Self.toolAnswer)])
        _ = try await AgentPlanner.plan(goal: "g", context: context, history: [], model: model("grunden", key: "sk-grunden-x"))
        let sent = try #require(FakeProvider.requests.first)
        #expect(sent.url.absoluteString == "https://api.grunden.ai/v1/chat/completions")
        #expect(sent.json["reasoning_effort"] as? String == "low" && sent.json["usage"] == nil)
    }

    @Test func ollamaGetsNoKeyAndNoToolChoice() async throws {
        FakeProvider.script([(200, Self.toolAnswer)])
        _ = try await AgentPlanner.plan(goal: "g", context: context, history: [], model: model("ollama", key: ""))
        let sent = try #require(FakeProvider.requests.first)
        #expect(sent.url.absoluteString == "http://127.0.0.1:11434/v1/chat/completions")
        #expect(sent.headers["Authorization"] == nil && sent.json["tool_choice"] == nil && sent.json["tools"] != nil)
    }

    @Test func openRouterIsSentWhatItWasSentBefore() async throws {
        FakeProvider.script([(200, Self.toolAnswer)])
        _ = try await AgentPlanner.plan(goal: "g", context: context, history: [], model: model("openrouter", key: "sk-or"))
        let sent = try #require(FakeProvider.requests.first)
        #expect(sent.json["usage"] != nil && sent.json["tool_choice"] as? String == "auto" && sent.json["parallel_tool_calls"] as? Bool == true)
        #expect(sent.json["temperature"] as? Double == 0.2)
    }

    @Test func aProvidersRefusalIsShownAsItCameWithItsStatus() async {
        FakeProvider.script([(404, #"{"error":{"message":"The model `glm-9` does not exist or has been retired.","type":"model_not_found"}}"#)])
        await #expect { _ = try await AgentPlanner.plan(goal: "g", context: context, history: [], model: model("berget", key: "bk")) } throws: {
            ($0 as? LocalizedError)?.errorDescription == "Berget answered HTTP 404: The model `glm-9` does not exist or has been retired."
        }
        FakeProvider.script([(401, "Unauthorized")])
        await #expect { _ = try await AgentPlanner.plan(goal: "g", context: context, history: [], model: model("grunden", key: "bad")) } throws: {
            ($0 as? LocalizedError)?.errorDescription == "Grunden answered HTTP 401: Unauthorized"
        }
    }

    @Test func aCloudProviderWithoutAKeyIsNotCalled() async {
        FakeProvider.script([(200, Self.toolAnswer)])
        await #expect(throws: OpenRouterError.missingAPIKey) {
            _ = try await AgentPlanner.plan(goal: "g", context: context, history: [], model: model("berget", key: ""))
        }
        #expect(FakeProvider.requests.isEmpty)
    }

    @Test func theModelListIsFetchedFromTheService() async throws {
        FakeProvider.script([(200, ModelCatalogTests.grunden)])
        let models = try await ModelCatalog.fetchTextModels(AIProvider.named("grunden")!, key: nil, session: FakeProvider.session)
        #expect(models.map(\.id) == ["gemma-4-26b", "glm-5.3"])
        #expect(FakeProvider.requests.first?.url.absoluteString == "https://api.grunden.ai/v1/models")
    }
}
