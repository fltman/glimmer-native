import Foundation
@testable import GlimmerAI
import Testing

@Suite struct AgentAPITests {
    func raw(_ s: String) -> Data { Data(s.replacingOccurrences(of: "\n", with: "\r\n").utf8) }

    @Test func parsesARequestWithBodyAndQuery() throws {
        let data = raw("POST /api/v1/documents/abc/image?maxSide=512&format=png HTTP/1.1\nHost: 127.0.0.1:9001\nX-Glimmer-Agent: 1\nContent-Length: 5\n\n") + Data("hello".utf8)
        guard case .request(let r) = AgentAPI.parse(data) else { Issue.record("not parsed"); return }
        #expect(r.method == "POST")
        #expect(r.segments == ["api", "v1", "documents", "abc", "image"])
        #expect(r.query == ["maxSide": "512", "format": "png"])
        #expect(r.headers["x-glimmer-agent"] == "1")
        #expect(r.body == Data("hello".utf8))
    }

    @Test func waitsForTheWholeBody() {
        let data = raw("POST /x HTTP/1.1\nHost: localhost\nContent-Length: 10\n\n") + Data("12345".utf8)
        #expect(AgentAPI.parse(data) == .incomplete)
        #expect(AgentAPI.parse(raw("GET / HTTP/1.1\nHost: local")) == .incomplete)
    }

    @Test func refusesChunkedAndHugeBodies() {
        if case .invalid = AgentAPI.parse(raw("POST /x HTTP/1.1\nTransfer-Encoding: chunked\n\n")) {} else { Issue.record("chunked accepted") }
        if case .invalid = AgentAPI.parse(raw("POST /x HTTP/1.1\nContent-Length: 999999999999\n\n")) {} else { Issue.record("huge accepted") }
    }

    func request(_ method: String, headers: [String: String]) -> AgentAPI.Request {
        AgentAPI.Request(method: method, path: "/api/v1/status", headers: headers)
    }

    @Test func securityRules() {
        #expect(AgentAPI.check(request("GET", headers: ["host": "127.0.0.1:9001"]), port: 9001) == nil)
        #expect(AgentAPI.check(request("GET", headers: ["host": "localhost:9001"]), port: 9001) == nil)
        // DNS rebinding: a foreign Host.
        #expect(AgentAPI.check(request("GET", headers: ["host": "evil.example:9001"]), port: 9001)?.status == 403)
        // From a web page.
        #expect(AgentAPI.check(request("GET", headers: ["host": "127.0.0.1:9001", "origin": "https://evil.example"]), port: 9001)?.status == 403)
        // State changes need the agent header.
        #expect(AgentAPI.check(request("POST", headers: ["host": "127.0.0.1:9001"]), port: 9001)?.message.contains("X-Glimmer-Agent") == true)
        #expect(AgentAPI.check(request("POST", headers: ["host": "127.0.0.1:9001", "x-glimmer-agent": "1"]), port: 9001) == nil)
    }

    @Test func errorsAreJSONWithCodeAndMessage() throws {
        let r = AgentAPI.Response.error(.notFound("No such document."))
        #expect(r.status == 404)
        let obj = try JSONSerialization.jsonObject(with: r.body) as? [String: [String: String]]
        #expect(obj?["error"]?["code"] == "not_found")
        #expect(String(decoding: r.serialized.prefix(30), as: UTF8.self).hasPrefix("HTTP/1.1 404 Not Found"))
    }

    @Test func unprocessableCarriesAReason() throws {
        let r = AgentAPI.Response.error(.unprocessable("nothing_to_undo", "Nothing to undo."))
        #expect(r.status == 422)
        let obj = try JSONSerialization.jsonObject(with: r.body) as? [String: [String: String]]
        #expect(obj?["error"]?["code"] == "unprocessable" && obj?["error"]?["reason"] == "nothing_to_undo")
    }

    @Test func aRefusedStepIsStepFailedWithAReason() {
        // SIBLINGS.md: inside /steps a refusal is always step_failed; unprocessable is only for other calls.
        let refused = AgentAPI.APIError.stepFailedBody(step: 1, op: "transform_layer", message: "Would rasterize.", reason: "bad_corners")
        #expect(refused["code"] as? String == "step_failed")
        #expect(refused["reason"] as? String == "bad_corners")
        #expect(refused["step"] as? Int == 1)
        let plain = AgentAPI.APIError.stepFailedBody(step: 0, op: "crop", message: "No such layer.", reason: nil)
        #expect(plain["code"] as? String == "step_failed" && plain["reason"] == nil)
        #expect(AgentAPI.guide(port: 9001, appVersion: "1").contains("`error.reason` says which (`would_rasterize_text`"))
        #expect(AgentAPI.guide(port: 9001, appVersion: "1").contains("`group_has_mask` is no longer returned"))
    }

