import Foundation

/// Glimmer's own test of a text model before it is offered as the Assistant's model
/// (the-apps/PROVIDERS.md, rule 6): everyday requests in English and Swedish, each with the
/// tool call that answers it. A model passes when it gets enough of them right, with no
/// made-up tools, fast enough to wait for.
public enum LocalModelEvaluation {
    public struct Case: Sendable {
        public let goal: String
        public let language: String
        /// The operation that answers it, and parameter values that must be there (as text; numbers within 1 %).
        public let op: String
        public let params: [String: String]
        /// Other parameter sets that give the same result (half the size of the 2400 × 1600 test
        /// document is `scale: 0.5`, and it is also `width: 1200`).
        public var alternatives: [[String: String]] = []
        /// A question to answer in words: no step may be planned, and the answer may hold no
        /// figure that the editor state didn't give (`AssistantNumbers`).
        public var answerOnly = false
        /// A request that names no edit ("write a poem about the sea"): whatever is answered,
        /// no step may be planned, because nothing in the document was asked to change.
        public var changesNothing = false
        /// The request names its step plainly, so the plan must be one that runs at once
        /// (`PlanCheck`): the check on unnamed steps must not quietly become "always ask".
        public var mustRunAtOnce = false
        /// A known gap, measured and not counted in the verdict: the check sees figures, not
        /// claims, so "it is free" gets through. Held when the answer doesn't call a paid
        /// feature free, cheap or expensive, and points to Settings or says that it costs.
        public var knownGap = false
    }

    /// The cases the verdict counts.
    public static var scored: [Case] { cases.filter { !$0.knownGap } }

    public static let cases: [Case] = [
        Case(goal: "Make the photo black and white", language: "en", op: "add_adjustment", params: ["type": "black_white"]),
        Case(goal: "Gör bilden svartvit", language: "sv", op: "add_adjustment", params: ["type": "black_white"]),
        Case(goal: "Crop the image to 16:9", language: "en", op: "crop", params: ["aspect": "16:9"]),
        Case(goal: "Beskär bilden till en kvadrat", language: "sv", op: "crop", params: ["aspect": "1:1"]),
        Case(goal: "Remove the background", language: "en", op: "remove_background", params: [:]),
        Case(goal: "Ta bort bakgrunden", language: "sv", op: "remove_background", params: [:]),
        Case(goal: "Add the text Hello at the top", language: "en", op: "add_text", params: ["text": "Hello", "position": "top"]),
        Case(goal: "Lägg till texten Hej längst ner", language: "sv", op: "add_text", params: ["text": "Hej", "position": "bottom"]),
        Case(goal: "Improve the photo automatically", language: "en", op: "auto_enhance", params: [:]),
        Case(goal: "Gör bilden hälften så stor", language: "sv", op: "resize_image", params: ["scale": "0.5"],
             alternatives: [["width": "1200"], ["height": "800"], ["width": "1200", "height": "800"]]),
        Case(goal: "Make the layer half transparent", language: "en", op: "set_layer", params: ["opacity": "0.5"]),
        Case(goal: "Markera motivet", language: "sv", op: "select_subject", params: [:]),
        Case(goal: "How big is this document, in pixels?", language: "en", op: "", params: [:], answerOnly: true),
        Case(goal: "Hur många lager har dokumentet och vad kostar det att förstora det?", language: "sv", op: "", params: [:], answerOnly: true),
        Case(goal: "Make it black and white", language: "en", op: "add_adjustment", params: ["type": "black_white"], mustRunAtOnce: true),
        Case(goal: "Write a poem about the sea", language: "en", op: "", params: [:], changesNothing: true),
        Case(goal: "Berätta ett skämt", language: "sv", op: "", params: [:], changesNothing: true),
        Case(goal: "Thanks, that looks good", language: "en", op: "", params: [:], changesNothing: true),
        // Generating goes to a paid service, so "free" would be wrong. (Upscaling was the first
        // question here, and it is in fact done on the Mac at no cost: a bad test of the gap.)
        Case(goal: "Is generating a new image free?", language: "en", op: "", params: [:], answerOnly: true, knownGap: true),
    ]

    public struct Outcome: Sendable {
        public let goal: String
        public let language: String
        public let seconds: Double
        public let passed: Bool
        /// What the model did, for the report.
        public let got: String
        /// A known gap: shown in the report, left out of the verdict.
        public var knownGap = false
    }

    public struct Report: Sendable {
        public let model: String
        public let outcomes: [Outcome]
        /// What the verdict counts, and the known gaps beside it.
        public var scored: [Outcome] { outcomes.filter { !$0.knownGap } }
        public var gaps: [Outcome] { outcomes.filter(\.knownGap) }
        public var passed: Int { scored.filter(\.passed).count }
        public func passed(language: String) -> (Int, Int) {
            let some = scored.filter { $0.language == language }
            return (some.filter(\.passed).count, some.count)
        }
        public var slowest: Double { scored.map(\.seconds).max() ?? 0 }
        public var median: Double { let s = scored.map(\.seconds).sorted(); return s.isEmpty ? 0 : s[s.count / 2] }
        /// "known gaps: 0 of 1 held" for the report's last line.
        public var gapLine: String { gaps.isEmpty ? "" : " Known gaps (not counted): \(gaps.filter(\.passed).count) of \(gaps.count) held." }

