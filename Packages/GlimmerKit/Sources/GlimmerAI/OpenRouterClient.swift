import Foundation

public enum AIDefaults {
    public static let imageModel = "google/gemini-3-pro-image-preview"
    public static let textModel = "google/gemini-2.5-flash"

    public static let imageModelKey = "ai.imageModel"
    public static let textModelKey = "ai.textModel"
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
        case .network(let m): "Network error: \(m)"
        case .unexpectedResponse(let s, let m): "Unexpected response (HTTP \(s))." + (m.map { " \($0)" } ?? "")
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

    public init(baseURL: URL = URL(string: "https://openrouter.ai/api/v1")!, appTitle: String = "Glimmer") {
        self.baseURL = baseURL
        self.appTitle = appTitle
    }
}

/// Talks to OpenRouter with the user's own API key.
/// Image/text completion endpoints arrive in phase 3.
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

    func request(path: String, method: String = "GET", body: Data? = nil) throws -> URLRequest {
        guard !apiKey.isEmpty else { throw OpenRouterError.missingAPIKey }
        var request = URLRequest(url: configuration.baseURL.appending(path: path))
        request.httpMethod = method
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue(configuration.appTitle, forHTTPHeaderField: "X-Title")
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