    @Test func operationsAndGuideComeFromTheAssistantsList() {
        let ops = AgentAPI.operations
        #expect(ops.filter { $0["call"] == nil }.count == AgentPlanner.ops.count)
        #expect(ops.contains { ($0["name"] as? String) == "generate_layer" && ($0["paid"] as? Bool) == true })
        #expect(ops.contains { ($0["name"] as? String) == "auto_enhance" && ($0["paid"] as? Bool) == false })
        let guide = AgentAPI.guide(port: 9007, appVersion: "0.2.0")
        #expect(guide.contains("http://127.0.0.1:9007"))
        #expect(guide.contains("X-Glimmer-Agent: 1"))
        // Quick start comes before the endpoint reference.
        #expect(guide.range(of: "## Quick start")!.lowerBound < guide.range(of: "## Endpoints")!.lowerBound)
        for op in AgentPlanner.ops { #expect(guide.contains("### `\(op.name)`"), "\(op.name)") }
    }
}

@Suite struct SiblingProtocolTests {
    @Test func operationsHaveTheSeriesShape() throws {
        for op in AgentAPI.operations {
            let name = try #require(op["name"] as? String)
            #expect(op["description"] is String, "\(name)")
            #expect(op["paid"] is Bool && op["undoable"] is Bool && op["startsJob"] is Bool, "\(name)")
            let params = try #require(op["params"] as? [String: Any], "\(name)")
            #expect(params["type"] as? String == "object")
            #expect(params["properties"] is [String: Any] && params["required"] is [String])
            // Every operation offered as a tool accepts `rationale` and says so, and its schema is closed (SIBLINGS.md §3, 2026-11-16).
            #expect((params["properties"] as? [String: Any])?["rationale"] != nil && params["additionalProperties"] as? Bool == false, "\(name)")
            if let call = op["call"] as? [String: String] {
                #expect(["GET", "POST"].contains(call["method"] ?? "") && call["path"]?.hasPrefix("/api/v1/documents/{id}/") == true)
                let id = (params["properties"] as? [String: Any])?["id"] as? [String: Any]
                #expect(id?["x-in"] as? String == "path" && (params["required"] as? [String])?.contains("id") == true, "\(name)")
            }
        }
        #expect(Set(AgentAPI.operations.compactMap { $0["call"] == nil ? nil : $0["name"] as? String }) == ["export", "image", "add_image", "undo", "redo"])
        // Every op has a tier; the core set is small and every core name exists.
        #expect(AgentAPI.operations.allSatisfy { ["core", "advanced"].contains($0["tier"] as? String ?? "") })
        let core = AgentAPI.operations.filter { $0["tier"] as? String == "core" }.compactMap { $0["name"] as? String }
        #expect((10...15).contains(core.count) && Set(core) == AgentAPI.coreOps)
        // It's plain JSON, and paid steps are the ones that start jobs.
        #expect(JSONSerialization.isValidJSONObject(["operations": AgentAPI.operations]))
        let export = try #require(AgentAPI.operations.first { $0["name"] as? String == "export" })
        let exportProps = try #require((export["params"] as? [String: Any])?["properties"] as? [String: Any])
        #expect((exportProps["preset"] as? [String: Any])?["enum"] as? [String] == ["podcast-cover"])
        #expect((exportProps["size"] as? [String: Any])?["enum"] as? [Int] == [3000, 1400])
        let image = try #require(AgentAPI.operations.first { $0["name"] as? String == "image" })
        let imageProps = try #require((image["params"] as? [String: Any])?["properties"] as? [String: Any])
        #expect((imageProps["maxSide"] as? [String: Any])?["x-in"] as? String == "query")
        let gen = try #require(AgentAPI.operations.first { $0["name"] as? String == "generate_layer" })
        #expect(gen["paid"] as? Bool == true && gen["startsJob"] as? Bool == true)
        let adj = try #require(AgentAPI.operations.first { $0["name"] as? String == "add_adjustment" })
        #expect(adj["paid"] as? Bool == false && adj["startsJob"] as? Bool == false)
        let props = try #require((adj["params"] as? [String: Any])?["properties"] as? [String: Any])
        #expect((props["type"] as? [String: Any])?["enum"] is [String])
    }

    @Test func siblingHeaderIsShownByName() {
        func req(_ value: String?) -> AgentAPI.Request {
            AgentAPI.Request(method: "POST", path: "/", headers: value.map { ["x-sibling": $0] } ?? [:])
        }
        #expect(AgentAPI.sibling(req(nil)) == nil)
        #expect(AgentAPI.sibling(req("flimmer")) == "Flimmer")
        #expect(AgentAPI.sibling(req(" Jammer ")) == "Jämmer")
        #expect(AgentAPI.sibling(req("other-app")) == "Other-app")
        #expect(AgentAPI.sibling(req("<script>")) == "Script")
        #expect(AgentAPI.sibling(req("!!!")) == nil)
        #expect(AgentAPI.sibling(req(String(repeating: "a", count: 100)))?.count == 32)
    }
}

@Suite struct TransformLayerOpTests {
    @Test func theSchemaTakesCornersAndAPermission() throws {
        let op = try #require(AgentAPI.operations.first { $0["name"] as? String == "transform_layer" })
        #expect(op["paid"] as? Bool == false && op["startsJob"] as? Bool == false && op["tier"] as? String == "advanced")
        let props = try #require((op["params"] as? [String: Any])?["properties"] as? [String: Any])
        let corners = try #require(props["corners"] as? [String: Any])
        #expect(corners["type"] as? String == "array")
        #expect((corners["items"] as? [String: Any])?["type"] as? String == "array")
        #expect((props["allowRasterize"] as? [String: Any])?["type"] as? String == "boolean")
        #expect(((op["params"] as? [String: Any])?["required"] as? [String])?.isEmpty == true, "every parameter is optional")
    }
}
