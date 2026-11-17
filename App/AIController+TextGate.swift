import Foundation
import GlimmerAI

/// What stands between a text request and the service it goes to: the first-use notice per
/// cloud service, and the refusal to send a picture to a model that takes none.
extension AIController {
    struct TextNotice: Identifiable {
        enum Kind { case firstUse, cantSee, unknownPrice }
        let id = UUID()
        let kind: Kind
        let title: String
        let message: String
        /// For `firstUse`: what to do once the person has said Send.
        var proceed: (@MainActor () -> Void)?
    }

    static func toldKey(_ slug: String) -> String { "ai.textNoticeShown.\(slug)" }

    /// Set when the notice that was agreed to said that a picture of the document is sent.
    static func toldPicturesKey(_ slug: String) -> String { "ai.textNoticeShown.\(slug).pictures" }

    /// Whether the person has been told what goes to `provider`. A local server needs no telling.
    /// Someone who agreed while a model without picture input was chosen was told that no
    /// picture is sent, so the first request that does send one asks again.
    static func hasBeenTold(about provider: AIProvider, sendsPictures: Bool) -> Bool {
        guard provider.kind == .cloud else { return true }
        let d = UserDefaults.standard
        return d.bool(forKey: toldKey(provider.slug)) && (!sendsPictures || d.bool(forKey: toldPicturesKey(provider.slug)))
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
        let sendsPictures = chosen.vision != false   // the same rule as the request itself (AIController+Agent)
        // Then the price: known from the service's own list, or the person's once-per-service word that it is not.
        let request: @MainActor () -> Void = { [weak self] in self?.gateTextPrice(provider, model: chosen.id, request) }
        guard hasTextModel, !Self.hasBeenTold(about: provider, sendsPictures: sendsPictures) else { return request() }
        session.textNotice = TextNotice(
            kind: .firstUse,
            title: String(localized: "Send this to \(provider.name)?"),
            message: Self.textNotice(for: provider, sendsPictures: sendsPictures) + " " + String(localized: "You can read this again in Settings › AI."),
            proceed: {
                UserDefaults.standard.set(true, forKey: Self.toldKey(provider.slug))
                if sendsPictures { UserDefaults.standard.set(true, forKey: Self.toldPicturesKey(provider.slug)) }
                request()
            })
    }

    // MARK: The price of a text request (the-apps/SIBLINGS.md, "Okänt pris")

    /// What the service's own list said the chosen model costs, and when Glimmer read it (Settings › AI reads the list).
    struct ListedPrice { let line: String; let read: Date }

    static func textPriceKey(_ slug: String) -> String { "ai.textPrice.\(slug)" }
    /// Set when the person has said, once for this service, that they know it states no price in advance. Taken back in Settings › AI.
    static func textUnknownPriceKey(_ slug: String) -> String { "ai.unknownPriceAgreed.text.\(slug)" }

    /// Called when Settings has read the service's model list: keeps the chosen model's listed price with the time, or forgets it when the list has none.
    static func rememberTextPrice(_ slug: String, model: String, line: String?) {
        let d = UserDefaults.standard
        if let line { d.set(["model": model, "line": line, "read": Date()] as [String: Any], forKey: textPriceKey(slug)) }
        else { d.removeObject(forKey: textPriceKey(slug)) }
    }

    /// The listed price of the model now chosen for `provider`, if the list had one when it was last read.
    static func listedTextPrice(for provider: AIProvider) -> ListedPrice? {
        guard let kept = UserDefaults.standard.dictionary(forKey: textPriceKey(provider.slug)),
              kept["model"] as? String == chosenTextModel(for: provider).id,
              let line = kept["line"] as? String, let read = kept["read"] as? Date else { return nil }
        return ListedPrice(line: line, read: read)
    }

    /// Whether a text request to `provider` may go without asking about the price: nothing is billed (this Mac), the price is listed, or the person has said they know it is not.
    static func textPriceSettled(for provider: AIProvider) -> Bool {
        provider.kind != .cloud || listedTextPrice(for: provider) != nil || UserDefaults.standard.bool(forKey: textUnknownPriceKey(provider.slug))
    }

    /// The line the Assistant shows about what a request costs; nil when nothing is billed.
    static func textPriceLine(for provider: AIProvider) -> String? {
        guard provider.kind == .cloud else { return nil }
        if let listed = listedTextPrice(for: provider) {
            return String(localized: "\(provider.name)'s list, read \(listed.read.formatted(date: .abbreviated, time: .shortened)): \(listed.line).")
        }
        return String(localized: "Price not known in advance")
    }

    private func gateTextPrice(_ provider: AIProvider, model: String, _ request: @escaping @MainActor () -> Void) {
        guard hasTextModel, !Self.textPriceSettled(for: provider) else { return request() }
        // After the alert before this one (if any) has gone: it clears the notice as it closes.
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(450))
            self?.session.textNotice = TextNotice(
                kind: .unknownPrice,
                title: String(localized: "\(provider.name) states no price in advance"),
                message: String(localized: "Glimmer has read no price for \(model) from \(provider.name)'s list, so it cannot say what a request costs. \(provider.name) bills your key for each request. You are asked this once for \(provider.name); it is kept in Settings › AI, where you can take it back."),
                proceed: {
                    UserDefaults.standard.set(true, forKey: Self.textUnknownPriceKey(provider.slug))
                    request()
                })
        }
    }

    /// What a text request sends to `provider`, said before the first one (the-apps/PROVIDERS.md,
    /// rule 7) and shown again in Settings. Only what is known: where it is processed is the
    /// service's own statement, when the register has one.
    static func textNotice(for provider: AIProvider, sendsPictures: Bool) -> String {
        var parts: [String] = []
        parts.append(sendsPictures
            ? String(localized: "The Assistant sends what you typed, the list of Glimmer's operations, a description of your document (its size and layers) and a small picture of it to \(provider.name) (\(provider.host)).")
            : String(localized: "The Assistant sends what you typed, the list of Glimmer's operations and a description of your document (its size and layers) to \(provider.name) (\(provider.host)). The chosen model takes no pictures, so none is sent."))
        parts.append(sendsPictures
            ? String(localized: "Suggest Edits and Find Distractions send a picture of the document too.")
            : String(localized: "Suggest Edits and Find Distractions need to see the document, so they don't run with this model."))
        if provider.kind == .cloud {
            if let place = provider.dataNote { parts.append(String(localized: "\(provider.name) says it processes this in \(place).")) }
            parts.append(String(localized: "\(provider.name) bills your key for each request."))
        } else {
            parts.append(String(localized: "Nothing leaves this Mac and nothing is billed."))
        }
        return parts.joined(separator: " ")
    }
}
