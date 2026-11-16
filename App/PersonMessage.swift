import Foundation

/// An error's words for a person, in the person's language. The package's refusals (a damaged
/// Photoshop file, a RAW file macOS can't develop) are written once, in English, and that is
/// what the agent API answers with. A window says the same thing through the string catalogue
/// when it has it there; a message with a figure or a name in it is shown as it is.
/// (Found 2026-11-16: every such refusal was English in the Swedish app.)
enum PersonMessage {
    static func text(for error: Error) -> String {
        let english = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        return text(english)
    }

    static func text(_ english: String) -> String {
        Bundle.main.localizedString(forKey: english, value: english, table: nil)
    }

    /// The same error, saying it in the person's language when macOS presents it in an alert.
    static func presentable(_ error: Error) -> NSError {
        NSError(domain: "com.brattoo.glimmer", code: (error as NSError).code, userInfo: [NSLocalizedDescriptionKey: text(for: error)])
    }
}
