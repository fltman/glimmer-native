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

/// What is published is what is enforced (SIBLINGS.md §3): closed schemas, the nested settings per type, `rationale` everywhere.
@Suite struct PublishedSchemaTests {
    @Test func everyPublishedSchemaIsClosedAndCarriesRationale() throws {
        let ops = AgentAPI.operations
        #expect(ops.count >= 35)
        for op in ops {
            let name = op["name"] as? String ?? "?"
            let params = try #require(op["params"] as? [String: Any], "\(name) has no schema")
            #expect(params["additionalProperties"] as? Bool == false, "\(name)'s schema is open")
            let properties = try #require(params["properties"] as? [String: Any])
            #expect(properties["rationale"] != nil, "\(name) does not publish rationale")
            // What the schema lists is exactly what the check accepts.
            if op["call"] == nil, let registered = AgentPlanner.op(named: name) {
                #expect(Set(properties.keys) == Set(registered.params.map(\.name) + ["rationale"]), "\(name): schema and register differ")
            }
        }
    }

    @Test func theNestedSettingsArePublishedPerTypeAndClosed() throws {
        for (name, types) in [("add_adjustment", AdjustmentKind.allCases.map(\.rawValue)), ("apply_filter", FilterKind.allCases.map(\.rawValue)),
                              ("add_layer_effect", ["dropShadow", "innerShadow", "outerGlow", "stroke", "colorOverlay"])] {
            let op = try #require(AgentAPI.operations.first { $0["name"] as? String == name })
            let nested = try #require(((op["params"] as? [String: Any])?["properties"] as? [String: Any])?["params"] as? [String: Any])
            let byType = try #require(nested["x-byType"] as? [String: [String: Any]], "\(name)'s params is a bare object")
            #expect(Set(byType.keys) == Set(types))
            for type in types {
                let schema = try #require(byType[type])
                #expect(schema["additionalProperties"] as? Bool == false)
                // The published names are the enforced names.
                #expect(Set((schema["properties"] as? [String: Any] ?? [:]).keys) == Set(StepParameters.nestedKeys(op: name, type: type) ?? ["?"]), "\(name) \(type)")
            }
        }
        // A slider's range and default are there to check against.
        let exposure = StepParameters.nestedSchemas(op: "add_adjustment")?["exposure"]?["properties"] as? [String: [String: Any]]
        #expect(exposure?["exposure"]?["minimum"] != nil && exposure?["exposure"]?["maximum"] != nil)
        // A model's tool list has the closed top level but not the per-type tables.
        let tool = try #require(AgentPlanner.toolSchemas().first { ($0["function"] as? [String: Any])?["name"] as? String == "add_adjustment" })
        let parameters = try #require((tool["function"] as? [String: Any])?["parameters"] as? [String: Any])
        #expect(parameters["additionalProperties"] as? Bool == false)
        #expect(((parameters["properties"] as? [String: Any])?["params"] as? [String: Any])?["x-byType"] == nil)
    }

    @Test func rationaleIsAcceptedOnEveryEndpoint() {
        #expect(StepParameters.strayMessage(["fit", "rationale"], allowed: ["fit"], what: "x") == nil)
        #expect(StepParameters.strayMessage(["rationale"], allowed: [], what: "x") == nil)
    }

    /// The sizes, for the record (the full list goes to cloud models and to siblings).
    @Test func sizes() throws {
        func bytes(_ v: Any) throws -> Int { try JSONSerialization.data(withJSONObject: v, options: [.sortedKeys]).count }
        print("SCHEMA sizes: /operations \(try bytes(AgentAPI.operations)) bytes; a model's full tool list \(try bytes(AgentPlanner.toolSchemas())) bytes; the short list \(try bytes(AgentPlanner.toolSchemas(short: true))) bytes; the per-type tables alone \(try bytes(["a": StepParameters.nestedSchemas(op: "add_adjustment")!, "f": StepParameters.nestedSchemas(op: "apply_filter")!, "e": StepParameters.nestedSchemas(op: "add_layer_effect")!])) bytes")
    }
}

