import Foundation

/// The one list of AI services Glimmer can use (the-apps/PROVIDERS.md). Key fields in
/// Settings, model pickers, "key missing" messages, the agent API's key status and the table
/// in the manual all come from here, so a change of the list is a change in one place.
public struct AIProvider: Sendable, Identifiable, Equatable {
    public enum Kind: String, Sendable { case cloud, localServer }
    public enum Capability: String, Sendable, CaseIterable { case text, image }
    /// How Glimmer talks to it for text.
    public enum TextAdapter: String, Sendable { case chatCompletions, responses, anthropicMessages }

    /// The series' name for it: also the keychain account its key is stored under.
    public let slug: String
    public let name: String
    public let kind: Kind
    public let serves: [Capability]
    public let textAdapter: TextAdapter?
    /// Where requests go (a local server's address is a setting; this is its default).
    public let baseURL: String
    /// What its chat completions accept.
    public var dialect = ChatDialect.plain
    /// What is offered to the person. Everything new is hidden until Anders has made a paid
    /// test of it; Berget and Grunden are the exception he decided on 2026-11-16 (built from
    /// their documentation and offered at once). A local model is shown only once one has
    /// passed Glimmer's own evaluation.
    public var offered: Set<Capability> = []
    /// Built for these (an adapter exists and passes its tests), offered or not.
    public var built: Set<Capability> = []
    /// Shown where the key is entered: only what was read, with a link to the service's own terms.
    public var termsNote: String?
    public var termsURL: String?
    public var keysURL: String?
    public var pricesURL: String?
    /// One line for the manual: where the data is processed, in the service's own words.
    public var dataNote: String?
    /// Nobody has made a real call: said in the manual.
    public var fromDocumentationOnly = false
    /// For a local server: the models that have passed Glimmer's own evaluation
    /// (`LocalModelEvaluation`, numbers in docs/TESTING-NOTES.md). Others that are installed
    /// are listed as "not evaluated with Glimmer".
    public var evaluatedModels: [String] = []

    public var id: String { slug }
    public var needsKey: Bool { kind == .cloud }

    public func offers(_ capability: Capability) -> Bool { offered.contains(capability) }

    public var missingKeyMessage: String { "Add your \(name) API key in Settings › AI." }

    /// The host requests go to, for "sent to …".
    public var host: String { URL(string: baseURL)?.host() ?? baseURL }

    // MARK: The list

