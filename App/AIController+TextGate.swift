import Foundation
import GlimmerAI

/// What stands between a text request and the service it goes to: the first-use notice per
/// cloud service, and the refusal to send a picture to a model that takes none.
extension AIController {
    struct TextNotice: Identifiable {
        enum Kind { case firstUse, cantSee }
        let id = UUID()
        let kind: Kind
        let title: String
        let message: String
        /// For `firstUse`: what to do once the person has said Send.
        var proceed: (@MainActor () -> Void)?
    }

    static func toldKey(_ slug: String) -> String { "ai.textNoticeShown.\(slug)" }

    /// Whether the person has been told what goes to `provider`. A local server needs no telling.
    static func hasBeenTold(about provider: AIProvider) -> Bool {
        provider.kind != .cloud || UserDefaults.standard.bool(forKey: toldKey(provider.slug))
    }

    /// Runs `request` if it may go out now. Otherwise it puts up the notice that explains
    /// why not (a model that takes no pictures) or asks first (the first request to a cloud
    /// service), and `request` runs when the person says Send.
    func gateTextRequest(needsPicture: Bool, _ request: @escaping @MainActor () -> Void) {
        let provider = Self.textProvider
        let chosen = Self.chosenTextModel(for: provider)
        if needsPicture, chosen.vision == false {
            session.textNotice = TextNotice(
                kind: .cantSee,
                title: String(localized: "This model can't look at pictures"),
                message: String(localized: "\(provider.name) lists \(chosen.id) as a model without picture input, and this needs to see your document. Nothing was sent. Choose a model that takes pictures in Settings › AI."))
            return
        }
        // Without a key or a model there is nothing to ask about yet: the request itself says what is missing.
        guard hasTextModel, !Self.hasBeenTold(about: provider) else { return request() }
        session.textNotice = TextNotice(
            kind: .firstUse,
            title: String(localized: "Send this to \(provider.name)?"),
            message: Self.textNotice(for: provider, sendsPictures: chosen.vision != false) + " " + String(localized: "You can read this again in Settings › AI."),
            proceed: {
                UserDefaults.standard.set(true, forKey: Self.toldKey(provider.slug))
                request()
            })
    }

    /// What a text request sends to `provider`, said before the first one (the-apps/PROVIDERS.md,
    /// rule 7) and shown again in Settings. Only what is known: where it is processed is the
    /// service's own statement, when the register has one.
    static func textNotice(for provider: AIProvider, sendsPictures: Bool) -> String {
        var parts: [String] = []
        parts.append(sendsPictures
            ? String(localized: "The Assistant sends what you typed, the list of Glimmer's operations, a description of your document (its size and layers) and a small picture of it to \(provider.name) (\(provider.host)).")
            : String(localized: "The Assistant sends what you typed, the list of Glimmer's operations and a description of your document (its size and layers) to \(provider.name) (\(provider.host)). The chosen model takes no pictures, so none is sent."))
        parts.append(String(localized: "Suggest Edits and Find Distractions send a picture of the document too."))
        if provider.kind == .cloud {
            if let place = provider.dataNote { parts.append(String(localized: "\(provider.name) says it processes this in \(place).")) }
            parts.append(String(localized: "\(provider.name) bills your key for each request."))
        } else {
            parts.append(String(localized: "Nothing leaves this Mac and nothing is billed."))
        }
        return parts.joined(separator: " ")
    }
}
