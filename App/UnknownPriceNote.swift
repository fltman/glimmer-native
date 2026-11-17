import GlimmerAI
import SwiftUI

/// The line every paid plan and sheet carries while the picture service states no price in
/// advance, and under it, until it has been made, the once-per-service tick
/// (the-apps/SIBLINGS.md, "Okänt pris"). The tick is kept in Settings › AI, where it can be taken back.
struct UnknownPriceNote: View {
    @AppStorage(AIController.imageProviderKey) private var chosen = "openrouter"

    var body: some View {
        let provider = AIController.imageProvider
        if !PaidPrice.knownInAdvance(service: provider.slug) {
            VStack(alignment: .leading, spacing: 4) {
                StatusLine(.notice, "Price not known in advance")
                    .font(.caption).foregroundStyle(.secondary)
                UnknownPriceTick(provider: provider, onlyUntilMade: true)
            }
            .id(chosen)
        }
    }
}

/// "<service> does not state a price in advance; I know": one tick per service.
struct UnknownPriceTick: View {
    let provider: AIProvider
    /// In a sheet or a plan the tick goes away once made; in Settings it stays, to be taken back.
    var onlyUntilMade = false
    @AppStorage private var agreed: Bool
    @State private var shownAtStart: Bool

    /// `key`: the picture service's tick unless another is given (the text service has its own).
    init(provider: AIProvider, key: String? = nil, onlyUntilMade: Bool = false) {
        self.provider = provider
        self.onlyUntilMade = onlyUntilMade
        let key = key ?? AIController.unknownPriceKey(provider.slug)
        _agreed = AppStorage(wrappedValue: false, key)
        _shownAtStart = State(initialValue: !UserDefaults.standard.bool(forKey: key))
    }

    var body: some View {
        // Made here, it stays in sight (ticked) until the sheet closes: a tick that vanishes when clicked looks like a fault.
        if !onlyUntilMade || shownAtStart {
            Toggle("\(provider.name) does not state a price in advance; I know", isOn: $agreed)
                .toggleStyle(.checkbox)
                .font(onlyUntilMade ? .caption : .body)
        }
    }
}

/// Greys a button that starts a paid picture job until the tick for the chosen service is made.
struct NeedsUnknownPriceTick: ViewModifier {
    var applies = true
    @AppStorage(AIController.imageProviderKey) private var chosen = "openrouter"

    func body(content: Content) -> some View {
        content.modifier(Gate(applies: applies, key: AIController.unknownPriceKey(AIController.imageProvider.slug),
                              known: PaidPrice.knownInAdvance(service: AIController.imageProvider.slug)))
            .id(chosen)
    }

    private struct Gate: ViewModifier {
        let applies: Bool
        let known: Bool
        @AppStorage private var agreed: Bool
        init(applies: Bool, key: String, known: Bool) {
            self.applies = applies; self.known = known
            _agreed = AppStorage(wrappedValue: false, key)
        }
        func body(content: Content) -> some View {
            // The system's disabled look for a prominent button keeps most of its colour; this one is to read as grey.
            let off = applies && !known && !agreed
            content.disabled(off).tint(off ? Color.gray : nil)
        }
    }
}

extension View {
    /// For a button that starts a paid picture job: grey until the price is known or the person has ticked that it isn't.
    func needsUnknownPriceTick(_ applies: Bool = true) -> some View { modifier(NeedsUnknownPriceTick(applies: applies)) }
}
