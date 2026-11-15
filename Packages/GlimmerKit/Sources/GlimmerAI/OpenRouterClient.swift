import Foundation

public enum AIDefaults {
    public static let imageModel = "google/gemini-3-pro-image-preview"
    public static let textModel = "google/gemini-2.5-flash"

    public static let imageModelKey = "ai.imageModel"
    public static let textModelKey = "ai.textModel"

    /// The OpenRouter-compatible API Glimmer talks to. Configurable in Settings › AI,
    /// so nothing depends on a server Glimmer's makers run.
    public static let defaultEndpoint = "https://openrouter.ai/api/v1"
    public static let endpointKey = "ai.endpoint"

    /// The configured endpoint, or OpenRouter when the setting is empty or not an http(s) URL.
    public static var endpoint: URL { endpoint(from: UserDefaults.standard.string(forKey: endpointKey)) }

    static func endpoint(from text: String?) -> URL {
        let trimmed = (text ?? "").trimmingCharacters(in: .whitespaces)
        if let url = URL(string: trimmed), ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host() != nil {
            return url
        }
        return URL(string: defaultEndpoint)!
    }
}

public enum OpenRouterError: Error, Equatable, LocalizedError {
    case missingAPIKey
    /// 401 – fatal, never retried.
    case invalidAPIKey
    /// 402 – fatal, never retried.
    case insufficientCredits
    case rateLimited(retryAfter: TimeInterval?)
    case contentPolicy(String?)
    case badRequest(String?)
    case unavailable(status: Int)
    case network(String)
    case unexpectedResponse(status: Int, message: String?)
    /// The model answered without an image (often a refusal or a clarifying question).
    case noImageInResponse(String?)

    public var isRetryable: Bool {
        switch self {
        case .rateLimited, .unavailable, .network: true
        default: false
        }
    }

    public var errorDescription: String? {
        switch self {
        case .missingAPIKey: "Add your OpenRouter API key in Settings → AI."
        case .invalidAPIKey: "OpenRouter rejected the API key."
        case .insufficientCredits: "Your OpenRouter account is out of credits."
        case .rateLimited: "OpenRouter is rate limiting requests. Try again shortly."
        case .contentPolicy(let m): "The request was blocked by content policy." + (m.map { " \($0)" } ?? "")
        case .badRequest(let m): "OpenRouter could not process the request." + (m.map { " \($0)" } ?? "")
        case .unavailable(let s): "OpenRouter is unavailable (HTTP \(s))."
        case .network(let m):
            // What the system says ("The Internet connection appears to be offline"), then what to do.
            "Glimmer couldn't reach the AI service: \(m.trimmingCharacters(in: CharacterSet(charactersIn: ". ")))."
                + " Check your internet connection and try again. The tools that run on this Mac keep working."
        case .unexpectedResponse(let s, let m): "Unexpected response (HTTP \(s))." + (m.map { " \($0)" } ?? "")
        case .noImageInResponse(let m): "The model didn't return an image." + (m.map { " It said: \($0.prefix(300))" } ?? "")
        }
    }

    /// Maps a non-2xx HTTP response. Returns nil for success codes.
    public static func from(status: Int, body: Data, retryAfterHeader: String?) -> OpenRouterError? {
        guard !(200..<300).contains(status) else { return nil }
        let message = extractMessage(from: body)
        switch status {
        case 401: return .invalidAPIKey
        case 402: return .insufficientCredits
        case 403: return .contentPolicy(message)
        case 400, 422: return .badRequest(message)
        case 429: return .rateLimited(retryAfter: retryAfterHeader.flatMap(TimeInterval.init))
        case 500...599: return .unavailable(status: status)
        default: return .unexpectedResponse(status: status, message: message)
        }
    }

    /// OpenRouter errors look like `{"error": {"message": "...", "code": 401}}`.
    static func extractMessage(from body: Data) -> String? {
        struct Envelope: Decodable {
            struct Inner: Decodable { var message: String? }
            var error: Inner?
        }
        return (try? JSONDecoder().decode(Envelope.self, from: body))?.error?.message
    }
}

public struct OpenRouterKeyInfo: Decodable, Equatable, Sendable {
    public var label: String?
    /// Credits used, in USD.
    public var usage: Double?
    /// Credit limit in USD, nil when unlimited.
    public var limit: Double?
    public var limitRemaining: Double?
    public var isFreeTier: Bool?

