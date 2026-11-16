import Foundation

/// Text from Claude through Anthropic's Messages API (`POST /v1/messages`), in its own form:
/// Swift has no official SDK, so this is the documented HTTP request.
///
/// What the current models refuse is not sent: no temperature (an error on Claude 4.7 and
/// later), no forced tool choice, no thinking setting (the model's default applies). JSON
/// answers are asked for in the prompt and parsed, as with the other services. The reply
/// arrives whole; `onText` gets it once.
public struct AnthropicTextModel: TextModel {
    public static let apiVersion = "2026-10-21"

    public let modelID: String
    public var providerName: String { "Anthropic" }
    let baseURL: URL
    let key: String
    let session: URLSession

    public init(provider: AIProvider, key: String, model: String, session: URLSession = .shared) {
        self.baseURL = URL(string: provider.baseURL)!
        self.key = key
        self.modelID = model
        self.session = session
    }

    /// A declined request: Claude answers 200 with `stop_reason: "refusal"`.
    public struct Refusal: Error, LocalizedError, Equatable {
        public let category: String?
        public var errorDescription: String? {
            "Claude declined this request" + (category.map { " (\($0))" } ?? "") + ". Nothing was changed."
        }
    }

    public func reply(system: String?, user: String, images: [Data], imageType: String, json: Bool, temperature: Double) async throws -> TextReply {
        var content: [[String: Any]] = images.map { Self.imageBlock(mediaType: imageType, base64: $0.base64EncodedString()) }
        content.append(["type": "text", "text": user])
        var body: [String: Any] = ["model": modelID, "max_tokens": 16_000, "messages": [["role": "user", "content": content]]]
        if let system { body["system"] = system }
        return TextReply(text: Self.text(in: try await send(body)), cost: nil)
    }

    public func callTools(messages: sending [[String: Any]], tools: sending [[String: Any]], temperature: Double,
                          onText: (@Sendable (String) -> Void)?) async throws -> TextToolReply {
        let (system, turns) = Self.conversation(from: messages)
        var body: [String: Any] = ["model": modelID, "max_tokens": 16_000, "messages": turns, "tools": Self.tools(from: tools)]
        if let system { body["system"] = system }
        let blocks: [[String: Any]]
        if let onText {
            // The Assistant shows the text as it comes: the same request with `stream`, put together from its events.
            body["stream"] = true
            var stream = AnthropicStream()
            let name = providerName
            try await ServerSentEvents.read(try request(body), provider: name, session: session) { event in
                if try stream.consume(event, provider: name) { onText(stream.text) }
            }
            if stream.stopReason == "refusal" { throw Refusal(category: stream.stopCategory) }
            blocks = stream.content
        } else {
            blocks = try await send(body)
        }
        let text = Self.text(in: blocks)
        let calls: [TextToolCall] = blocks.compactMap { block in
            guard block["type"] as? String == "tool_use", let name = block["name"] as? String else { return nil }
            // The input is an object; the rest of Glimmer reads arguments as a JSON string.
            let input = block["input"] ?? [String: Any]()
            let data = JSONSerialization.isValidJSONObject(input) ? try? JSONSerialization.data(withJSONObject: input, options: [.sortedKeys]) : nil
            return TextToolCall(name: name, arguments: data.map { String(decoding: $0, as: UTF8.self) } ?? "{}")
        }
        return TextToolReply(text: text.isEmpty ? nil : text, toolCalls: calls, cost: nil)
    }

    static func imageBlock(mediaType: String, base64: String) -> [String: Any] {
        ["type": "image", "source": ["type": "base64", "media_type": mediaType, "data": base64]]
    }

    /// Chat-form tools to Anthropic's: `name`, `description`, `input_schema`.
    static func tools(from chat: [[String: Any]]) -> [[String: Any]] {
        chat.compactMap { tool in
            guard let f = tool["function"] as? [String: Any], let name = f["name"] as? String else { return nil }
            var out: [String: Any] = ["name": name, "input_schema": f["parameters"] ?? ["type": "object", "properties": [String: Any]()]]
            if let d = f["description"] { out["description"] = d }
            return out
        }
    }

    /// Chat-form messages to a top-level system prompt and user/assistant turns; a picture's
    /// data URL becomes a base64 image block.
    static func conversation(from messages: [[String: Any]]) -> (system: String?, turns: [[String: Any]]) {
        var system: [String] = [], turns: [[String: Any]] = []
        for message in messages {
            let role = message["role"] as? String ?? "user"
            if role == "system" {
                if let text = message["content"] as? String { system.append(text) }
                continue
            }
            guard let parts = message["content"] as? [[String: Any]] else {
                turns.append(["role": role, "content": message["content"] ?? ""])
                continue
            }
            let blocks: [[String: Any]] = parts.compactMap { part in
                if let text = part["text"] as? String { return ["type": "text", "text": text] }
                if let url = (part["image_url"] as? [String: Any])?["url"] as? String, url.hasPrefix("data:"),
                   let semicolon = url.firstIndex(of: ";"), let comma = url.firstIndex(of: ",") {
                    return imageBlock(mediaType: String(url[url.index(url.startIndex, offsetBy: 5)..<semicolon]), base64: String(url[url.index(after: comma)...]))
                }
                return nil
            }
            turns.append(["role": role, "content": blocks])
        }
        return (system.isEmpty ? nil : system.joined(separator: "\n\n"), turns)
    }

    static func text(in blocks: [[String: Any]]) -> String {
        blocks.filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }.joined()
    }

    static func headers(key: String) -> [String: String] {
        ["x-api-key": key, "anthropic-version": apiVersion, "Content-Type": "application/json"]
    }

    /// The `content` blocks of the answer.
    private func request(_ body: [String: Any]) throws -> URLRequest {
        guard !key.isEmpty else { throw OpenRouterError.missingAPIKey }
        var request = URLRequest(url: baseURL.appending(path: "messages"))
        request.httpMethod = "POST"
        for (name, value) in Self.headers(key: key) { request.setValue(value, forHTTPHeaderField: name) }
        request.timeoutInterval = 300
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    private func send(_ body: [String: Any]) async throws -> [[String: Any]] {
        let request = try request(body)
        let data: Data, response: URLResponse
        do { (data, response) = try await session.data(for: request, delegate: KeyStaysHome.shared) } catch {
            throw OpenRouterError.network(error.localizedDescription)
        }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw ProviderHTTPError(provider: providerName, status: http.statusCode, message: ProviderHTTPError.message(from: data))
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ProviderHTTPError(provider: providerName, status: 200, message: "The answer wasn't in the form Glimmer expects.")
        }
        // Always look at the stop reason before the content.
        if json["stop_reason"] as? String == "refusal" {
            throw Refusal(category: (json["stop_details"] as? [String: Any])?["category"] as? String)
        }
        guard let content = json["content"] as? [[String: Any]] else {
            throw ProviderHTTPError(provider: providerName, status: 200, message: "The answer wasn't in the form Glimmer expects.")
        }
        return content
    }
}