        /// At least five in six right, overall and in each language (15 of 18, 9 of 10 in English,
        /// 7 of 8 in Swedish), and none slower than a minute.
        public var passes: Bool {
            let en = passed(language: "en"), sv = passed(language: "sv")
            return passed * 6 >= scored.count * 5 && en.0 * 6 >= en.1 * 5 && sv.0 * 6 >= sv.1 * 5 && slowest <= LocalModelEvaluation.slowestAllowed
        }
    }

    public static let slowestAllowed = 60.0

    /// Whether `plan` answers `test`: the right operation with the right values, and nothing made up.
    public static func judge(_ plan: AgentPlan, _ test: Case) -> Bool {
        if test.knownGap {
            let said = plan.message ?? ""
            // Held: no step, no figure, no "free"/"cheap"/"expensive", and it either points to
            // Settings or says that it costs (which Glimmer's own list of operations states).
            let lower = said.lowercased()
            let pointsOrPaid = ["settings", "inställningar", "costs money", "costs credits", "paid", "kostar pengar", "not free", "inte gratis"].contains { lower.contains($0) }
            return plan.steps.isEmpty && plan.removedFigures.isEmpty && !AssistantNumbers.claimsACost(lower.replacingOccurrences(of: "not free", with: "").replacingOccurrences(of: "inte gratis", with: "")) && pointsOrPaid
        }
        // Nothing may change without confirmation: no step, or a plan that waits for Run.
        if test.changesNothing { return plan.droppedOps.isEmpty && (plan.steps.isEmpty || !PlanCheck.runsAtOnce(plan, request: test.goal)) }
        // What was asked for must run at once: the whole plan, or the plan without a self-contained
        // extra that is held back as an offer. The step that runs is the one judged below.
        var plan = plan
        if test.mustRunAtOnce, !PlanCheck.runsAtOnce(plan, request: test.goal) {
            guard let split = PlanCheck.withoutExtras(plan, request: test.goal) else { return false }
            plan = split.runs
        }
        if test.answerOnly { return plan.steps.isEmpty && plan.droppedOps.isEmpty && plan.removedFigures.isEmpty }
        guard plan.droppedOps.isEmpty, let step = plan.steps.first(where: { $0.op == test.op }) else { return false }
        // Every step must be a real operation with only parameters that operation has.
        for s in plan.steps {
            guard let op = AgentPlanner.op(named: s.op) else { return false }
            let known = Set(op.params.map(\.name) + ["rationale"])
            if !Set(s.params.keys).isSubset(of: known) { return false }
        }
        func has(_ wanted: [String: String]) -> Bool {
            for (key, want) in wanted {
                if let number = Double(want), let got = step.number(key) {
                    if abs(got - number) > max(0.01, abs(number) * 0.01) { return false }
                } else if step.string(key)?.caseInsensitiveCompare(want) != .orderedSame {
                    return false
                }
            }
            return true
        }
        // An alternative must be met exactly: no other sizing parameter beside it.
        let given = Set(step.params.keys).subtracting(["rationale"])
        return has(test.params) || test.alternatives.contains { has($0) && given == Set($0.keys) }
    }

    public static func run(_ model: any TextModel, cases: [Case] = cases, progress: (@Sendable (Outcome) -> Void)? = nil) async -> Report {
        let context = AgentContext(width: 2400, height: 1600, layerCount: 1, hasSelection: false, activeLayerKind: "pixel", activeLayerName: "Photo")
        var outcomes: [Outcome] = []
        for test in cases {
            let start = Date()
            var passed = false, got: String
            do {
                let (plan, _) = try await AgentPlanner.plan(goal: test.goal, context: context, history: [], model: model)
                passed = judge(plan, test)
                got = plan.steps.isEmpty ? "no tool call" + (plan.message.map { ": \($0.prefix(240))" } ?? "")
                    : plan.steps.map { s in "\(s.op)(" + s.params.filter { $0.key != "rationale" }.map { "\($0.key): \($0.value.display)" }.sorted().joined(separator: ", ") + ")" }.joined(separator: " ")
                if plan.filledFromRequest > 0 { got += " | type filled in from the request" }
                if !PlanCheck.runsAtOnce(plan, request: test.goal), !plan.steps.isEmpty {
                    got += PlanCheck.withoutExtras(plan, request: test.goal).map { " | runs at once without \($0.offered.map(\.op).joined(separator: ", ")), which is offered" } ?? " | waits for Run"
                }
                if !plan.removedFigures.isEmpty { got += " | figures nobody gave it: \(plan.removedFigures.joined(separator: ", "))" }
                if !plan.droppedOps.isEmpty { got += " | made-up tools: \(plan.droppedOps.joined(separator: ", "))" }
            } catch {
                got = "error: " + String(((error as? LocalizedError)?.errorDescription ?? "\(error)").prefix(120))
            }
            let outcome = Outcome(goal: test.goal, language: test.language, seconds: Date().timeIntervalSince(start), passed: passed, got: got, knownGap: test.knownGap)
            outcomes.append(outcome)
            progress?(outcome)
        }
        return Report(model: model.modelID, outcomes: outcomes)
    }
}

private extension JSONValue {
    var display: String {
        switch self {
        case .string(let s): s
        case .number(let n): n == n.rounded() ? String(Int(n)) : String(n)
        case .bool(let b): String(b)
        default: "…"
        }
    }
}
