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

    @Test func operationsAndGuideComeFromTheAssistantsList() {
        let ops = AgentAPI.operations
        #expect(ops.count == AgentPlanner.ops.count)
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