    public static let all: [AIProvider] = [
        {
            var p = AIProvider(slug: "openrouter", name: "OpenRouter", kind: .cloud, serves: [.text, .image], textAdapter: .chatCompletions,
                               baseURL: AIDefaults.defaultEndpoint)
            p.dialect = ChatDialect()
            p.offered = [.text, .image]; p.built = [.text, .image]
            p.keysURL = "https://openrouter.ai/keys"; p.termsURL = "https://openrouter.ai/terms"; p.pricesURL = "https://openrouter.ai/models"
            return p
        }(),
        {
            var p = AIProvider(slug: "openai", name: "OpenAI", kind: .cloud, serves: [.text, .image], textAdapter: .responses, baseURL: "https://api.openai.com/v1")
            p.built = [.text, .image]
            p.keysURL = "https://platform.openai.com/api-keys"; p.pricesURL = "https://developers.openai.com/api/docs/pricing"
            return p
        }(),
        {
            var p = AIProvider(slug: "anthropic", name: "Anthropic", kind: .cloud, serves: [.text], textAdapter: .anthropicMessages, baseURL: "https://api.anthropic.com/v1")
            p.built = [.text]
            p.keysURL = "https://platform.claude.com/settings/keys"; p.pricesURL = "https://platform.claude.com/docs/en/about-claude/pricing"
            p.termsURL = "https://www.anthropic.com/legal/commercial-terms"
            return p
        }(),
        {
            var p = AIProvider(slug: "xai", name: "xAI", kind: .cloud, serves: [.text], textAdapter: .responses, baseURL: "https://api.x.ai/v1")
            p.built = [.text]
            p.keysURL = "https://console.x.ai"; p.pricesURL = "https://docs.x.ai/developers/models"
            return p
        }(),
        {
            var p = AIProvider(slug: "google", name: "Google", kind: .cloud, serves: [.text, .image], textAdapter: .chatCompletions,
                               baseURL: "https://generativelanguage.googleapis.com/v1beta/openai")
            // Google's OpenAI-compatible route ("still in beta" in its own words). Its page shows tools,
            // tool_choice, pictures and streaming; what it doesn't show is left out.
            p.dialect.parallelToolCalls = false
            p.dialect.jsonObject = false
            p.built = [.text, .image]
            p.keysURL = "https://aistudio.google.com/apikey"; p.pricesURL = "https://ai.google.dev/gemini-api/docs/pricing"
            p.termsNote = "For professional or business use, and for people who are 18 or older. Google's rules restrict pictures of recognisable people."
            p.termsURL = "https://ai.google.dev/gemini-api/terms"
            return p
        }(),
        {
            var p = AIProvider(slug: "berget", name: "Berget", kind: .cloud, serves: [.text], textAdapter: .chatCompletions, baseURL: "https://api.berget.ai/v1")
            p.offered = [.text]; p.built = [.text]
            p.keysURL = "https://console.berget.ai"; p.termsURL = "https://berget.ai/en/terms"; p.pricesURL = "https://berget.ai/en/pricing"
            p.termsNote = "Berget AI runs open models in Stockholm. Its terms say it never stores the content of prompts or answers."
            p.dataNote = "Stockholm, Sweden"
            p.fromDocumentationOnly = true
            return p
        }(),
        {
            var p = AIProvider(slug: "grunden", name: "Grunden", kind: .cloud, serves: [.text], textAdapter: .chatCompletions, baseURL: "https://api.grunden.ai/v1")
            // Its models reason at full depth unless told otherwise; the Assistant wants a quick plan.
            p.dialect.reasoningEffort = "low"
            p.offered = [.text]; p.built = [.text]
            p.keysURL = "https://grunden.ai/login"; p.termsURL = "https://grunden.ai/terms"; p.pricesURL = "https://grunden.ai/models/"
            p.termsNote = "Grunden AI runs open models in Sweden and says all processing happens there."
            p.dataNote = "Sweden"
            p.fromDocumentationOnly = true
            return p
        }(),
        {
            var p = AIProvider(slug: "fal", name: "fal.ai", kind: .cloud, serves: [.image], textAdapter: nil, baseURL: "https://fal.run")
            p.built = [.image]
            p.keysURL = "https://fal.ai/dashboard/keys"; p.termsURL = "https://fal.ai/legal/terms-of-service"; p.pricesURL = "https://fal.ai/pricing"
            // Only what has been read. Glimmer sends pictures inside the request and asks for the result the same way, so nothing is put on fal's storage.
            p.termsNote = "fal keeps what you send in its request history for 90 days by default. Glimmer sends your pictures inside the request and gets the result back the same way, so nothing is placed on fal's file storage, which is public by default."
            return p
        }(),
        {
            var p = AIProvider(slug: "hedra", name: "Hedra", kind: .cloud, serves: [.image], textAdapter: nil, baseURL: "https://api.hedra.com/v3")
            p.built = [.image]
            p.keysURL = "https://www.hedra.com/develop"; p.pricesURL = "https://www.hedra.com/pricing"
            p.termsNote = "Upload only pictures of yourself: Hedra's rules forbid media of other people. Hedra gets a licence to what you make with it. Your pictures are uploaded to Hedra for the job; the upload expires after an hour."
            p.termsURL = "https://www.hedra.com/terms"
            return p
        }(),
        {
            var p = AIProvider(slug: "ollama", name: "Ollama", kind: .localServer, serves: [.text], textAdapter: .chatCompletions, baseURL: "http://127.0.0.1:11434/v1")
            p.dialect.toolChoice = false
            // Offered since qwen3:8b passed the evaluation (2026-11-16), and only shown while a
            // server is running on this Mac.
            p.built = [.text]; p.offered = [.text]
            p.evaluatedModels = ["qwen3:8b"]
            p.termsNote = "Runs on this Mac with Ollama: nothing is sent anywhere and nothing is billed. Slower than a cloud model; an answer can take up to a minute on a busy Mac."
            p.dataNote = "This Mac"
            return p
        }(),
        {
            var p = AIProvider(slug: "mlx", name: "MLX", kind: .localServer, serves: [.text], textAdapter: .chatCompletions, baseURL: "http://127.0.0.1:8080/v1")
            p.dataNote = "This Mac"
            return p
        }(),
    ]

