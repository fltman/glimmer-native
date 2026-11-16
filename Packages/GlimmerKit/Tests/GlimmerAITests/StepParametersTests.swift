import Foundation
import Testing
@testable import GlimmerAI
import GlimmerCore

/// A parameter an operation doesn't have is refused by name, for every operation in the
/// register: the walk, so that an operation added later can't forget it.
@Suite struct StepParametersTests {
    @Test func everyOperationRefusesAParameterItDoesNotHave() {
        #expect(AgentPlanner.ops.count >= 30)
        for op in AgentPlanner.ops {
            // Its own parameters, whatever their values: nothing stray.
            var all: [String: JSONValue] = [:]
            for p in op.params where p.name != "params" { all[p.name] = .string("x") }
            #expect(StepParameters.stray(in: AgentStep(op: op.name, params: all)) == nil, "\(op.name) refuses one of its own parameters")
            // One more, under a name it doesn't have.
            all["zzNotAParameter"] = .number(1)
            let stray = StepParameters.stray(in: AgentStep(op: op.name, params: all))
            #expect(stray?.name == "zzNotAParameter" && stray?.inside == nil && stray?.allowed == op.params.map(\.name), "\(op.name) lets an unknown parameter through")
            #expect(stray?.message.hasPrefix("\(op.name) has no parameter named zzNotAParameter. ") == true)
        }
        // The model's own "rationale" is not a parameter of any operation and is always allowed.
        #expect(StepParameters.stray(in: AgentStep(op: "auto_enhance", params: ["rationale": .string("why")])) == nil)
        #expect(StepParameters.stray(in: AgentStep(op: "auto_enhance", params: ["strength": .number(1)]))?.message == "auto_enhance has no parameter named strength. It takes none.")
        // An operation Glimmer doesn't have (a sibling's tool) is not this check's to refuse.
        #expect(StepParameters.stray(in: AgentStep(op: "flimmer_add_clip", params: ["anything": .number(1)])) == nil)
    }

    @Test func theNestedSettingsAreCheckedAgainstTheirKind() {
        var checked = 0
        func walk(_ op: String, _ types: [String]) {
            for type in types {
                guard let keys = StepParameters.nestedKeys(op: op, type: type) else { Issue.record("\(op) \(type) has no list of settings"); continue }
                var nested: [String: JSONValue] = [:]
                for key in keys { nested[key] = .number(0) }
                #expect(StepParameters.stray(in: AgentStep(op: op, params: ["type": .string(type), "params": .object(nested)])) == nil, "\(op) \(type) refuses one of its own settings")
                nested["zzNotASetting"] = .number(1)
                let stray = StepParameters.stray(in: AgentStep(op: op, params: ["type": .string(type), "params": .object(nested)]))
                #expect(stray?.name == "zzNotASetting" && stray?.inside == "params", "\(op) \(type) lets an unknown setting through")
                checked += 1
            }
        }
        walk("add_adjustment", AdjustmentKind.allCases.map(\.rawValue))
        walk("apply_filter", FilterKind.allCases.map(\.rawValue))
        walk("add_layer_effect", ["dropShadow", "innerShadow", "outerGlow", "stroke", "colorOverlay"])
        #expect(checked > 30)
        // What the guide documents for each kind is what is accepted: the same lists.
        #expect(StepParameters.nestedKeys(op: "add_adjustment", type: "brightness_contrast") == ["brightness", "contrast"])
        #expect(StepParameters.nestedKeys(op: "add_layer_effect", type: "dropShadow")?.contains("enabled") == true)
        #expect(StepParameters.stray(in: AgentStep(op: "add_adjustment", params: ["type": .string("exposure"), "params": .object(["brightness": .number(0.2)])]))?.message
                == "add_adjustment has no parameter named brightness in params. It has: \(StepParameters.nestedKeys(op: "add_adjustment", type: "exposure")!.joined(separator: ", ")).")
        // A type that doesn't exist is refused elsewhere, with its own message.
        #expect(StepParameters.stray(in: AgentStep(op: "add_adjustment", params: ["type": .string("nope"), "params": .object(["x": .number(1)])])) == nil)
    }

    @Test func aPlanWithAStrayParameterIsShownNotRun() {
        let named = AgentPlan(steps: [AgentStep(op: "add_adjustment", params: ["type": .string("black_white")])])
        #expect(PlanCheck.runsAtOnce(named, request: "Make it black and white"))
        let stray = AgentPlan(steps: [AgentStep(op: "add_adjustment", params: ["type": .string("black_white"), "strength": .number(2)])])
        #expect(!PlanCheck.runsAtOnce(stray, request: "Make it black and white"))
    }

    @Test func endpointsHaveTheirParametersAndNoOthers() {
        #expect(StepParameters.queryParameters(path: ["documents"], method: "POST") == ["name"])
        #expect(StepParameters.queryParameters(path: ["documents"], method: "GET").isEmpty)
        #expect(StepParameters.queryParameters(path: ["documents", "abc", "image"], method: "GET") == ["format", "maxSide"])
        #expect(StepParameters.queryParameters(path: ["documents", "abc", "layers"], method: "POST") == ["fit", "x", "y", "smartObject", "name"])
        #expect(StepParameters.queryParameters(path: ["documents", "abc", "steps"], method: "POST").isEmpty)
        #expect(StepParameters.strayMessage(["fit", "scale"], allowed: ["fit", "x"], what: "POST /x") == "POST /x has no parameter named scale. It has: fit, x.")
        #expect(StepParameters.strayMessage(["fit"], allowed: ["fit", "x"], what: "POST /x") == nil)
        #expect(StepParameters.strayMessage(["a"], allowed: [], what: "Undo") == "Undo has no parameter named a. It takes none.")
    }
}