/// What Glimmer sends to a sibling: a name the sibling's closed schema doesn't have is stopped here.
@Suite struct SiblingStrayParameterTests {
    static func op(closed: Bool) -> SiblingOperation {
        var schema: [String: JSONValue] = ["type": .string("object"), "properties": .object(["seconds": .object(["type": .string("number")]), "rationale": .object(["type": .string("string")])])]
        if closed { schema["additionalProperties"] = .bool(false) }
        return SiblingOperation(app: .flimmer, name: "trim_clip", description: "Trim.", params: .object(schema))
    }

    @Test func aClosedSiblingSchemaIsCheckedBeforeAnythingIsSent() {
        let closed = Self.op(closed: true)
        #expect(closed.stray(in: ["seconds": .number(2)]) == nil)
        let stray = closed.stray(in: ["seconds": .number(2), "fade": .bool(true)])
        #expect(stray?.name == "fade" && stray?.allowed == ["seconds"])
        // An older sibling with an open schema decides for itself.
        #expect(Self.op(closed: false).stray(in: ["fade": .bool(true)]) == nil)
        #expect(SiblingError.strayParameter("flimmer_trim_clip", "fade", ["seconds"]).errorDescription == "flimmer_trim_clip has no parameter named fade. It has: seconds.")
    }

    /// A sibling's settings per sort (Jämmer publishes its restore settings this way, on `kind`).
    @Test func aSiblingsSettingsPerSortAreChecked() {
        func sort(_ keys: [String]) -> JSONValue {
            .object(["type": .string("object"), "additionalProperties": .bool(false), "properties": .object(Dictionary(uniqueKeysWithValues: keys.map { ($0, JSONValue.object(["type": .string("number")])) }))])
        }
        let settings: JSONValue = .object(["type": .string("object"), "x-byType": .object(["denoise": sort(["strength"]), "declick": sort(["sensitivity", "width"])])])
        let schema: JSONValue = .object(["type": .string("object"), "additionalProperties": .bool(false), "properties": .object([
            "kind": .object(["type": .string("string"), "enum": .array([.string("denoise"), .string("declick")])]), "settings": settings])])
        let restore = SiblingOperation(app: .jammer, name: "restore", description: "Restore.", params: schema)
        #expect(restore.stray(in: ["kind": .string("denoise"), "settings": .object(["strength": .number(0.5)])]) == nil)
        // A setting of another sort is refused for this one, by name, with what this sort has.
        let stray = restore.stray(in: ["kind": .string("denoise"), "settings": .object(["sensitivity": .number(0.5)])])
        #expect(stray?.name == "sensitivity in settings" && stray?.allowed == ["strength"])
        #expect(restore.stray(in: ["kind": .string("declick"), "settings": .object(["sensitivity": .number(0.5), "width": .number(2)])]) == nil)
        // A sort the table doesn't have is the sibling's to refuse.
        #expect(restore.stray(in: ["kind": .string("dehum"), "settings": .object(["x": .number(1)])]) == nil)
        // Glimmer's own published table names its chooser, and is read the same way.
        let own = AgentAPI.operations.first { $0["name"] as? String == "add_adjustment" }
        let params = ((own?["params"] as? [String: Any])?["properties"] as? [String: Any])?["params"] as? [String: Any]
        #expect(params?["x-byTypeKey"] as? String == "type")
    }

    /// A plan with a sibling step that carries an unknown name is known to be refused when it is made.
    @Test func aPlanIsNotRunAtOnceWhenItSaysAStepWillBeRefused() {
        var plan = AgentPlan(steps: [AgentStep(op: "add_adjustment", params: ["type": .string("black_white")])])
        #expect(PlanCheck.runsAtOnce(plan, request: "Make it black and white"))
        plan.strayParameters = ["flimmer_trim_clip has no parameter named fade. It has: seconds."]
        #expect(!PlanCheck.runsAtOnce(plan, request: "Make it black and white"))
    }

    /// The tool Glimmer offers a model keeps the sibling's closed schema, with Glimmer's two additions inside it.
    @Test func theToolKeepsTheSiblingsSchemaClosed() throws {
        let tool = Self.op(closed: true).toolSchema
        let parameters = try #require((tool["function"] as? [String: Any])?["parameters"] as? [String: Any])
        #expect(parameters["additionalProperties"] as? Bool == false)
        let properties = try #require(parameters["properties"] as? [String: Any])
        #expect(properties["document"] != nil && properties["rationale"] != nil && properties["seconds"] != nil)
    }
}