    public static func named(_ slug: String) -> AIProvider? { all.first { $0.slug == slug } }
    public static let openRouter = named("openrouter")!

    /// The services offered for `capability`, in list order.
    public static func offering(_ capability: Capability) -> [AIProvider] { all.filter { $0.offers(capability) } }

    /// The client configuration for this service's chat completions. `baseURL` overrides the
    /// address (OpenRouter's endpoint setting, a local server's address).
    public func chatConfiguration(baseURL override: URL? = nil) -> OpenRouterConfiguration {
        var c = OpenRouterConfiguration(baseURL: override ?? URL(string: baseURL)!)
        c.dialect = dialect
        c.needsKey = needsKey
        c.providerName = slug == "openrouter" ? nil : name
        return c
    }

    /// The text model for this service: the adapter its `textAdapter` names. `baseURL` overrides
    /// the address (OpenRouter's endpoint setting, a local server's address). The key is passed
    /// in for this one model and kept nowhere else.
    public func textModel(key: String, model: String, baseURL override: URL? = nil, session: URLSession = .shared) -> (any TextModel)? {
        guard built.contains(.text) else { return nil }
        if slug == "ollama" { return OllamaTextModel(baseURL: override ?? URL(string: baseURL)!, model: model, session: session) }
        switch textAdapter {
        case .chatCompletions:
            return OpenRouterTextModel(client: OpenRouterClient(apiKey: key, configuration: chatConfiguration(baseURL: override), session: session),
                                       model: model, providerName: name)
        case .responses:
            return ResponsesTextModel(provider: self, key: key, model: model, session: session)
        case .anthropicMessages:
            return AnthropicTextModel(provider: self, key: key, model: model, session: session)
        case nil:
            return nil
        }
    }

    /// The image model for this service. `editModel` is fal's separate model id for requests
    /// with input pictures. The key is passed in for this one model and kept nowhere else.
    public func imageModel(key: String, model: String, editModel: String? = nil, session: URLSession = .shared) -> (any ImageModel)? {
        guard built.contains(.image) else { return nil }
        switch slug {
        case "openai": return OpenAIImageModel(key: key, model: model, session: session)
        case "google": return GoogleImageModel(key: key, model: model, session: session)
        case "fal": return FalImageModel(key: key, model: model, editModel: editModel, session: session)
        case "hedra": return HedraImageModel(key: key, model: model, session: session)
        default: return nil   // OpenRouter's has a result cache and two routes: `OpenRouterImageModel`
        }
    }

