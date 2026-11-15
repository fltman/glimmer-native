import Foundation
@testable import GlimmerAI
import GlimmerCore
import Testing

/// A made-up Jämmer behind a URLProtocol: no sockets, no real app. Flimmer isn't running.
final class FakeJammer: URLProtocol, @unchecked Sendable {
    struct Seen: Sendable { var method: String; var url: URL; var headers: [String: String]; var body: Data? }
    nonisolated(unsafe) static var seen: [Seen] = []
    nonisolated(unsafe) static var running = true
    nonisolated(unsafe) static var statusBundleID: String?
    static let lock = NSLock()

    static func reset(running: Bool = true, bundleID: String? = nil) {
        lock.withLock { seen = []; self.running = running; statusBundleID = bundleID }
    }
    static var requests: [Seen] { lock.withLock { seen } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let url = request.url!
        var body = request.httpBody
        if body == nil, let stream = request.httpBodyStream {
            stream.open(); var data = Data(); var buf = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable { let n = stream.read(&buf, maxLength: 4096); if n <= 0 { break }; data.append(buf, count: n) }
            stream.close(); body = data
        }
        let isRunning = Self.lock.withLock {
            Self.seen.append(Seen(method: request.httpMethod ?? "GET", url: url, headers: request.allHTTPHeaderFields ?? [:], body: body))
            return Self.running
        }
        guard isRunning, url.port == 9003 else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost)); return
        }
        let (status, json) = Self.answer(request.httpMethod ?? "GET", url)
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: try! JSONSerialization.data(withJSONObject: json))
        client?.urlProtocolDidFinishLoading(self)
    }

    static func answer(_ method: String, _ url: URL) -> (Int, Any) {
        switch (method, url.path) {
        case ("GET", "/api/v1/status"):
            var app: [String: Any] = ["name": "Jammer", "version": "0.1.0"]
            if let id = lock.withLock({ statusBundleID }) { app["bundleID"] = id }
            return (200, ["app": app])
        case ("GET", "/api/v1/operations"):
            let start: [String: Any] = ["type": "number", "x-in": "query"]
            let id: [String: Any] = ["type": "string", "x-in": "path"]
            return (200, ["operations": [
                ["name": "gain", "description": "Change the level.", "paid": false, "undoable": true, "startsJob": false,
                 "params": ["type": "object", "properties": ["db": ["type": "number"]], "required": ["db"]]],
                ["name": "echo", "description": "Add an echo.", "paid": false, "undoable": true, "startsJob": false,
                 "params": ["type": "object", "properties": ["delay": ["type": "number"]], "required": [String]()]],
                ["name": "analysis", "description": "Measure loudness.", "paid": false, "undoable": false, "startsJob": false,
                 "params": ["type": "object", "properties": ["id": id, "start": start], "required": ["id"]],
                 "call": ["method": "GET", "path": "/api/v1/documents/{id}/analysis"]],
                ["name": "restore", "description": "Clean up the sound.", "paid": false, "undoable": true, "startsJob": true,
                 "params": ["type": "object", "properties": ["id": id, "strength": ["type": "number"]], "required": ["id"]],
                 "call": ["method": "POST", "path": "/api/v1/documents/{id}/restore"]],
                ["name": "studio_voice", "description": "Cloud voice.", "paid": true, "undoable": true, "startsJob": true,
                 "params": ["type": "object", "properties": [:], "required": [String]()]],
                ["name": "bad name!", "description": "Malformed."],
            ]])
        case ("GET", "/api/v1/documents"):
            return (200, ["documents": [["id": "D2", "name": "Intro", "duration": 3.0], ["id": "D1", "name": "Episode 7", "duration": 42.5, "frontmost": true]]])
        case ("POST", "/api/v1/documents/D1/steps"), ("POST", "/api/v1/documents/D2/steps"):
            return (200, ["results": [["index": 0, "status": "done"]]])
        case ("GET", "/api/v1/documents/D1/analysis"): return (200, ["analysis": ["lufs": -16]])
        case ("POST", "/api/v1/documents/D1/restore"): return (202, ["job": ["id": "J1", "status": "running"]])
        case ("GET", "/api/v1/jobs/J1"): return (200, ["job": ["id": "J1", "status": "done", "result": ["ok": true]]])
        case ("GET", "/api/v1/documents/D1/waveform"):
            let width = Int(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "width" }?.value ?? "4") ?? 4
            let left = (0..<width).map { i in [-0.1 * Double(i % 5), 0.1 * Double(i % 5)] }
            let right = (0..<width).map { _ in [-0.05, 0.05] }
            return (200, ["waveform": ["width": width, "tracks": [["name": "Voice", "channels": [left, right]]]]])
        default: return (404, ["error": ["code": "not_found", "message": "No such path: \(url.path)."]])
        }
    }

    static func client() -> SiblingClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FakeJammer.self]
        return SiblingClient(session: URLSession(configuration: config))
    }
}

