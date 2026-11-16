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

    static func sort(_ keys: [String]) -> JSONValue {
        .object(["type": .string("object"), "additionalProperties": .bool(false), "properties": .object(Dictionary(uniqueKeysWithValues: keys.map { ($0, JSONValue.object(["type": .string("number")])) }))])
    }
    static let kinds: JSONValue = .object(["type": .string("string"), "enum": .array([.string("denoise"), .string("declick")])])
    static let table: JSONValue = .object(["denoise": sort(["strength"]), "declick": sort(["sensitivity", "width"])])

    /// Settings in an object of their own, the table on that property (Glimmer's own shape).
    @Test func nestedSettingsPerSortAreChecked() {
        func restore(named: Bool) -> SiblingOperation {
            var settings: [String: JSONValue] = ["type": .string("object"), "x-byType": Self.table]
            if named { settings["x-byTypeKey"] = .string("kind") }
            return SiblingOperation(app: .jammer, name: "restore", description: "Restore.", params: .object(["type": .string("object"), "additionalProperties": .bool(false),
                "properties": .object(["kind": Self.kinds, "settings": .object(settings)])]))
        }
        let op = restore(named: true)
        #expect(op.stray(in: ["kind": .string("denoise"), "settings": .object(["strength": .number(0.5)])]) == nil)
        let stray = op.stray(in: ["kind": .string("denoise"), "settings": .object(["sensitivity": .number(0.5)])])
        #expect(stray?.name == "sensitivity in settings" && stray?.allowed == ["strength"])
        #expect(op.uncheckedTable(for: ["kind": .string("denoise"), "settings": .object([:])]) == nil)
        // A sort the table doesn't have is the sibling's to refuse.
        #expect(op.stray(in: ["kind": .string("dehum"), "settings": .object(["x": .number(1)])]) == nil)
        // Without the chooser's name nothing is guessed: not checked, and that is known.
        let unnamed = restore(named: false)
        #expect(unnamed.stray(in: ["kind": .string("denoise"), "settings": .object(["sensitivity": .number(0.5)])]) == nil)
        #expect(unnamed.uncheckedTable(for: ["kind": .string("denoise"), "settings": .object(["sensitivity": .number(0.5)])]) == "settings")
        #expect(unnamed.uncheckedTable(for: ["kind": .string("denoise")]) == nil)   // no settings given: nothing went unchecked
    }

    /// Settings beside the chooser at top level, the table on the operation's own schema (Jämmer's restore).
    @Test func topLevelSettingsPerSortAreChecked() {
        let schema: JSONValue = .object(["type": .string("object"), "additionalProperties": .bool(false), "x-byType": Self.table, "x-byTypeKey": .string("kind"),
            "properties": .object(["kind": Self.kinds, "track": .object(["type": .string("string")]), "strength": .object(["type": .string("number")]),
                                   "sensitivity": .object(["type": .string("number")]), "width": .object(["type": .string("number")])])])
        let op = SiblingOperation(app: .jammer, name: "restore", description: "Restore.", params: schema)
        #expect(op.stray(in: ["kind": .string("denoise"), "track": .string("a"), "strength": .number(0.4)]) == nil)
        // A setting of another sort: refused for this one, with what this sort has. `track` belongs to no sort and is always allowed.
        let stray = op.stray(in: ["kind": .string("denoise"), "track": .string("a"), "width": .number(2)])
        #expect(stray?.name == "width for denoise" && stray?.allowed == ["kind", "strength", "track"])   // what denoise does take
        #expect(op.stray(in: ["kind": .string("declick"), "sensitivity": .number(0.2), "width": .number(2)]) == nil)
        // A name the schema doesn't have at all is the ordinary refusal.
        #expect(op.stray(in: ["kind": .string("denoise"), "amount": .number(1)])?.name == "amount")
    }

    /// Glimmer's own published table names its chooser.
    @Test func glimmersOwnTablesNameTheirChooser() {
        for name in ["add_adjustment", "apply_filter", "add_layer_effect"] {
            let own = AgentAPI.operations.first { $0["name"] as? String == name }
            let params = ((own?["params"] as? [String: Any])?["properties"] as? [String: Any])?["params"] as? [String: Any]
            #expect(params?["x-byTypeKey"] as? String == "type" && params?["x-byType"] != nil, "\(name)")
        }
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

/// The reader against a sibling's real list: GLIMMER_SIBLING_OPS=<a saved /api/v1/operations of Jämmer>.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["GLIMMER_SIBLING_OPS"] != nil))
struct RealSiblingOperations {
    @Test func jammersRestoreIsCheckedBySort() throws {
        let data = try Data(contentsOf: URL(fileURLWithPath: ProcessInfo.processInfo.environment["GLIMMER_SIBLING_OPS"]!))
        let ops = SiblingOperation.parse(data, app: .jammer)
        print("SIBLING \(ops.count) operations read")
        for name in ["restore", "restore_preview"] {
            let op = try #require(ops.first { $0.name == name })
            func verdict(_ params: [String: JSONValue]) -> String { op.stray(in: params).map { "refused: \($0.name); has \($0.allowed)" } ?? "passes" }
            let cases: [(String, [String: JSONValue], Bool)] = [
                ("denoise with amount", ["kind": .string("denoise"), "amount": .number(0.5)], true),
                ("dehum with humFrequency", ["kind": .string("dehum"), "humFrequency": .number(50)], true),
                ("declick with sensitivity", ["kind": .string("declick"), "sensitivity": .number(0.4)], true),
                ("denoise with sensitivity (declick's)", ["kind": .string("denoise"), "sensitivity": .number(0.4)], false),
                ("dehum with sensitivity (declick's)", ["kind": .string("dehum"), "sensitivity": .number(0.4)], false),
                ("declick with humFrequency (dehum's)", ["kind": .string("declick"), "humFrequency": .number(50)], false),
                ("denoise with a name nobody has", ["kind": .string("denoise"), "strength": .number(1)], false),
            ]
            for (what, params, passes) in cases {
                print("SIBLING \(name): \(what): \(verdict(params))")
                #expect((op.stray(in: params) == nil) == passes, "\(name): \(what)")
            }
            #expect(op.uncheckedTable(for: ["kind": .string("denoise")]) == nil)
        }
        // No operation of the list refuses an empty call for a name, and none has a table Glimmer can't read.
        #expect(ops.allSatisfy { $0.stray(in: [:]) == nil && $0.uncheckedTable(for: [:]) == nil })
        // The tools Glimmer would offer a model keep every schema closed.
        #expect(ops.allSatisfy { ((($0.toolSchema["function"] as? [String: Any])?["parameters"] as? [String: Any])?["additionalProperties"] as? Bool) == false })
    }
}

/// A visiting test's copy (`….debug.guest`) is a debug build, and debug builds accept each other's guest copies; a release never does.
@Suite struct GuestCopyTests {
    @Test func guestCopiesAreDebugAndOnlyDebugAcceptsThem() {
        #expect(AppIdentity.isDebug("com.brattoo.glimmer.debug") && AppIdentity.isDebug("com.brattoo.glimmer.debug.guest") && AppIdentity.isDebug("com.brattoo.glimmer.offline.debug"))
        #expect(!AppIdentity.isDebug("com.brattoo.glimmer") && !AppIdentity.isDebug("com.brattoo.glimmer.guest"))
        for app in SiblingApp.allCases {
            let id = "com.brattoo.\(app.rawValue)"
            #expect(app.accepts(bundleID: id + ".debug", debug: true) && app.accepts(bundleID: id + ".debug.guest", debug: true))
            #expect(!app.accepts(bundleID: id, debug: true))                       // debug talks to debug
            #expect(app.accepts(bundleID: id, debug: false))
            #expect(!app.accepts(bundleID: id + ".debug.guest", debug: false) && !app.accepts(bundleID: id + ".debug", debug: false))
            #expect(!app.accepts(bundleID: nil, debug: true))
        }
    }
}

/// Figures a capable model works out from what it was given are not taken for invented ones
/// (the first real model, Berget, 2026-11-16: five cases), and an invented figure beside each still goes.
@Suite struct WorkedFiguresTests {
    static let given = ["Crop the image to 16:9", "2400 1600 1", "Photo"]
    static func check(_ text: String, request: String = "Crop the image to 16:9") -> (text: String?, removed: [String]) {
        var extra = AssistantNumbers.worked(width: 2400, height: 1600, request: request)
        extra.operations = AgentPlanner.operationFigures
        return AssistantNumbers.checked(text, given: [request, "2400 1600 1", "Photo"], steps: 1, extra: extra)
    }

    @Test func theOtherSideOfANamedAspectIsGiven() {
        #expect(Self.check("Cropped to 16:9, which is 2400 × 1350 pixels, centred.").removed.isEmpty)
        // An invented size beside it goes, and it is a number, not a price ("centred" has "cent" in it).
        #expect(Self.check("Cropped to 16:9, which is 2400 × 1350 pixels, centred. The result is 1777 pixels wide.").removed == ["number 1777"])
        #expect(Self.check("Cropped to 2400 × 1280 pixels, centred.").removed == ["number 1280"])
    }

    @Test func halvesAndDoublesAreGiven() {
        let request = "Gör bilden hälften så stor"
        #expect(Self.check("Bilden blir 1200 × 800 pixlar.", request: request).removed.isEmpty)
        #expect(Self.check("Dubbla storleken är 4800 × 3200.", request: request).removed.isEmpty)
        #expect(Self.check("Bilden blir 1200 × 850 pixlar.", request: request).removed == ["number 850"])
    }

    @Test func theSizeAsARatioAndItsMegapixelsAreGiven() {
        let request = "How big is this document, in pixels?"
        #expect(Self.check("It is 2400 × 1600 pixels, a 3:2 image of 3.84 megapixels.", request: request).removed.isEmpty)
        #expect(Self.check("It is about 3.8 megapixels.", request: request).removed.isEmpty)
        // A wrong shape for the person's own document goes: neither the megapixels nor an operation's figures excuse "4:3".
        #expect(Self.check("It is a 4:3 image.", request: request).removed == ["number 4", "number 3"])
        #expect(Self.check("It is a 3:2 image.", request: request).removed.isEmpty)
        #expect(Self.check("It has 4 megapixels.", request: request).removed.isEmpty)       // 3.84, said round
        #expect(Self.check("It is 4 wide.", request: request).removed == ["number 4"])      // not megapixels, not a size
        #expect(Self.check("It is 5.1 megapixels.", request: request).removed == ["number 5.1"])
    }

    @Test func theOperationsOwnFiguresAreGiven() {
        let request = "Hur många lager har dokumentet och vad kostar det att förstora det?"
        // 2× and 4× are in the upscale operation's own description, which the model was sent.
        #expect(Self.check("Dokumentet har 1 lager. Du kan förstora det 2× eller 4×.", request: request).removed.isEmpty)
        #expect(Self.check("Du kan förstora det 7×.", request: request).removed == ["number 7"])
    }

    @Test func aPercentageNamedInTheRequestIsGiven() {
        #expect(Self.check("At 25 % it is 600 × 400.", request: "Scale it to 25 %").removed.isEmpty)
        #expect(Self.check("At 25 % it is 640 × 400.", request: "Scale it to 25 %").removed == ["number 640"])
    }

    /// Held whatever the arithmetic: money, time, sizes on disk, quality, a service.
    @Test func moneyTimeFileSizeQualityAndServicesKeepOnlyWhatWasGiven() {
        let request = "Make it half as large and tell me the cost"
        // 2 is an operation's own figure and 1200 a worked one; neither backs a sentence about money, time or a file's size.
        #expect(Self.check("That costs 2 credits.", request: request).removed == ["price 2"])
        #expect(Self.check("It will take 4 seconds.", request: request).removed == ["number 4"])
        #expect(Self.check("The file will be about 1200 kB.", request: request).removed == ["number 1200"])
        #expect(Self.check("Berget charges 2 per request.", request: request).removed == ["number 2"])
        #expect(Self.check("Quality 4 is best.", request: request).removed == ["number 4"])
        // The same figures in a sentence about the picture stay.
        #expect(Self.check("It becomes 1200 × 800 pixels.", request: request).removed.isEmpty)
        // A price is called a price only with a currency or the word.
        #expect(Self.check("The centre is at 999.", request: request).removed == ["number 999"])
        #expect(Self.check("It is €3.", request: request).removed == ["price 3"])
    }

    /// An operation's own figures count where the sentence names the operation or its subject, and nowhere else.
    @Test func anOperationsFiguresCountOnlyWhereItIsNamed() {
        let request = "Make it better"
        #expect(Self.check("I can upscale it 2× or 4×.", request: request).removed.isEmpty)
        #expect(Self.check("Du kan förstora det 4×.", request: request).removed.isEmpty)
        #expect(Self.check("An exposure of +3 would brighten it.", request: request).removed.isEmpty)        // within the exposure adjustment's own range
        #expect(Self.check("The crop moves it by +3.", request: request).removed == ["number 3"])           // crop has no such figure
        #expect(Self.check("There are 4 of them.", request: request).removed == ["number 4"])               // names nothing
        // Free as before: 0, 1 and the count of the plan's steps, as in "1 step" or a numbered list.
        #expect(Self.check("1. Crop it. Then 1 more thing.", request: request).removed.isEmpty)
        #expect(AssistantNumbers.checked("Step 1: crop. Step 2: blur. That is 2 steps.", given: [request], steps: 2).removed.isEmpty)
        #expect(AssistantNumbers.checked("Step 3 comes later.", given: [request], steps: 2).removed == ["number 3"])
    }

    @Test func theSetIsClosed() {
        let worked = AssistantNumbers.worked(width: 2400, height: 1600, request: "Crop to 16:9 and to a square")
        #expect(Set(worked.sizes).isSuperset(of: [1200, 800, 4800, 3200, 9600, 6400, 1350, 1600]))
        #expect(worked.megapixels == [4, 3.8, 3.84] && worked.ratio?.0 == 3 && worked.ratio?.1 == 2)
        #expect(!worked.sizes.contains(1777) && !worked.sizes.contains(1280) && worked.sizes.count < 20)
        #expect(AssistantNumbers.worked(width: 0, height: 0, request: "x").sizes.isEmpty)
    }
}

/// A figure the request gives in words backs the same figure in digits in the answer.
@Suite struct FiguresInWordsTests {
    @Test func wordsAreReadInEnglishAndSwedish() {
        #expect(AssistantNumbers.numbersInWords(in: "one and a half seconds") == [1.5])
        #expect(AssistantNumbers.numbersInWords(in: "minus arton") == [18])
        #expect(AssistantNumbers.numbersInWords(in: "twenty-five percent, then two hundred and fifty") == [25, 250])
        #expect(AssistantNumbers.numbersInWords(in: "tjugofem procent och tvåhundra pixlar") == [25, 200])
        #expect(AssistantNumbers.numbersInWords(in: "en och en halv gång, tre tusen") == [1.5, 3000])
        #expect(AssistantNumbers.numbersInWords(in: "half as large, a quarter, double it") == [0.5, 0.25, 2])
        #expect(AssistantNumbers.numbersInWords(in: "Remove the background") == [])
    }

    @Test func aFigureGivenInWordsBacksTheDigits() {
        func check(_ text: String, request: String) -> [String] { AssistantNumbers.checked(text, given: [request, "2400 1600 1"], steps: 1).removed }
        #expect(check("Blurred with a radius of 18.", request: "Blur it by eighteen") == [])
        #expect(check("Oskärpa med radie 18.", request: "Gör den suddig, radie arton") == [])
        #expect(check("Rotated 1.5 degrees.", request: "Rotate it one and a half degrees") == [])
        #expect(check("Scaled to 25 %.", request: "Scale it to a quarter") == [])        // a share may be said as a percentage
        // A figure nobody gave still goes, in words or not.
        #expect(check("Blurred with a radius of 19.", request: "Blur it by eighteen") == ["number 19"])
        #expect(check("Rotated 2.5 degrees.", request: "Rotate it one and a half degrees") == ["number 2.5"])
    }
}

/// A sentence saying something was done must not stand when it was not.
@Suite struct PlanClaimsTests {
    static func step(_ op: String, _ params: [String: JSONValue] = [:]) -> AgentStep { AgentStep(op: op, params: params) }

    @Test func aSentenceStandsOnlyAboveTheStepsItNames() {
        let crop = Self.step("crop", ["aspect": .string("16:9")])
        #expect(PlanClaims.shown("Cropped to 16:9.", steps: [crop], madeUpSteps: false) == "Cropped to 16:9.")
        #expect(PlanClaims.shown("Beskär bilden till 16:9.", steps: [crop], madeUpSteps: false) != nil)
        // It names something no step does.
        #expect(PlanClaims.shown("Cropped to 16:9 and removed the background.", steps: [crop], madeUpSteps: false) == nil)
        #expect(PlanClaims.shown("Beskuren, och bakgrunden är borttagen.", steps: [crop], madeUpSteps: false) == nil)
        #expect(PlanClaims.shown("Cropped and sharpened.", steps: [crop], madeUpSteps: false) == nil)
        // With both steps it stands.
        let sharpen = Self.step("apply_filter", ["type": .string("sharpen")])
        #expect(PlanClaims.shown("Cropped and sharpened.", steps: [crop, sharpen], madeUpSteps: false) != nil)
        // A kind of adjustment other than the one planned.
        let bw = Self.step("add_adjustment", ["type": .string("black_white")])
        #expect(PlanClaims.shown("Made it black and white.", steps: [bw], madeUpSteps: false) != nil)
        #expect(PlanClaims.shown("Made it black and white with a vignette.", steps: [bw], madeUpSteps: false) == nil)
        // Words too common to mean an operation don't take a sentence down.
        #expect(PlanClaims.shown("The background is removed; the layer keeps its size.", steps: [Self.step("remove_background")], madeUpSteps: false) != nil)
    }

    @Test func aSentenceThatSaysItIsFinishedDoesNotStandAboveSteps() {
        let crop = Self.step("crop", ["aspect": .string("16:9")])
        for said in ["All done!", "Done. Cropped to 16:9.", "I have cropped it to 16:9.", "I've cropped it.", "Klart!", "Jag har beskurit bilden.", "Beskärningen är färdig.", "Finished cropping."] {
            #expect(PlanClaims.shown(said, steps: [crop], madeUpSteps: false) == nil, "\(said)")
        }
        // Not completion words inside other words, and a plain statement of the plan stands.
        for said in ["Cropping to 16:9.", "Beskär till 16:9, klarare blir det inte.", "Abandoned edges are cropped away."] {
            #expect(PlanClaims.shown(said, steps: [crop], madeUpSteps: false) == said, "\(said)")
        }
    }

    @Test func nothingStandsAboveNoStepsOrMadeUpSteps() {
        #expect(PlanClaims.shown("VCA Voices removed.", steps: [], madeUpSteps: false) == nil)
        #expect(PlanClaims.shown("Cropped to 16:9.", steps: [Self.step("crop")], madeUpSteps: true) == nil)
        #expect(PlanClaims.shown(nil, steps: [Self.step("crop")], madeUpSteps: false) == nil)
    }
}