    /// The manual's table, generated so it can't drift from the list.
    public static func manualTable() -> String {
        var lines = ["| Service | Used for | Key | Where your data is processed | Notes |", "|---|---|---|---|---|"]
        for p in all where !p.offered.isEmpty {
            let uses = Capability.allCases.filter(p.offers).map { $0 == .text ? "text (the Assistant)" : "images" }.joined(separator: ", ")
            let key = p.needsKey ? "your own, in **Settings › AI**" : "none (shown only while it is running on your Mac)"
            var notes: [String] = []
            if p.fromDocumentationOnly { notes.append("Built from \(p.name)'s documentation; not yet tried with a real call.") }
            if let t = p.termsNote { notes.append(t) }
            lines.append("| \(p.name) | \(uses) | \(key) | \(p.dataNote ?? "see the service's terms") | \(notes.joined(separator: " ")) |")
        }
        return lines.joined(separator: "\n")
    }
}

// MARK: Keys

/// The API keys, one keychain item per service: service = the app's bundle id, account = the
/// service's slug. A key is read when a request is made and passed into it; it is never
/// kept on a shared object or written to a log.
public struct ProviderKeys: Sendable {
    /// The account OpenRouter's key was stored under before the series agreed on slugs.
    public static let oldOpenRouterAccount = "openrouter-api-key"

    let store: @Sendable (String) -> any SecretStore

    public init(store: @escaping @Sendable (String) -> any SecretStore) { self.store = store }

    /// The user's keychain, under this build's own bundle id.
    public static let keychain = ProviderKeys { KeychainSecretStore(service: AppIdentity.glimmerBundleID, account: $0) }

    public func store(for slug: String) -> any SecretStore { store(slug) }

    /// The key for `slug`, or nil. OpenRouter's key is moved from its old item the first time.
    public func key(for slug: String) throws -> String? {
        if let key = try store(slug).read(), !key.isEmpty { return key }
        guard slug == "openrouter" else { return nil }
        return try migrateOpenRouterKey()
    }

    /// Moves the old item to the new account: write the new one, read it back, and only then
    /// remove the old. Stopped anywhere in between, the key is still found the next time
    /// (under the new account if it got that far, otherwise under the old), and the move finishes then.
    func migrateOpenRouterKey() throws -> String? {
        let old = store(Self.oldOpenRouterAccount)
        guard let key = try old.read(), !key.isEmpty else { return nil }
        let new = store("openrouter")
        try new.write(key)
        guard try new.read() == key else { return key }   // not safely there: keep the old item
        try old.delete()
        return key
    }

    /// Finishes a move that was interrupted after the new item was written.
    public func removeLeftoverOpenRouterItem() {
        guard let new = try? store("openrouter").read(), !new.isEmpty,
              let old = try? store(Self.oldOpenRouterAccount).read(), old == new else { return }
        try? store(Self.oldOpenRouterAccount).delete()
    }

    /// Present or missing per service that needs a key: for Settings and the agent API. Never the key.
    public func status() -> [String: Bool] {
        var result: [String: Bool] = [:]
        for p in AIProvider.all where p.needsKey && !p.offered.isEmpty {
            result[p.slug] = ((try? key(for: p.slug)) ?? nil) != nil
        }
        return result
    }
}

// MARK: Models

/// One model of a service, as its list endpoint describes it.
public struct ProviderModel: Sendable, Equatable, Identifiable {
    public var id: String
    /// nil when the list doesn't say.
    public var tools: Bool?
    public var vision: Bool?
    /// Per million tokens, in `currency`, when the list publishes prices.
    public var inputPrice: Double?
    public var outputPrice: Double?
    public var currency: String?

    public init(id: String, tools: Bool? = nil, vision: Bool? = nil, inputPrice: Double? = nil, outputPrice: Double? = nil, currency: String? = nil) {
        self.id = id; self.tools = tools; self.vision = vision
        self.inputPrice = inputPrice; self.outputPrice = outputPrice; self.currency = currency
    }

    /// "€0.25 in, €0.50 out per million tokens", or nil when the list has no prices.
    public var priceLine: String? {
        guard let i = inputPrice, let o = outputPrice else { return nil }
        let sign = currency == "EUR" ? "€" : currency == "USD" ? "$" : (currency.map { $0 + " " } ?? "")
        func n(_ v: Double) -> String { String(format: "%.2f", v) }
        return "\(sign)\(n(i)) in, \(sign)\(n(o)) out per million tokens"
    }
}

/// Reads a service's model list, so a picker never offers an id the service has retired.
public enum ModelCatalog {
    public struct ListError: Error, LocalizedError, Equatable {
        public let provider: String
        public let reason: String
        public var errorDescription: String? { "Couldn't read \(provider)'s model list: \(reason)" }
    }