@Suite(.serialized) struct SiblingClientTests {
    @Test func findsJammerAndNotFlimmer() async {
        FakeJammer.reset()
        let client = FakeJammer.client()
        #expect(await client.running() == [.jammer])
        #expect(await client.port(.jammer) == 9003)
        #expect(await client.port(.flimmer) == nil)
        // Every request looks like an outside agent's, with X-Sibling and no Origin.
        for r in FakeJammer.requests {
            #expect(r.headers["X-Sibling"] == "glimmer")
            #expect(r.headers["Origin"] == nil)
        }
    }

    @Test func aSiblingOfTheOtherBuildIsNotUsed() async {
        // These tests run as a release-style host, so a debug Jämmer on the port doesn't count.
        FakeJammer.reset(bundleID: "com.brattoo.jammer.debug")
        #expect(await FakeJammer.client().port(.jammer) == nil)
        FakeJammer.reset(bundleID: "com.brattoo.jammer")
        #expect(await FakeJammer.client().port(.jammer) == 9003)
    }

    @Test func operationsBecomeToolsNamedAfterTheApp() async throws {
        FakeJammer.reset()
        let client = FakeJammer.client()
        let ops = try await client.operations(.jammer)
        #expect(ops.map(\.name) == ["gain", "echo", "analysis", "restore", "studio_voice"])
        let (tools, context) = await client.toolbox()
        #expect(tools.map(\.toolName) == ["jammer_gain", "jammer_echo", "jammer_analysis", "jammer_restore"], "paid ops are left out")
        #expect(context?.contains("Jämmer") == true && context?.contains("“Episode 7” (id D1, 42.5 s)") == true)
        for tool in tools {
            #expect(tool.toolName.range(of: "^[a-zA-Z0-9_-]{1,64}$", options: .regularExpression) != nil)
            let schema = try #require(tool.toolSchema["function"] as? [String: Any])
            let params = try #require(schema["parameters"] as? [String: Any])
            let props = try #require(params["properties"] as? [String: Any])
            #expect(props.values.allSatisfy { ($0 as? [String: Any])?["x-in"] == nil }, "x-in stays out of the tool schema")
            #expect((props["document"] != nil) == (props["id"] == nil))
            #expect((schema["description"] as? String)?.hasPrefix("In Jämmer") == true)
        }
    }

    @Test func stepsGoThroughStepsWithTheAgentHeader() async throws {
        FakeJammer.reset()
        let client = FakeJammer.client()
        _ = try await client.perform(tool: "jammer_echo", params: ["delay": .number(0.3), "rationale": .string("Space."), "document": .string("Intro")])
        let post = try #require(FakeJammer.requests.last { $0.method == "POST" })
        #expect(post.url.path == "/api/v1/documents/D2/steps")
        #expect(post.headers["X-Jammer-Agent"] == "1" && post.headers["X-Sibling"] == "glimmer")
        let body = try #require(try JSONSerialization.jsonObject(with: post.body ?? Data()) as? [String: Any])
        let step = try #require((body["steps"] as? [[String: Any]])?.first)
        #expect(step["op"] as? String == "echo" && (step["params"] as? [String: Any])?["delay"] as? Double == 0.3)
        #expect((step["params"] as? [String: Any])?["rationale"] == nil && body["allowPaid"] as? Bool == false)
    }

    @Test func callsPlaceParamsByXIn() async throws {
        FakeJammer.reset()
        let client = FakeJammer.client()
        let result = try await client.perform(tool: "jammer_analysis", params: ["start": .number(1)])
        #expect(result.object?["analysis"]?.object?["lufs"]?.number == -16)
        let get = try #require(FakeJammer.requests.last { $0.url.path.hasSuffix("/analysis") })
        #expect(get.url.path == "/api/v1/documents/D1/analysis" && get.url.query == "start=1")
    }

