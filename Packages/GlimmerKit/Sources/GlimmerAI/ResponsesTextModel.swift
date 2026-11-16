import Foundation

/// Text through the Responses API (`POST /responses`): OpenAI and xAI. OpenAI's newest models
/// take tool calls only this way ("GPT-6 Astra and GPT-6.1 Sol require the Responses API for
/// tool calling"), and xAI's function-calling page shows only this form.
///
/// Built from the two services' documentation. What their pages don't show for this API is
/// not sent: no temperature, no JSON mode (the prompt asks for JSON and the answer is parsed).
/// OpenAI's answer is streamed when the Assistant wants the text as it comes (its guides
/// document the events). xAI's pages name no events for this API, so its reply arrives
/// whole and `onText` gets it once.
public struct ResponsesTextModel: TextModel {
    public let providerName: String
    public let modelID: String
    let baseURL: URL
    let key: String
    let session: URLSession
    /// Whether the service documents this API's stream events.
    let streams: Bool

    public init(provider: AIProvider, key: String, model: String, session: URLSession = .shared) {
        self.providerName = provider.name
        self.streams = provider.slug == "openai"
        self.baseURL = URL(string: provider.baseURL)!
        self.key = key
        self.modelID = model
        self.session = session
    }

    public func reply(system: String?, user: String, images: [Data], imageType: String, json: Bool, temperature: Double) async throws -> TextReply {
        var input: [[String: Any]] = []
        if let system { input.append(["role": "system", "content": system]) }
        var content: [[String: Any]] = [["type": "input_text", "text": user]]
        for image in images {
            content.append(["type": "input_image", "image_url": "data:\(imageType);base64," + image.base64EncodedString()])
        }
        input.append(["role": "user", "content": content])
        let output = try await send(["model": modelID, "input": input])
        return TextReply(text: Self.text(in: output), cost: nil)
    }

    public func callTools(messages: sending [[String: Any]], tools: sending [[String: Any]], temperature: Double,
                          onText: (@Sendable (String) -> Void)?) async throws -> TextToolReply {
        let body: [String: Any] = ["model": modelID, "input": Self.input(from: messages), "tools": Self.tools(from: tools)]
        if streams, let onText {
            var stream = ResponsesStream()
            let name = providerName
            try await ServerSentEvents.read(try request(body.merging(["stream": true]) { $1 }), provider: name, session: session) { event in
                if try stream.consume(event, provider: name) { onText(stream.text) }
            }
            // Text that came only inside a finished item (no deltas) still counts.
            let text = stream.text.isEmpty ? Self.text(in: stream.items) : stream.text
            let calls = Self.calls(in: stream.items)
            guard !text.isEmpty || !calls.isEmpty else {
                throw ProviderHTTPError(provider: name, status: 200, message: "The answer wasn't in the form Glimmer expects.")
            }
            return TextToolReply(text: text.isEmpty ? nil : text, toolCalls: calls, cost: nil)
        }
        let output = try await send(body)
        let text = Self.text(in: output)
        if !text.isEmpty { onText?(text) }
        return TextToolReply(text: text.isEmpty ? nil : text, toolCalls: Self.calls(in: output), cost: nil)
    }

    static func calls(in output: [[String: Any]]) -> [TextToolCall] {
        output.compactMap { item in
            guard item["type"] as? String == "function_call", let name = item["name"] as? String else { return nil }
            return TextToolCall(name: name, arguments: (item["arguments"] as? String) ?? "{}")
        }
    }

    /// Chat-form tools (`{"type": "function", "function": {name, description, parameters}}`) to the flat form this API takes.
    static func tools(from chat: [[String: Any]]) -> [[String: Any]] {
        chat.compactMap { tool in
            guard let f = tool["function"] as? [String: Any], let name = f["name"] as? String else { return nil }
            var out: [String: Any] = ["type": "function", "name": name]
            if let d = f["description"] { out["description"] = d }
            if let p = f["parameters"] { out["parameters"] = p }
            return out
        }
    }

    /// Chat-form messages to input items: text parts become `input_text`, pictures `input_image` with their data URL.
    static func input(from messages: [[String: Any]]) -> [[String: Any]] {
        messages.map { message in
            guard let parts = message["content"] as? [[String: Any]] else { return message }
            var out = message
            out["content"] = parts.compactMap { part -> [String: Any]? in
                if let text = part["text"] as? String { return ["type": "input_text", "text": text] }
                if let url = (part["image_url"] as? [String: Any])?["url"] as? String { return ["type": "input_image", "image_url": url] }
                return nil
            }
            return out
        }
    }

    /// The text of the answer: every `output_text` of every `message` item.
    static func text(in output: [[String: Any]]) -> String {
        output.filter { $0["type"] as? String == "message" }
            .flatMap { ($0["content"] as? [[String: Any]]) ?? [] }
            .filter { $0["type"] as? String == "output_text" }
            .compactMap { $0["text"] as? String }
            .joined()
    }

    /// The `output` array of the answer.
    private func request(_ body: [String: Any]) throws -> URLRequest {
        guard !key.isEmpty else { throw OpenRouterError.missingAPIKey }
        var request = URLRequest(url: baseURL.appending(path: "responses"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 240
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
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let output = json["output"] as? [[String: Any]] else {
            throw ProviderHTTPError(provider: providerName, status: 200, message: "The answer wasn't in the form Glimmer expects.")
        }
        return output
    }
}