    /// The text models in a `GET /models` answer. Each service describes capabilities its own
    /// way; an entry that is clearly not a chat model (embeddings, speech) is left out.
    public static func textModels(slug: String, data: Data) throws -> [ProviderModel] {
        let name = AIProvider.named(slug)?.name ?? slug
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let list = json["data"] as? [[String: Any]] else {
            throw ListError(provider: name, reason: "the answer isn't a model list.")
        }
        func number(_ v: Any?) -> Double? {
            if let d = v as? Double { return d }
            if let s = v as? String { return Double(s) }
            if let o = v as? [String: Any] { return number(o["amount"]) }
            return nil
        }
        var models: [ProviderModel] = []
        for entry in list {
            guard let id = entry["id"] as? String else { continue }
            var m = ProviderModel(id: id)
            switch slug {
            case "berget":
                // {"model_type": "text", "capabilities": {"function_calling": true, "vision": true}, "pricing": {"input": 0.25, "output": 0.5, "currency": "EUR"}}
                let kind = (entry["model_type"] as? String) ?? (entry["type"] as? String)
                guard kind == nil || kind == "text" else { continue }
                let caps = entry["capabilities"] as? [String: Any]
                m.tools = caps?["function_calling"] as? Bool
                m.vision = caps?["vision"] as? Bool
                if let price = entry["pricing"] as? [String: Any] {
                    m.inputPrice = number(price["input"]); m.outputPrice = number(price["output"]); m.currency = price["currency"] as? String
                }
            case "grunden":
                // {"type": "chat", "capabilities": ["chat", "tools", "vision"], "tool_calling": true, "input_modalities": ["text", "image"],
                //  "pricing": {"input_per_1m_tokens": {"amount": "0.20", "currency": "EUR"}, …}}
                guard (entry["type"] as? String) == "chat" else { continue }
                let caps = entry["capabilities"] as? [String] ?? []
                m.tools = (entry["tool_calling"] as? Bool) ?? caps.contains("tools")
                m.vision = (entry["input_modalities"] as? [String])?.contains("image") ?? caps.contains("vision")
                if let price = entry["pricing"] as? [String: Any] {
                    m.inputPrice = number(price["input_per_1m_tokens"]); m.outputPrice = number(price["output_per_1m_tokens"])
                    m.currency = (price["input_per_1m_tokens"] as? [String: Any])?["currency"] as? String
                }
            default:
                break   // ids only (OpenRouter's own list, Ollama, MLX)
            }
            models.append(m)
        }
        return models.sorted { $0.id.localizedCaseInsensitiveCompare($1.id) == .orderedAscending }
    }

    /// Fetches the list. Berget's and Grunden's are public; a key is sent when there is one.
    public static func fetchTextModels(_ provider: AIProvider, baseURL: URL? = nil, key: String?, session: URLSession = .shared) async throws -> [ProviderModel] {
        var request = URLRequest(url: (baseURL ?? URL(string: provider.baseURL)!).appending(path: "models"))
        request.timeoutInterval = 20
        if let key, !key.isEmpty {
            if provider.textAdapter == .anthropicMessages {
                for (name, value) in AnthropicTextModel.headers(key: key) where name != "Content-Type" { request.setValue(value, forHTTPHeaderField: name) }
            } else {
                request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            }
        }
        let data: Data, response: URLResponse
        do { (data, response) = try await session.data(for: request) } catch {
            throw ListError(provider: provider.name, reason: error.localizedDescription)
        }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw ProviderHTTPError(provider: provider.name, status: http.statusCode, message: ProviderHTTPError.message(from: data))
        }
        return try textModels(slug: provider.slug, data: data)
    }
}
