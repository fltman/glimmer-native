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
        let found = Bundle.main.localizedString(forKey: english, value: english, table: nil)
        if found != english { return found }
        // A message with a figure or a name in it: found by the catalogue entry whose fixed words
        // it has ("This RAW file is %@, more than Glimmer keeps in a document."), and said with the same values.
        for entry in patterns {
            guard let match = english.wholeMatch(of: entry.pattern) else { continue }
            let values = (1..<match.count).map { match[$0].substring.map(String.init) ?? "" }
            return filled(entry.translation, with: values)
        }
        return english
    }

    /// The translations with placeholders that this language has, as patterns for the English they translate, the most specific first.
    /// (Made once and only read afterwards.)
    nonisolated(unsafe) private static let patterns: [(pattern: Regex<AnyRegexOutput>, translation: String, own: Int)] = {
        guard let language = Bundle.main.preferredLocalizations.first, language != "en",
              let url = Bundle.main.url(forResource: "Localizable", withExtension: "strings", subdirectory: nil, localization: language),
              let table = NSDictionary(contentsOf: url) as? [String: String] else { return [] }
        let place = /%(?:\d+\$)?(?:@|lld|ld|d|lf)/
        var out: [(pattern: Regex<AnyRegexOutput>, translation: String, own: Int)] = []
        for (key, translation) in table where key.contains("%") {
            let pieces = key.split(separator: place, omittingEmptySubsequences: false).map { NSRegularExpression.escapedPattern(for: String($0).replacingOccurrences(of: "%%", with: "%")) }
            let own = pieces.reduce(0) { $0 + $1.count }
            guard pieces.count > 1, own >= 12, let pattern = try? Regex("(?s)" + pieces.joined(separator: "(.+?)")) else { continue }
            out.append((pattern, translation, own))
        }
        return out.sorted { $0.own > $1.own }
    }()

    /// A translation with its values put in: a numbered placeholder takes the value of that number, a plain one the next.
    private static func filled(_ translation: String, with values: [String]) -> String {
        var next = 0
        let place = /%(?:(\d+)\$)?(?:@|lld|ld|d|lf)/
        return translation.replacing(place) { match in
            if let number = match.1.flatMap({ Int($0) }), values.indices.contains(number - 1) { return values[number - 1] }
            defer { next += 1 }
            return values.indices.contains(next) ? values[next] : ""
        }.replacingOccurrences(of: "%%", with: "%")
    }

    /// The same error, saying it in the person's language when macOS presents it in an alert.
    static func presentable(_ error: Error) -> NSError {
        NSError(domain: "com.brattoo.glimmer", code: (error as NSError).code, userInfo: [NSLocalizedDescriptionKey: text(for: error)])
    }
}