    @Test func jobsAreFollowedToTheEnd() async throws {
        FakeJammer.reset()
        let client = FakeJammer.client()
        let result = try await client.perform(tool: "jammer_restore", params: ["strength": .number(0.5)])
        #expect(result.object?["ok"]?.bool == true)
        let post = try #require(FakeJammer.requests.last { $0.method == "POST" })
        let body = try #require(try JSONSerialization.jsonObject(with: post.body ?? Data()) as? [String: Any])
        #expect(body["strength"] as? Double == 0.5)
    }

    @Test func refusalsAndErrors() async throws {
        FakeJammer.reset()
        let client = FakeJammer.client()
        await #expect(throws: SiblingError.paid("jammer_studio_voice")) { try await client.perform(tool: "jammer_studio_voice", params: [:]) }
        await #expect(throws: SiblingError.unknownOperation("jammer_teleport")) { try await client.perform(tool: "jammer_teleport", params: [:]) }
        await #expect(throws: SiblingError.noDocument(.jammer, "Outro")) { try await client.perform(tool: "jammer_gain", params: ["db": .number(3), "document": .string("Outro")]) }
        await #expect(throws: SiblingError.notRunning(.flimmer)) { try await client.perform(tool: "flimmer_cut", params: [:]) }
    }

    @Test func notRunningAfterTheAppQuits() async throws {
        FakeJammer.reset()
        let client = FakeJammer.client()
        _ = try await client.operations(.jammer)
        FakeJammer.reset(running: false)
        await #expect(throws: SiblingError.notRunning(.jammer)) { try await client.perform(tool: "jammer_gain", params: ["db": .number(3)]) }
    }

    @Test func waveformFromJammer() async throws {
        FakeJammer.reset()
        let client = FakeJammer.client()
        let wave = try await client.waveform(.jammer, document: nil, columns: 10)
        #expect(wave.documentName == "Episode 7" && wave.amplitudes.count == 10)
        // The louder channel wins per column.
        #expect(wave.amplitudes[0] == 0.05 && abs(wave.amplitudes[4] - 0.4) < 1e-9)
        #expect(FakeJammer.requests.last?.url.query == "width=10")
    }
}

@Suite struct SiblingPlanningTests {
    @Test func debugBuildsPairWithDebugBuilds() {
        #expect(SiblingApp.jammer.bundleID(debug: true) == "com.brattoo.jammer.debug")
        #expect(SiblingApp.flimmer.bundleID(debug: false) == "com.brattoo.flimmer")
        #expect(!AppIdentity.isDebugBuild, "the test host isn't a debug Glimmer")
    }

    @Test func theBestInstalledCopyIsChosen() {
        let old = Date(timeIntervalSince1970: 1_000), new = Date(timeIntervalSince1970: 2_000)
        // The highest build wins, even over /Applications: a stale copy broke a cold start.
        #expect(SiblingApp.bestCopy([("/Users/x/actions-runner/Debug/Jammer.app", "2", new), ("/Users/x/build/Jammer.app", "7", old)]) == 1)
        #expect(SiblingApp.bestCopy([("/Users/x/build/Jammer.app", "9", old), ("/Applications/Jammer.app", "3", new)]) == 0)
        // Builds compare as numbers, missing parts as 0.
        #expect(SiblingApp.bestCopy([("/a/Jammer.app", "1.10", old), ("/b/Jammer.app", "1.9", new)]) == 0)
        #expect(SiblingApp.bestCopy([("/a/Jammer.app", "10", old), ("/b/Jammer.app", "9.9", new)]) == 0)
        // Same build: /Applications, then the most recently built.
        #expect(SiblingApp.bestCopy([("/Users/x/Jammer.app", "5", new), ("/Applications/Jammer.app", "5", old)]) == 1)
        #expect(SiblingApp.bestCopy([("/a/Jammer.app", "5", old), ("/b/Jammer.app", "5.0", new)]) == 1)
        #expect(SiblingApp.bestCopy([]) == nil)
    }

    @Test func toolNamesSplit() {
        #expect(SiblingApp.split(tool: "jammer_gain")! == (.jammer, "gain"))
        #expect(SiblingApp.split(tool: "flimmer_add_title")! == (.flimmer, "add_title"))
        #expect(SiblingApp.split(tool: "jammer_") == nil && SiblingApp.split(tool: "add_waveform") == nil)
    }

