import Foundation

/// A language model for text: the one door every text request goes through (the Assistant's
/// plan and review, suggestions, Find Distractions). What stands behind it is chosen in one
/// place; callers never talk to a provider's client themselves (TextModelGuardTests).
///
/// Messages and tools are in the common chat form (`{"role", "content"}` dictionaries, with
/// pictures as `image_url` data URLs, and `{"type": "function", …}` tool schemas); an adapter
/// translates them to what its provider wants and leaves out what that provider refuses.
public protocol TextModel: Sendable {
    /// Shown in messages ("OpenRouter"), and the model's id there.
    var providerName: String { get }
    var modelID: String { get }

    /// Text and pictures in, text out. `json` asks for a JSON object.
    func reply(system: String?, user: String, images: [Data], imageType: String, json: Bool, temperature: Double) async throws -> TextReply

    /// The model answers by calling tools. With `onText`, the text part streams as it is written.
    func callTools(messages: sending [[String: Any]], tools: sending [[String: Any]], temperature: Double,
                   onText: (@Sendable (String) -> Void)?) async throws -> TextToolReply
}

public typealias TextReply = OpenRouterClient.TextResponse
public typealias TextToolReply = OpenRouterClient.ToolResponse
public typealias TextToolCall = OpenRouterClient.ToolCall

/// Text through OpenRouter (or the OpenRouter-compatible endpoint set in Settings), with the user's key.
public struct OpenRouterTextModel: TextModel {
    public let client: OpenRouterClient
    public let modelID: String
    public var providerName: String { "OpenRouter" }

    public init(client: OpenRouterClient, model: String) {
        self.client = client
        self.modelID = model
    }

    public func reply(system: String?, user: String, images: [Data], imageType: String, json: Bool, temperature: Double) async throws -> TextReply {
        try await client.textCompletion(model: modelID, system: system, user: user, images: images, imageType: imageType,
                                        jsonMode: json, temperature: temperature)
    }

    public func callTools(messages: sending [[String: Any]], tools: sending [[String: Any]], temperature: Double,
                          onText: (@Sendable (String) -> Void)?) async throws -> TextToolReply {
        if let onText {
            return try await client.toolCompletionStreaming(model: modelID, messages: messages, tools: tools, temperature: temperature, onText: onText)
        }
        return try await client.toolCompletion(model: modelID, messages: messages, tools: tools, temperature: temperature)
    }
}
