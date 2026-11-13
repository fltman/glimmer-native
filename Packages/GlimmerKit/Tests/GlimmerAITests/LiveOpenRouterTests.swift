import Foundation
import Testing
@testable import GlimmerAI

/// Real OpenRouter calls. Opt in with GLIMMER_LIVE_AI=1 and OPENROUTER_API_KEY;
/// each run costs a few cents.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["GLIMMER_LIVE_AI"] == "1"))
struct LiveOpenRouterTests {
    let key = ProcessInfo.processInfo.environment["OPENROUTER_API_KEY"] ?? ""

    @Test func keyIsValid() async throws {
        let info = try await OpenRouterClient(apiKey: key).keyInfo()
        print("OpenRouter key OK, usage: \(info.usage ?? -1)")
    }

    @Test func generatesAnImage() async throws {
        let model = OpenRouterImageModel(client: OpenRouterClient(apiKey: key), model: "google/gemini-2.5-flash-image",
                                         cacheDirectory: nil)
        let result = try await AIPipelines.generate(prompt: "A single red apple on a white table, studio photo",
                                                    width: 512, height: 512, model: model)
        print("Generated \(result.image.width)×\(result.image.height), cost \(result.cost ?? -1)")
        #expect(result.image.width > 64 && result.image.height > 64)
    }

    @Test func badKeyIsFatalNotRetried() async {
        let client = OpenRouterClient(apiKey: "sk-or-v1-invalid")
        await #expect(throws: OpenRouterError.invalidAPIKey) {
            _ = try await client.keyInfo()
        }
    }
}
