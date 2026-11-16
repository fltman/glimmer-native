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
    }

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
        Case(goal: "Gör bilden hälften så stor", language: "sv", op: "resize_image", params: ["scale": "0.5"]),
        Case(goal: "Make the layer half transparent", language: "en", op: "set_layer", params: ["opacity": "0.5"]),
        Case(goal: "Markera motivet", language: "sv", op: "select_subject", params: [:]),
    ]

    public struct Outcome: Sendable {
        public let goal: String
        public let language: String
        public let seconds: Double
        public let passed: Bool
        /// What the model did, for the report.
        public let got: String
    }

    public struct Report: Sendable {
        public let model: String
        public let outcomes: [Outcome]
        public var passed: Int { outcomes.filter(\.passed).count }
        public func passed(language: String) -> (Int, Int) {
            let some = outcomes.filter { $0.language == language }
            return (some.filter(\.passed).count, some.count)
        }
        public var slowest: Double { outcomes.map(\.seconds).max() ?? 0 }
        public var median: Double { let s = outcomes.map(\.seconds).sorted(); return s.isEmpty ? 0 : s[s.count / 2] }

        /// At least 10 of 12 right, at least 5 of 6 in each language, and none slower than a minute.
        public var passes: Bool {
            let en = passed(language: "en"), sv = passed(language: "sv")
            return passed * 6 >= outcomes.count * 5 && en.0 * 6 >= en.1 * 5 && sv.0 * 6 >= sv.1 * 5 && slowest <= LocalModelEvaluation.slowestAllowed
        }
    }

    public static let slowestAllowed = 60.0

    /// Whether `plan` answers `test`: the right operation with the right values, and nothing made up.
    public static func judge(_ plan: AgentPlan, _ test: Case) -> Bool {
        guard plan.droppedOps.isEmpty, let step = plan.steps.first(where: { $0.op == test.op }) else { return false }
        // Every step must be a real operation with only parameters that operation has.
        for s in plan.steps {
            guard let op = AgentPlanner.op(named: s.op) else { return false }
            let known = Set(op.params.map(\.name) + ["rationale"])
            if !Set(s.params.keys).isSubset(of: known) { return false }
        }
        for (key, want) in test.params {
            if let number = Double(want), let got = step.number(key) {
                if abs(got - number) > max(0.01, abs(number) * 0.01) { return false }
            } else if step.string(key)?.caseInsensitiveCompare(want) != .orderedSame {
                return false
            }
        }
        return true
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
                got = plan.steps.isEmpty ? "no tool call" + (plan.message.map { ": \($0.prefix(60))" } ?? "")
                    : plan.steps.map { s in "\(s.op)(" + s.params.filter { $0.key != "rationale" }.map { "\($0.key): \($0.value.display)" }.sorted().joined(separator: ", ") + ")" }.joined(separator: " ")
                if !plan.droppedOps.isEmpty { got += " | made-up tools: \(plan.droppedOps.joined(separator: ", "))" }
            } catch {
                got = "error: " + String(((error as? LocalizedError)?.errorDescription ?? "\(error)").prefix(120))
            }
            let outcome = Outcome(goal: test.goal, language: test.language, seconds: Date().timeIntervalSince(start), passed: passed, got: got)
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