    enum CodingKeys: String, CodingKey {
        case label, usage, limit
        case limitRemaining = "limit_remaining"
        case isFreeTier = "is_free_tier"
    }
}

public struct OpenRouterConfiguration: Sendable {
    public var baseURL: URL
    /// Shown in the OpenRouter dashboard; identifies the app, not the user.
    public var appTitle: String

    public init(baseURL: URL = AIDefaults.endpoint, appTitle: String = "Glimmer") {
        self.baseURL = baseURL
        self.appTitle = appTitle
    }
}

/// Talks to OpenRouter with the user's own API key.
public actor OpenRouterClient {
    private let apiKey: String
    private let configuration: OpenRouterConfiguration
    private let session: URLSession

    public init(apiKey: String, configuration: OpenRouterConfiguration = .init(), session: URLSession = .shared) {
        self.apiKey = apiKey
        self.configuration = configuration
        self.session = session
    }

    /// Validates the key and returns its usage/limits (`GET /key`).
    public func keyInfo() async throws -> OpenRouterKeyInfo {
        struct Envelope: Decodable { var data: OpenRouterKeyInfo }
        let data = try await send(request(path: "key"))
        do {
            return try JSONDecoder().decode(Envelope.self, from: data).data
        } catch {
            throw OpenRouterError.unexpectedResponse(status: 200, message: "unreadable key info")
        }
    }

    // MARK: Chat completions

    public struct ImageResponse: Sendable {
        public var imageData: Data
        public var cost: Double?
        public var model: String?
    }

    public struct TextResponse: Sendable {
        public var text: String
        public var cost: Double?
    }

    /// One user message with text plus images (PNG), asking for an image back.
    public func imageCompletion(model: String, text: String, images: [Data], seed: Int? = nil) async throws -> ImageResponse {
        var content: [[String: Any]] = [["type": "text", "text": text]]
        for png in images {
            content.append(["type": "image_url",
                            "image_url": ["url": "data:image/png;base64," + png.base64EncodedString()]])
        }
        var body: [String: Any] = [
            "model": model,
            "messages": [["role": "user", "content": content]],
            "modalities": ["image", "text"],
            "usage": ["include": true],
        ]
        if let seed { body["seed"] = seed }
        let data = try await sendWithRetry(try request(path: "chat/completions", method: "POST",
                                                       body: JSONSerialization.data(withJSONObject: body)))
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw OpenRouterError.unexpectedResponse(status: 200, message: "not JSON")
        }
        guard let image = Self.extractImage(from: json) else {
            throw OpenRouterError.noImageInResponse(Self.extractText(from: json))
        }
        return ImageResponse(imageData: image, cost: Self.cost(json), model: json["model"] as? String)
    }

    /// Text-only (optionally multimodal) completion. `jsonMode` requests a JSON object.
    public func textCompletion(model: String, system: String?, user: String, images: [Data] = [],
                               imageType: String = "image/png",
                               jsonMode: Bool = false, temperature: Double = 0.2) async throws -> TextResponse {
        var messages: [[String: Any]] = []
        if let system { messages.append(["role": "system", "content": system]) }
        if images.isEmpty {
            messages.append(["role": "user", "content": user])
        } else {
            var content: [[String: Any]] = [["type": "text", "text": user]]
            for png in images {
                content.append(["type": "image_url",
                                "image_url": ["url": "data:\(imageType);base64," + png.base64EncodedString()]])
            }
            messages.append(["role": "user", "content": content])
        }
        var body: [String: Any] = ["model": model, "messages": messages, "temperature": temperature,
                                   "usage": ["include": true]]
        if jsonMode { body["response_format"] = ["type": "json_object"] }
        let data = try await sendWithRetry(try request(path: "chat/completions", method: "POST",
                                                       body: JSONSerialization.data(withJSONObject: body)))
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = Self.extractText(from: json) else {
            throw OpenRouterError.unexpectedResponse(status: 200, message: "no text in response")
        }
        return TextResponse(text: text, cost: Self.cost(json))
    }

    public struct ToolCall: Sendable, Equatable {
        public var name: String
        /// The arguments as the model sent them (a JSON object string).
        public var arguments: String
    }

    public struct ToolResponse: Sendable {
        public var text: String?
        public var toolCalls: [ToolCall]
        public var cost: Double?
    }

    /// Chat completion with function tools. `messages` are OpenAI-style
    /// `{"role", "content"}` dictionaries; `tools` are `{"type": "function", …}` schemas.
    public func toolCompletion(model: String, messages: [[String: Any]], tools: [[String: Any]],
                               temperature: Double = 0.2) async throws -> ToolResponse {
        let body: [String: Any] = ["model": model, "messages": messages, "tools": tools, "tool_choice": "auto",
                                   "parallel_tool_calls": true, "temperature": temperature,
                                   "usage": ["include": true]]
        let data = try await sendWithRetry(try request(path: "chat/completions", method: "POST",
                                                       body: JSONSerialization.data(withJSONObject: body)))
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any], Self.message(json) != nil else {
            throw OpenRouterError.unexpectedResponse(status: 200, message: "no message in response")
        }
        return ToolResponse(text: Self.extractText(from: json), toolCalls: Self.extractToolCalls(from: json), cost: Self.cost(json))
    }

    /// Accumulates a streamed chat completion (SSE `data:` chunks): text deltas
    /// are joined, and tool-call deltas are merged by their index.
    struct StreamAccumulator {
        var text = ""
        var calls: [Int: ToolCall] = [:]
        var cost: Double?

        /// Returns the text delta in this chunk, if any.
        mutating func consume(_ json: [String: Any]) -> String? {
            if let c = OpenRouterClient.cost(json) { cost = c }
            guard let delta = ((json["choices"] as? [[String: Any]])?.first)?["delta"] as? [String: Any] else { return nil }
            for call in delta["tool_calls"] as? [[String: Any]] ?? [] {
                let index = call["index"] as? Int ?? calls.count
                let function = call["function"] as? [String: Any] ?? [:]
                var current = calls[index] ?? ToolCall(name: "", arguments: "")
                if let name = function["name"] as? String { current.name += name }
                if let args = function["arguments"] as? String { current.arguments += args }
                calls[index] = current
            }
            guard let piece = delta["content"] as? String, !piece.isEmpty else { return nil }
            text += piece
            return piece
        }

        var response: ToolResponse {
            let ordered = calls.keys.sorted().compactMap { calls[$0] }.filter { !$0.name.isEmpty }
                .map { ToolCall(name: $0.name, arguments: $0.arguments.isEmpty ? "{}" : $0.arguments) }
            return ToolResponse(text: text.isEmpty ? nil : text, toolCalls: ordered, cost: cost)
        }
    }

    /// Like `toolCompletion`, but streams: `onText` gets the reply text so far as
    /// it grows. Falls back to the plain (retrying) call if the stream can't start.
    public func toolCompletionStreaming(model: String, messages: [[String: Any]], tools: [[String: Any]],
                                        temperature: Double = 0.2,
                                        onText: @escaping @Sendable (String) -> Void) async throws -> ToolResponse {
        let body: [String: Any] = ["model": model, "messages": messages, "tools": tools, "tool_choice": "auto",
                                   "parallel_tool_calls": true, "temperature": temperature,
                                   "usage": ["include": true], "stream": true]
        let request = try request(path: "chat/completions", method: "POST", body: JSONSerialization.data(withJSONObject: body))
        var accumulator = StreamAccumulator()
        do {
            let (bytes, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                throw OpenRouterError.unavailable(status: (response as? HTTPURLResponse)?.statusCode ?? 0)
            }
            for try await line in bytes.lines {
                guard line.hasPrefix("data:") else { continue }
                let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                if payload == "[DONE]" { break }
                guard let json = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any] else { continue }
                if accumulator.consume(json) != nil { onText(accumulator.text) }
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // Nothing usable arrived: use the ordinary call, which reports errors properly and retries.
            if accumulator.text.isEmpty && accumulator.calls.isEmpty {
                return try await toolCompletion(model: model, messages: messages, tools: tools, temperature: temperature)
            }
            throw OpenRouterError.network(error.localizedDescription)
        }
        return accumulator.response
    }

    static func extractToolCalls(from json: [String: Any]) -> [ToolCall] {
        guard let calls = message(json)?["tool_calls"] as? [[String: Any]] else { return [] }
        return calls.compactMap { call in
            guard let function = call["function"] as? [String: Any], let name = function["name"] as? String else { return nil }
            let args: String
            if let s = function["arguments"] as? String {
                args = s
            } else if let o = function["arguments"], let d = try? JSONSerialization.data(withJSONObject: o) {
                args = String(decoding: d, as: UTF8.self)
            } else {
                args = "{}"
            }
            return ToolCall(name: name, arguments: args)
        }
    }

    // MARK: Response parsing (mirrors workers/aips/providers/openrouter.py)

    static func cost(_ json: [String: Any]) -> Double? {
        ((json["usage"] as? [String: Any])?["cost"] as? NSNumber)?.doubleValue
    }

    static func message(_ json: [String: Any]) -> [String: Any]? {
        ((json["choices"] as? [[String: Any]])?.first)?["message"] as? [String: Any]
    }

    static func extractText(from json: [String: Any]) -> String? {
        guard let message = message(json) else { return nil }
        if let s = message["content"] as? String { return s }
        if let parts = message["content"] as? [[String: Any]] {
            let texts = parts.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }
            return texts.isEmpty ? nil : texts.joined(separator: "\n")
        }
        return nil
    }

    /// Finds image bytes in the three shapes OpenRouter image models return.
    static func extractImage(from json: [String: Any]) -> Data? {
        guard let message = message(json) else { return nil }
        // 1. message.images[*].image_url.url
        for img in message["images"] as? [[String: Any]] ?? [] {
            if let url = (img["image_url"] as? [String: Any])?["url"] as? String, let d = decodeDataURL(url) { return d }
        }
        // 2. content parts
        if let parts = message["content"] as? [[String: Any]] {
            for part in parts {
                let type = part["type"] as? String
                if type == "image_url" || type == "output_image" || type == "image" {
                    let url = (part["image_url"] as? [String: Any])?["url"] as? String ?? part["url"] as? String
                    if let url, let d = decodeDataURL(url) { return d }
                }
                if type == "text", let t = part["text"] as? String, let d = scanForDataURL(t) { return d }
            }
        }
        // 3. a data URL embedded in text
        if let s = message["content"] as? String { return scanForDataURL(s) }
        return nil
    }

    static func decodeDataURL(_ url: String) -> Data? {
        guard url.hasPrefix("data:"), let comma = url.firstIndex(of: ",") else { return nil }
        return Data(base64Encoded: String(url[url.index(after: comma)...]), options: .ignoreUnknownCharacters)
    }

    static func scanForDataURL(_ text: String) -> Data? {
        guard let start = text.range(of: "data:image/") else { return nil }
        let tail = text[start.lowerBound...]
        let end = tail.firstIndex { $0 == ")" || $0 == "\"" || $0 == " " || $0 == "\n" } ?? tail.endIndex
        return decodeDataURL(String(tail[..<end]))
    }

    // MARK: Transport

    /// Retries rate limits, 5xx and network errors with exponential backoff
    /// (as the web workers do). 401/402 are fatal and surface immediately.
    func sendWithRetry(_ request: URLRequest, maxRetries: Int = 4) async throws -> Data {
        var attempt = 0
        while true {
            do {
                return try await send(request)
            } catch let error as OpenRouterError where error.isRetryable && attempt < maxRetries {
                var delay = min(15, 0.5 * pow(2, Double(attempt))) * Double.random(in: 0.5...1)
                if case .rateLimited(let after?) = error { delay = min(after, 60) }
                attempt += 1
                try await Task.sleep(for: .seconds(delay))
            }
        }
    }

    func request(path: String, method: String = "GET", body: Data? = nil) throws -> URLRequest {
        guard !apiKey.isEmpty else { throw OpenRouterError.missingAPIKey }
        var request = URLRequest(url: configuration.baseURL.appending(path: path))
        request.httpMethod = method
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue(configuration.appTitle, forHTTPHeaderField: "X-Title")
        request.timeoutInterval = 240
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return request
    }

    func send(_ request: URLRequest) async throws -> Data {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw OpenRouterError.network(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw OpenRouterError.unexpectedResponse(status: 0, message: nil)
        }
        if let error = OpenRouterError.from(
            status: http.statusCode, body: data,
            retryAfterHeader: http.value(forHTTPHeaderField: "Retry-After")
        ) {
            throw error
        }
        return data
    }
}
