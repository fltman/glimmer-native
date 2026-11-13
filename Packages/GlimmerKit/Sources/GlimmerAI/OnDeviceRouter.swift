import Foundation
import FoundationModels

/// Routes text typed into the omnibar with Apple's on-device language model,
/// before anything is sent to OpenRouter: a request that one editor command
/// covers runs straight away, "make a picture of …" goes to Generate, and
/// everything else goes to the (paid) planner.
public enum OnDeviceRouter {
    public struct Candidate: Sendable, Hashable {
        public var id: String
        public var title: String
        public var subtitle: String

        public init(id: String, title: String, subtitle: String) {
            self.id = id
            self.title = title
            self.subtitle = subtitle
        }
    }

    public enum Decision: Sendable, Equatable {
        /// Run this candidate (by id).
        case run(String)
        /// Generate a new image from this prompt.
        case generate(String)
        /// Hand the request to the planner.
        case assistant
    }

    @Generable
    struct Route {
        @Generable
        enum Action {
            case run
            case generate
            case assistant
        }

        @Guide(description: "run, generate or assistant")
        var action: Action
        @Guide(description: "For run: the id of the one option that does what the user asked. Otherwise an empty string.")
        var optionID: String
        @Guide(description: "For generate: a detailed image prompt in English. Otherwise an empty string.")
        var prompt: String
    }

    public static var isAvailable: Bool {
        if case .available = SystemLanguageModel.default.availability { return true }
        return false
    }

    static let instructions = """
    You route requests typed into the command bar of a photo editor. Decide one action:
    - run: exactly ONE of the listed options fully does what the user asked by itself (for example "invert", "flip horizontal", "new layer", "select all", "black and white", the brush tool). Give its id.
    - generate: the user wants a brand-new picture created from a description ("a cat astronaut", "make an image of a castle at sunset"), not a change to the current photo. Write a good prompt.
    - assistant: anything else: several steps, specific amounts or settings ("brighten it by 20%", "warmer and with a vignette"), changes to the photo's content ("remove the person", "make it snowy"), or questions.
    When in doubt, answer assistant.
    """

    /// Decides what to do with `text`. `candidates` should be the best fuzzy
    /// matches from the command palette (a dozen or so).
    public static func route(_ text: String, candidates: [Candidate]) async throws -> Decision {
        let session = LanguageModelSession(instructions: instructions)
        let options = candidates.map { "- id: \($0.id) — \($0.title) (\($0.subtitle))" }.joined(separator: "\n")
        let prompt = """
        OPTIONS:
        \(options.isEmpty ? "(none)" : options)

        REQUEST: \(text)
        """
        let route = try await session.respond(to: prompt, generating: Route.self,
                                              options: GenerationOptions(temperature: 0)).content
        return decision(route, text: text, candidates: candidates)
    }

    /// Validates the model's answer: unknown ids and empty prompts fall back to the assistant.
    static func decision(_ route: Route, text: String, candidates: [Candidate]) -> Decision {
        switch route.action {
        case .run:
            let id = route.optionID.trimmingCharacters(in: .whitespaces)
            return candidates.contains { $0.id == id } ? .run(id) : .assistant
        case .generate:
            let prompt = route.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
            return .generate(prompt.isEmpty ? text : prompt)
        case .assistant:
            return .assistant
        }
    }
}