    @Test func plannerAcceptsOfferedSiblingTools() throws {
        let response = OpenRouterClient.ToolResponse(text: "Louder, then the waveform.", toolCalls: [
            .init(name: "jammer_gain", arguments: #"{"db": 3, "rationale": "Louder."}"#),
            .init(name: "add_waveform", arguments: #"{"style": "bars"}"#),
            .init(name: "jammer_unoffered", arguments: "{}"),
        ], cost: nil)
        let plan = try AgentPlanner.plan(from: response, extra: ["jammer_gain"])
        #expect(plan.steps.map(\.op) == ["jammer_gain", "add_waveform"])
        #expect(plan.droppedOps == ["jammer_unoffered"])
        #expect(!plan.usesAI)
    }

    @Test func aMadeUpPlanReachesTheSiblings() throws {
        // The development hook's raw plan (no planner, no cost) keeps sibling steps.
        let plan = try AgentPlanner.parsePlan(#"{"steps": [{"op": "jammer_echo", "params": {"delay": 0.3}}, {"op": "add_waveform", "params": {}}]}"#)
        #expect(plan.steps.map(\.op) == ["jammer_echo", "add_waveform"])
    }

    @Test func siblingContextReachesThePlanner() {
        let messages = AgentPlanner.toolMessages(goal: "Make the cover", context: AgentContext(width: 100, height: 100, layerCount: 1,
                                                 hasSelection: false, activeLayerKind: "pixel", activeLayerName: "Background"),
                                                 history: [], siblingContext: "[Sibling apps: Jämmer is running.]")
        #expect((messages.last?["content"] as? String)?.contains("[Sibling apps: Jämmer is running.]") == true)
    }

    @Test func addWaveformIsAnOrdinaryFreeStep() throws {
        let op = try #require(AgentPlanner.op(named: "add_waveform"))
        #expect(!op.isAIJob)
        let schema = AgentPlanner.paramsSchema(op)
        #expect((schema["required"] as? [String])?.isEmpty == true)
    }

    @Test func waveformPathFillsTheBox() {
        let wave = SiblingWaveform(amplitudes: [0, 0.5, 1, 0.25], documentName: "Episode 7")
        let rect = CGRectLike(x0: 100, y0: 200, x1: 500, y1: 300)
        let bars = wave.path(in: rect, style: .bars)
        #expect(bars.name == "Waveform – Episode 7" && bars.subpaths.count == 4)
        let all = bars.subpaths.flatMap(\.anchors).map(\.point)
        #expect(all.map(\.y).min() == 200 && all.map(\.y).max() == 300, "the loudest bar spans the box")
        #expect(all.map(\.x).min()! >= 100 && all.map(\.x).max()! <= 500)
        // Silence keeps a sliver, so it still shows.
        let quiet = bars.subpaths[0].anchors.map(\.point.y)
        #expect(quiet.max()! - quiet.min()! >= 1)
        let wavePath = wave.path(in: rect, style: .wave)
        #expect(wavePath.subpaths.count == 1 && wavePath.subpaths[0].isClosed && wavePath.subpaths[0].anchors.count == 2 + 2 * 4)
        #expect(wavePath.asSelection.bounds(in: PixelRect(x: 0, y: 0, width: 600, height: 400)) != nil)
    }
}

/// Live against a running Jämmer with a document named "Episode 7" (GLIMMER_LIVE_SIBLINGS=1;
/// never in CI). Changes that document: an echo, which one undo in Jämmer takes back.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["GLIMMER_LIVE_SIBLINGS"] == "1"), .serialized)
struct LiveSiblingTests {
    @Test func realJammer() async throws {
        let client = SiblingClient()
        #expect(await client.running().contains(.jammer))
        let (tools, context) = await client.toolbox()
        #expect(tools.contains { $0.toolName == "jammer_echo" } && context?.contains("Episode 7") == true)
        let before = try await client.document(.jammer, "Episode 7")
        _ = try await client.perform(tool: "jammer_echo", params: ["delay": .number(0.25), "document": .string("Episode 7")])
        let wave = try await client.waveform(.jammer, document: "Episode 7", columns: 32)
        #expect(wave.amplitudes.count == 32 && wave.amplitudes.max()! > 0.1)
        print("LIVE: tools \(tools.map(\.toolName).joined(separator: ", "))")
        print("LIVE: echo on \(before.name) done; waveform peak \(wave.amplitudes.max()!)")
    }
}
