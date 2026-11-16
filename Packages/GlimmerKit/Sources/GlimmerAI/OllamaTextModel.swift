import Foundation

/// Text from a model in Ollama on this Mac, through Ollama's own chat API (`/api/chat`).
/// Its OpenAI-style route can't set the context size ("The OpenAI API does not have a way of
/// setting the context size for a model"), and with the default of a few thousand tokens
/// Glimmer's tool list doesn't fit, so the request states the context it needs.
///
/// Nothing is sent off the Mac and no key is involved. A local model is not offered until
/// one has passed `LocalModelEvaluation`.
public struct OllamaTextModel: TextModel {
    public let baseURL: URL
    public let modelID: String
    /// Tokens of context asked for: room for the tool list, a picture and the answer.
    public let contextTokens: Int
    /// Whether the model may reason before it answers (slower; off by default, as measured in docs/TESTING-NOTES.md).
    public let thinks: Bool
    let session: URLSession

    public var providerName: String { "Ollama" }
    /// Small local models lose their way in a long tool list: they get the everyday operations only.
    public var prefersShortToolList: Bool { true }

    /// `baseURL` is the server's address, with or without the `/v1` of its OpenAI-style route.
    public init(baseURL: URL = URL(string: "http://127.0.0.1:11434")!, model: String, contextTokens: Int = 16_384, thinks: Bool = false, session: URLSession = .shared) {
        self.thinks = thinks
        self.baseURL = baseURL.lastPathComponent == "v1" ? baseURL.deletingLastPathComponent() : baseURL
        self.modelID = model
        self.contextTokens = contextTokens
        self.session = session
    }

    public func reply(system: String?, user: String, images: [Data], imageType: String, json: Bool, temperature: Double) async throws -> TextReply {
        var messages: [[String: Any]] = []
        if let system { messages.append(["role": "system", "content": system]) }
        var message: [String: Any] = ["role": "user", "content": user]
        if !images.isEmpty { message["images"] = images.map { $0.base64EncodedString() } }
        messages.append(message)
        var body = self.body(messages: messages, temperature: temperature)
        if json { body["format"] = "json" }
        let answer = try await send(body)
        return TextReply(text: (answer["content"] as? String) ?? "", cost: nil)
    }

    public func callTools(messages: sending [[String: Any]], tools: sending [[String: Any]], temperature: Double,
                          onText: (@Sendable (String) -> Void)?) async throws -> TextToolReply {
        var body = self.body(messages: Self.native(messages), temperature: temperature)
        body["tools"] = tools
        let answer = try await send(body)
        let text = answer["content"] as? String
        if let text, !text.isEmpty { onText?(text) }
        // Ollama gives the arguments as an object; the rest of Glimmer reads them as a JSON string.
        let calls: [TextToolCall] = ((answer["tool_calls"] as? [[String: Any]]) ?? []).compactMap { call in
            guard let function = call["function"] as? [String: Any], let name = function["name"] as? String else { return nil }
            let arguments = function["arguments"]
            let string: String
            if let s = arguments as? String {
                string = s
            } else if let object = arguments, JSONSerialization.isValidJSONObject(object),
                      let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) {
                string = String(decoding: data, as: UTF8.self)
            } else {
                string = "{}"
            }
            return TextToolCall(name: name, arguments: string)
        }
        return TextToolReply(text: text?.isEmpty == false ? text : nil, toolCalls: calls, cost: nil)
    }

    private func body(messages: [[String: Any]], temperature: Double) -> [String: Any] {
        ["model": modelID, "messages": messages, "stream": false, "think": thinks,
         "options": ["num_ctx": contextTokens, "temperature": temperature]]
    }

    /// The common chat form to Ollama's: text in `content`, pictures as base64 in `images`.
    static func native(_ messages: [[String: Any]]) -> [[String: Any]] {
        messages.map { message in
            guard let parts = message["content"] as? [[String: Any]] else { return message }
            var out = message
            var text: [String] = [], images: [String] = []
            for part in parts {
                if let t = part["text"] as? String { text.append(t) }
                if let url = (part["image_url"] as? [String: Any])?["url"] as? String, let comma = url.firstIndex(of: ","), url.hasPrefix("data:") {
                    images.append(String(url[url.index(after: comma)...]))
                }
            }
            out["content"] = text.joined(separator: "\n")
            if !images.isEmpty { out["images"] = images }
            return out
        }
    }

    /// The `message` of the answer.
    private func send(_ body: [String: Any]) async throws -> [String: Any] {
        var request = URLRequest(url: baseURL.appending(path: "api/chat"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 600   // a local model can be slow; nothing is billed while it thinks
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let data: Data, response: URLResponse
        do { (data, response) = try await session.data(for: request) } catch {
            throw OllamaError(message: "Glimmer couldn't reach Ollama at \(baseURL.host() ?? "this Mac"):\(baseURL.port ?? 11434). Is Ollama running? (\(error.localizedDescription))")
        }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw ProviderHTTPError(provider: "Ollama", status: http.statusCode, message: ProviderHTTPError.message(from: data))
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let message = json["message"] as? [String: Any] else {
            throw OllamaError(message: "Ollama's answer wasn't in the form Glimmer expects.")
        }
        return message
    }

    public struct OllamaError: Error, LocalizedError, Equatable {
        public let message: String
        public var errorDescription: String? { message }
    }

    /// What Ollama says a model can do (`/api/show`): tools and pictures.
    public static func abilities(of model: String, baseURL: URL = URL(string: "http://127.0.0.1:11434")!, session: URLSession = .shared) async throws -> (tools: Bool, vision: Bool, contextLength: Int?) {
        var request = URLRequest(url: baseURL.appending(path: "api/show"))
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: ["model": model])
        request.timeoutInterval = 20
        let (data, _) = try await session.data(for: request)
        let json = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        let caps = json["capabilities"] as? [String] ?? []
        let info = json["model_info"] as? [String: Any] ?? [:]
        let context = info.first { $0.key.hasSuffix(".context_length") }?.value as? Int
        return (caps.contains("tools"), caps.contains("vision"), context)
    }

    /// A model installed in Ollama, with what Ollama says it can do.
    public struct Installed: Sendable, Equatable, Identifiable {
        public let name: String
        public let tools: Bool
        public let vision: Bool
        /// Bytes on disk, roughly what it takes in memory while it runs.
        public let size: Int64?
        public var id: String { name }
    }

    /// The models installed in the Ollama at `baseURL` (`/api/tags`, then `/api/show` for each).
    /// Throws when no server answers there: Ollama is then not offered at all.
    public static func installed(baseURL: URL = URL(string: "http://127.0.0.1:11434")!, session: URLSession = .shared) async throws -> [Installed] {
        let root = baseURL.lastPathComponent == "v1" ? baseURL.deletingLastPathComponent() : baseURL
        var request = URLRequest(url: root.appending(path: "api/tags"))
        request.timeoutInterval = 3
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let list = json["models"] as? [[String: Any]] else {
            throw OllamaError(message: "No Ollama answered at \(root.host() ?? "this Mac"):\(root.port ?? 11434).")
        }
        var models: [Installed] = []
        for entry in list {
            guard let name = (entry["name"] as? String) ?? (entry["model"] as? String) else { continue }
            let abilities = try? await abilities(of: name, baseURL: root, session: session)
            models.append(Installed(name: name, tools: abilities?.tools ?? false, vision: abilities?.vision ?? false, size: (entry["size"] as? NSNumber)?.int64Value))
        }
        return models.sorted { $0.name < $1.name }
    }
}
