import Foundation

/// A sentence saying that something was done must not stand when it was not (SIBLINGS.md,
/// "Påståenden om vad som gjordes"; Jämmer showed "VCA Voices removed." above a step that
/// never ran).
///
/// Glimmer shows the model's sentence above the plan's steps. So:
/// - when every step was left out or refused, the sentence is not shown: only the app's own
///   line about what was not done and why;
/// - when steps remain, the sentence is shown only if it names no operation beyond those
///   steps. Glimmer tells by the words a request names an operation by (`PlanCheck.words`
///   and `PlanCheck.kinds`); where a sentence names another operation, or the model planned
///   a step that doesn't exist, the app's own line and the list of steps stand alone;
/// - when a plan stopped part-way, the app's own list of what was done and what was not
///   replaces the sentence.
///
/// The check sees the naming of operations, not grammar: a sentence that names nothing
/// Glimmer knows ("All done!") stands, above a list that shows each step's own state.
public enum PlanClaims {
    /// Stems too common to mean an operation by themselves ("layer" is in most sentences about a document).
    static let generic: Set<String> = ["layer", "lager", "text", "size", "storlek", "color", "colour", "färg", "name", "namn", "show", "visa",
                                       "fix", "better", "auto", "style", "stil", "look", "format", "light", "ljus", "ton", "film", "soft", "mjuk",
                                       "pop", "stop", "steg", "raw", "scale", "skala", "move", "turn", "pad", "fill", "fyll", "pixel", "effect", "effekt",
                                       "filter", "level", "cast", "stick", "dark", "bright", "mörk", "width", "height", "bredd", "höjd", "half", "double",
                                       "bigger", "larger", "smaller", "större", "mindre", "depth", "image", "bild", "balance", "balans", "visible", "synlig",
                                       "warm", "cool", "cold", "varm", "kall", "tint", "resolution", "upplösning", "hälften", "dubbel", "square", "kvadrat"]

    /// The words that name what `step` does.
    static func stems(for step: AgentStep) -> [String] {
        var stems = PlanCheck.words[step.op] ?? []
        stems += [step.op, step.op.replacingOccurrences(of: "_", with: " ")]
        if let kind = step.string("type")?.lowercased() {
            stems += (PlanCheck.kinds[kind] ?? []) + [kind, kind.replacingOccurrences(of: "_", with: " ")]
        }
        return stems
    }

    /// Whether `text` names an operation that is not among `steps`.
    public static func claimsMore(_ text: String, than steps: [AgentStep]) -> Bool {
        let lower = text.lowercased()
        let explained = steps.flatMap(stems(for:))
        func stray(_ stems: [String]) -> Bool {
            stems.contains { stem in
                !generic.contains(stem) && lower.contains(stem) && !explained.contains { $0.contains(stem) || stem.contains($0) }
            }
        }
        let ops = Set(steps.map(\.op)), kinds = Set(steps.compactMap { $0.string("type")?.lowercased() })
        if PlanCheck.words.contains(where: { !ops.contains($0.key) && stray($0.value + [$0.key, $0.key.replacingOccurrences(of: "_", with: " ")]) }) { return true }
        return PlanCheck.kinds.contains { !kinds.contains($0.key) && stray($0.value) }
    }

    /// The model's sentence, when it may stand above these steps; nil when the app's own line stands alone.
    public static func shown(_ message: String?, steps: [AgentStep], madeUpSteps: Bool) -> String? {
        guard let message, !steps.isEmpty, !madeUpSteps, !claimsMore(message, than: steps) else { return nil }
        return message
    }
}
