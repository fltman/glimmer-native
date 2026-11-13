import Foundation
import Testing
@testable import GlimmerAI

@Suite struct OpenRouterErrorTests {
    private let body = Data(#"{"error": {"message": "Nope", "code": 400}}"#.utf8)

    @Test func successIsNotAnError() {
        #expect(OpenRouterError.from(status: 200, body: Data(), retryAfterHeader: nil) == nil)
    }

    @Test func authAndCreditErrorsAreFatal() {
        let invalid = OpenRouterError.from(status: 401, body: body, retryAfterHeader: nil)
        let credits = OpenRouterError.from(status: 402, body: body, retryAfterHeader: nil)
        #expect(invalid == .invalidAPIKey)
        #expect(credits == .insufficientCredits)
        #expect(invalid?.isRetryable == false)
        #expect(credits?.isRetryable == false)
    }

    @Test func rateLimitCarriesRetryAfter() {
        let error = OpenRouterError.from(status: 429, body: Data(), retryAfterHeader: "12")
        #expect(error == .rateLimited(retryAfter: 12))
        #expect(error?.isRetryable == true)
    }

    @Test func mapsOtherStatuses() {
        #expect(OpenRouterError.from(status: 400, body: body, retryAfterHeader: nil) == .badRequest("Nope"))
        #expect(OpenRouterError.from(status: 403, body: body, retryAfterHeader: nil) == .contentPolicy("Nope"))
        #expect(OpenRouterError.from(status: 503, body: Data(), retryAfterHeader: nil) == .unavailable(status: 503))
        #expect(OpenRouterError.from(status: 418, body: Data(), retryAfterHeader: nil)
                == .unexpectedResponse(status: 418, message: nil))
    }

    @Test func decodesKeyInfo() throws {
        struct Envelope: Decodable { var data: OpenRouterKeyInfo }
        let json = #"{"data": {"label": "sk-or-v1-abc...", "usage": 1.5, "limit": null, "is_free_tier": false}}"#
        let info = try JSONDecoder().decode(Envelope.self, from: Data(json.utf8)).data
        #expect(info.usage == 1.5)
        #expect(info.limit == nil)
        #expect(info.isFreeTier == false)
    }

    @Test func missingKeyFailsBeforeNetwork() async {
        let client = OpenRouterClient(apiKey: "")
        await #expect(throws: OpenRouterError.missingAPIKey) {
            _ = try await client.keyInfo()
        }
    }
}

@Suite struct SecretStoreTests {
    @Test func inMemoryStore() throws {
        let store = InMemorySecretStore()
        #expect(try store.read() == nil)
        try store.write("sk-test")
        #expect(try store.read() == "sk-test")
        try store.delete()
        #expect(try store.read() == nil)
    }
}
