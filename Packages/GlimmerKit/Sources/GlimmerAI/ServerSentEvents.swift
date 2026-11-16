import Foundation

/// Reads an answer that arrives as server-sent events: each `data:` line holds one JSON
/// object. Used by the Anthropic and OpenAI adapters when the Assistant wants the text as
/// it comes. The request carries a key, so it goes through `KeyStaysHome`.
enum ServerSentEvents {
    /// Calls `event` for each JSON object, in order. A status other than 2xx is the
    /// service's own error, read from the body.
    static func read(_ request: URLRequest, provider: String, session: URLSession,
                     event: ([String: Any]) throws -> Void) async throws {
        let bytes: URLSession.AsyncBytes, response: URLResponse
        do { (bytes, response) = try await session.bytes(for: request, delegate: KeyStaysHome.shared) } catch {
            throw OpenRouterError.network(error.localizedDescription)
        }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            var body = Data()
            for try await byte in bytes { body.append(byte); if body.count > 65_536 { break } }
            throw ProviderHTTPError(provider: provider, status: http.statusCode, message: ProviderHTTPError.message(from: body))
        }
        do {
            for try await line in bytes.lines {
                try Task.checkCancellation()
                guard line.hasPrefix("data:") else { continue }
                let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                if payload == "[DONE]" { break }
                guard let json = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any] else { continue }
                try event(json)
            }
        } catch let error as URLError {
            throw OpenRouterError.network(error.localizedDescription)
        }
    }
}

/// Puts Anthropic's stream events together into the `content` blocks a whole answer has
/// (Messages API: `content_block_start`, `content_block_delta` with `text_delta` or
/// `input_json_delta`, `message_delta` with the stop reason; read on platform.claude.com 2026-11-16).
struct AnthropicStream {
    private var blocks: [Int: [String: Any]] = [:]
    private var partialInput: [Int: String] = [:]
    private(set) var stopReason: String?
    private(set) var stopCategory: String?

    /// Takes one event. True when the text grew.
    mutating func consume(_ event: [String: Any], provider: String) throws -> Bool {
        switch event["type"] as? String {
        case "content_block_start":
            guard let index = event["index"] as? Int, let block = event["content_block"] as? [String: Any] else { return false }
            blocks[index] = block
        case "content_block_delta":
            guard let index = event["index"] as? Int, let delta = event["delta"] as? [String: Any] else { return false }
            if delta["type"] as? String == "text_delta", let more = delta["text"] as? String {
                blocks[index, default: ["type": "text"]]["text"] = ((blocks[index]?["text"] as? String) ?? "") + more
                return true
            }
            if delta["type"] as? String == "input_json_delta", let more = delta["partial_json"] as? String {
                partialInput[index, default: ""] += more
            }
        case "message_delta":
            let delta = event["delta"] as? [String: Any]
            stopReason = delta?["stop_reason"] as? String ?? stopReason
            stopCategory = (delta?["stop_details"] as? [String: Any])?["category"] as? String ?? stopCategory
        case "error":
            let message = (event["error"] as? [String: Any])?["message"] as? String
            throw ProviderHTTPError(provider: provider, status: 200, message: message ?? "The answer stopped with an error.")
        default:
            break
        }
        return false
    }

    /// The blocks in order; a tool call's input is the JSON its pieces add up to.
    var content: [[String: Any]] {
        blocks.keys.sorted().map { index in
            var block = blocks[index]!
            if block["type"] as? String == "tool_use", let text = partialInput[index], !text.isEmpty,
               let input = try? JSONSerialization.jsonObject(with: Data(text.utf8)) {
                block["input"] = input
            }
            return block
        }
    }

    var text: String { AnthropicTextModel.text(in: content) }
}

/// Puts OpenAI's Responses stream together: text from `response.output_text.delta`, tool
/// calls from `response.output_item.done` (the item holds the whole call), an `error` event
/// with its message (OpenAI's streaming and function-calling guides, read 2026-11-16).
struct ResponsesStream {
    private(set) var text = ""
    private(set) var items: [[String: Any]] = []

    mutating func consume(_ event: [String: Any], provider: String) throws -> Bool {
        switch event["type"] as? String {
        case "response.output_text.delta":
            guard let more = event["delta"] as? String else { return false }
            text += more
            return true
        case "response.output_item.done":
            if let item = event["item"] as? [String: Any] { items.append(item) }
        case "error":
            throw ProviderHTTPError(provider: provider, status: 200, message: event["message"] as? String ?? "The answer stopped with an error.")
        case "response.failed":
            let message = ((event["response"] as? [String: Any])?["error"] as? [String: Any])?["message"] as? String
            throw ProviderHTTPError(provider: provider, status: 200, message: message ?? "The request failed at the service.")
        default:
            break
        }
        return false
    }
}
