import AppKit
import GlimmerAI
import GlimmerCore
import GlimmerRender
import Network
import OSLog
import UniformTypeIdentifiers

// MARK: Open documents

/// The editor sessions the API can address, by a stable id per window.
@MainActor
final class AgentRegistry {
    static let shared = AgentRegistry()

    private struct Entry {
        let id: String
        weak var session: EditorSession?
    }

    private var entries: [Entry] = []
    /// The document whose window was key last: `frontmost` in /documents (series rule).
    private(set) weak var front: EditorSession?

    func register(_ session: EditorSession) {
        entries.removeAll { $0.session == nil || $0.session === session }
        entries.append(Entry(id: session.agentID, session: session))
        front = session  // a window that just opened is in front
    }

    func markFront(_ session: EditorSession) { front = session }

    func unregister(_ session: EditorSession) {
        entries.removeAll { $0.session == nil || $0.session === session }
        if front === session { front = entries.last?.session }
    }

    var sessions: [EditorSession] {
        entries.removeAll { $0.session == nil }
        return entries.compactMap(\.session)
    }

    func session(_ id: String) -> EditorSession? {
        sessions.first { $0.agentID.caseInsensitiveCompare(id) == .orderedSame }
    }
}

// MARK: Jobs

/// Long requests (anything with a paid step, or `"async": true`) run as jobs:
/// POST answers 202 with the job, GET /api/v1/jobs/{id} reads it, DELETE cancels it.
/// The same shape as Flimmer's and Jämmer's jobs.
@MainActor
final class AgentJobs {
    static let shared = AgentJobs()

    final class Job {
        let id = UUID().uuidString
        let kind: String
        let documentID: String
        var status = "queued"  // queued, running, done, failed, cancelled
        var progress = 0.0
        var error: [String: Any]?
        var result: [String: Any]?
        var finished: Date?
        var task: Task<Void, Never>?

        init(kind: String, documentID: String) {
            self.kind = kind
            self.documentID = documentID
        }

        var json: [String: Any] {
            var d: [String: Any] = ["id": id, "kind": kind, "document": documentID, "status": status, "progress": progress]
            if let error { d["error"] = error }
            if let result { d["result"] = result }
            return d
        }
    }

    private var jobs: [String: Job] = [:]
    private var order: [String] = []

    func add(_ job: Job) {
        jobs[job.id] = job
        order.append(job.id)
        // Keep the 50 most recent finished jobs.
        let finished = order.filter { jobs[$0]?.finished != nil }
        for id in finished.dropLast(50) { jobs[id] = nil; order.removeAll { $0 == id } }
    }

    func job(_ id: String) -> Job? { jobs[id] ?? jobs.values.first { $0.id.caseInsensitiveCompare(id) == .orderedSame } }
    var running: [Job] { order.compactMap { jobs[$0] }.filter { $0.finished == nil } }
    var all: [Job] { order.compactMap { jobs[$0] } }
}

// MARK: Server

/// The local HTTP server for agents: the guide at `/glimmer` and the API under
/// `/api/v1`. It listens on 127.0.0.1 only, on port 9001 or the next free one.
@MainActor
@Observable
final class AgentServer {
    static let shared = AgentServer()

    private(set) var port: UInt16?
    private(set) var failure: String?
    @ObservationIgnored private var listener: NWListener?
    nonisolated static let queue = DispatchQueue(label: "glimmer.agent-server")

    var guideURL: String? { port.map { "http://127.0.0.1:\($0)/glimmer" } }

    /// The text for the splash's field: an agent that gets only this can find its way.
    var agentPrompt: String? {
        guideURL.map { "Learn all about Glimmer and how to interact with it: fetch and follow this guide \($0)" }
    }

    func start() {
        guard listener == nil else { return }
        Task {
            for candidate in AgentAPI.candidatePorts {
                if let l = await Self.listen(on: candidate) {
                    listener = l
                    port = candidate
                    return
                }
            }
            failure = String(localized: "Port 9001 and ports 9101–9119 are all in use.")
        }
    }

    /// A listener on 127.0.0.1:`port`, or nil when the port is taken.
    nonisolated private static func listen(on port: UInt16) async -> NWListener? {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = false
        params.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: port)!)
        guard let listener = try? NWListener(using: params) else { return nil }
        listener.newConnectionHandler = { connection in Self.handle(connection, port: port) }
        final class Once: @unchecked Sendable { var done = false }
        let once = Once()
        return await withCheckedContinuation { (continuation: CheckedContinuation<NWListener?, Never>) in
            listener.stateUpdateHandler = { state in
                // Called on `queue`, one at a time.
                guard !once.done else { return }
                switch state {
                case .ready:
                    once.done = true
                    continuation.resume(returning: listener)
                case .failed, .cancelled:
                    once.done = true
                    listener.cancel()
                    continuation.resume(returning: nil)
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
    }

    nonisolated private static func handle(_ connection: NWConnection, port: UInt16) {
        connection.start(queue: queue)
        receive(connection, buffer: Data(), port: port)
    }

    nonisolated private static func receive(_ connection: NWConnection, buffer: Data, port: UInt16) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4 << 20) { data, _, isComplete, error in
            var buffer = buffer
            if let data { buffer.append(data) }
            switch AgentAPI.parse(buffer) {
            case .incomplete:
                if isComplete || error != nil { connection.cancel() } else { receive(connection, buffer: buffer, port: port) }
            case .invalid(let message):
                let tooLarge = message.contains("too large")
                send(.error(AgentAPI.APIError(tooLarge ? 413 : 400, tooLarge ? "too_large" : "bad_request", message)), on: connection)
            case .request(let request):
                if let refusal = AgentAPI.check(request, port: port) {
                    send(.error(refusal), on: connection)
                    return
                }
                Task { @MainActor in
                    let response = await AgentRouter.route(request, port: port)
                    send(response, on: connection)
                }
            }
        }
    }

    nonisolated private static func send(_ response: AgentAPI.Response, on connection: NWConnection) {
        connection.send(content: response.serialized, completion: .contentProcessed { _ in connection.cancel() })
    }
}

// MARK: Routes

@MainActor
enum AgentRouter {
    typealias Response = AgentAPI.Response
    typealias APIError = AgentAPI.APIError

    static var appVersion: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?" }

    private static let log = Logger(subsystem: "com.brattoo.glimmer", category: "agent")

    static func route(_ r: AgentAPI.Request, port: UInt16) async -> Response {
        // A sibling app (Flimmer, Jämmer) names itself; it grants nothing, it's only shown.
        if let sibling = AgentAPI.sibling(r) {
            log.notice("\(r.method, privacy: .public) \(r.path, privacy: .public) requested by \(sibling, privacy: .public)")
        }
        do {
            return try await dispatch(r, port: port)
        } catch let error as APIError {
            return .error(error)
        } catch {
            return .error(.internalError((error as? LocalizedError)?.errorDescription ?? error.localizedDescription))
        }
    }

    private static func dispatch(_ r: AgentAPI.Request, port: UInt16) async throws -> Response {
        let s = r.segments
        func only(_ methods: String...) throws {
            guard methods.contains(r.method) else {
                throw APIError(405, "method_not_allowed", "\(r.method) isn't allowed here; use \(methods.joined(separator: " or ")).")
            }
        }
        switch s {
        case [], ["api"], ["api", "v1"]:
            try only("GET")
            return .json(["guide": "http://127.0.0.1:\(port)/glimmer", "api": "http://127.0.0.1:\(port)/api/v1"])
        case ["glimmer"], ["glimmer.md"]:
            try only("GET")
            return .text(AgentAPI.guide(port: port, appVersion: appVersion))
        case ["api", "v1", "status"]:
            try only("GET")
            return .json(["app": ["name": "Glimmer", "version": appVersion], "api": AgentAPI.version, "port": Int(port),
                          "documents": AgentRegistry.shared.sessions.map(summary),
                          "jobs": AgentJobs.shared.running.map(\.json)])
        case ["api", "v1", "operations"]:
            try only("GET")
            return .json(["operations": AgentAPI.operations])
        case ["api", "v1", "documents"]:
            try only("GET", "POST")
            if r.method == "GET" { return .json(["documents": AgentRegistry.shared.sessions.map(summary)]) }
            return try await createDocument(r)
        case ["api", "v1", "jobs"]:
            try only("GET")
            return .json(["jobs": AgentJobs.shared.all.map(\.json)])
        case let p where p.count == 4 && Array(p.prefix(3)) == ["api", "v1", "jobs"]:
            try only("GET", "DELETE")
            guard let job = AgentJobs.shared.job(p[3]) else {
                throw APIError.notFound("No job with id \(p[3]). Finished jobs are kept for a while; GET /api/v1/jobs lists them.")
            }
            if r.method == "DELETE", job.finished == nil {
                job.task?.cancel()
                AgentRegistry.shared.session(job.documentID)?.ai.cancelRunningJobs()
            }
            return .json(["job": job.json])
        case let p where p.count >= 4 && Array(p.prefix(3)) == ["api", "v1", "documents"]:
            guard let session = AgentRegistry.shared.session(p[3]) else {
                throw APIError.notFound("No open document with id \(p[3]). GET /api/v1/documents lists them.")
            }
            switch Array(p.dropFirst(4)) {
            case []:
                try only("GET")
                return .json(["document": detail(session)])
            case ["image"]:
                try only("GET")
                return try await image(session, r)
            case ["steps"]:
                try only("POST")
                return try await steps(session, r)
            case ["undo"], ["redo"]:
                try only("POST")
                return try undoRedo(session, redo: p.last == "redo")
            case ["export"]:
                try only("POST")
                return try await export(session, r)
            default:
                throw APIError.notFound("No such path: \(r.path). See /glimmer.")
            }
        default:
            throw APIError.notFound("No such path: \(r.path). See /glimmer.")
        }
    }

    // MARK: Documents

    static func summary(_ session: EditorSession) -> [String: Any] {
        let st = session.state
        return ["id": session.agentID, "name": st.layers.first?.name ?? "Untitled", "width": st.width, "height": st.height,
                "layerCount": st.allLayers.count, "hasSelection": st.selection != nil,
                "frontmost": AgentRegistry.shared.front === session]
    }

    static func detail(_ session: EditorSession) -> [String: Any] {
        var d = summary(session)
        let st = session.state
        d["layers"] = st.layers.reversed().map(describe)
        d["activeLayer"] = st.activeLayer.map { ["id": $0.id.uuidString, "name": $0.name] } ?? NSNull()
        if let sel = st.selection?.bounds(in: st.bounds) { d["selectionBounds"] = ["x": sel.x, "y": sel.y, "width": sel.width, "height": sel.height] }
        return d
    }

    static func describe(_ layer: Layer) -> [String: Any] {
        var d: [String: Any] = ["id": layer.id.uuidString, "name": layer.name, "visible": layer.isVisible,
                                "opacity": layer.opacity, "blendMode": layer.blendMode.rawValue, "hasMask": layer.mask != nil]
        switch layer.content {
        case .raster: d["kind"] = "pixels"
        case .adjustment(let a): d["kind"] = "adjustment"; d["adjustment"] = a.kind.rawValue
        case .text(let t): d["kind"] = "text"; d["text"] = t.string
        case .group(let g): d["kind"] = "group"; d["children"] = g.children.reversed().map(describe)
        case .fill: d["kind"] = "fill"
        case .smart: d["kind"] = "smartObject"
        }
        return d
    }

    private static func json(_ r: AgentAPI.Request) throws -> [String: Any] {
        if r.body.isEmpty { return [:] }
        guard let obj = try? JSONSerialization.jsonObject(with: r.body) as? [String: Any] else {
            throw APIError.badRequest("The body isn't a JSON object.")
        }
        return obj
    }

    private static func createDocument(_ r: AgentAPI.Request) async throws -> Response {
        let type = (r.headers["content-type"] ?? "").lowercased()
        var state: DocumentState
        if type.hasPrefix("image/") || type == "application/octet-stream" {
            state = try documentFromImage(r.body, name: r.query["name"] ?? "Image")
        } else {
            let obj = try json(r)
            if let b64 = obj["image"] as? String {
                guard let data = Data(base64Encoded: b64, options: .ignoreUnknownCharacters) else {
                    throw APIError.badRequest("\"image\" isn't valid base64.")
                }
                state = try documentFromImage(data, name: obj["name"] as? String ?? "Image")
            } else if let w = obj["width"] as? Int, let h = obj["height"] as? Int {
                guard (1...30_000).contains(w), (1...30_000).contains(h) else {
                    throw APIError.badRequest("width and height must be 1…30000 pixels.")
                }
                let bg: DocumentState.Background = switch obj["background"] as? String ?? "white" {
                case "transparent": .transparent
                case "black": .black
                default: .white
                }
                state = .new(width: w, height: h, background: bg)
            } else {
                throw APIError.badRequest("Send image bytes (Content-Type: image/…), {\"image\": \"<base64>\"} or {\"width\": …, \"height\": …}.")
            }
        }
        let marker = state.layers.first?.id
        DocumentOpener.shared.createDocument(state)
        // The window opens asynchronously; wait for its session to register.
        for _ in 0..<100 {
            if let session = AgentRegistry.shared.sessions.first(where: { $0.state.layers.first?.id == marker }) {
                showRequester(r, in: session)
                return .json(["document": detail(session)], status: 201)
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw APIError.internalError("The document window didn't open in time.")
    }

    private static func documentFromImage(_ data: Data, name: String) throws -> DocumentState {
        guard !data.isEmpty else { throw APIError.badRequest("The image body is empty.") }
        do {
            let image = try ImageImporter.image(from: data)
            let tiles = try ImageImporter.tiles(from: image)
            return DocumentState(width: image.width, height: image.height, layers: [Layer(name: name, content: .raster(tiles))])
        } catch {
            throw APIError.badRequest("Glimmer couldn't read the image (\(error.localizedDescription)). Send PNG, JPEG, HEIC, TIFF or WebP bytes.")
        }
    }

    // MARK: Images

    private static func format(_ name: String?) throws -> ExportOptions.Format {
        guard let name else { return .png }
        let n = name.lowercased() == "jpg" ? "jpeg" : name.lowercased()
        guard let f = ExportOptions.Format(rawValue: n) else {
            throw APIError.badRequest("format must be one of: png, jpeg, heic, tiff, webp.")
        }
        return f
    }

    private static func render(_ session: EditorSession, options: ExportOptions) async throws -> Response {
        guard let metal = MetalContext.shared else { throw APIError.internalError("No Metal GPU available.") }
        let snapshot = session.state
        let data = try await Task.detached(priority: .userInitiated) {
            try ImageExporter.encode(try ImageExporter.flatten(snapshot, context: metal), options: options)
        }.value
        return Response(status: 200, contentType: options.format.contentType.preferredMIMEType ?? "application/octet-stream", body: data)
    }

    private static func image(_ session: EditorSession, _ r: AgentAPI.Request) async throws -> Response {
        var options = ExportOptions(format: try format(r.query["format"]), quality: 0.9)
        if let side = r.query["maxSide"] {
            guard let v = Int(side), v >= 16 else { throw APIError.badRequest("maxSide must be a whole number ≥ 16.") }
            options.maxPixelSide = v
        }
        return try await render(session, options: options)
    }

    private static func export(_ session: EditorSession, _ r: AgentAPI.Request) async throws -> Response {
        let obj = try json(r)
        var options = ExportOptions(format: try format(obj["format"] as? String))
        if let q = obj["quality"] as? Double {
            guard (0.05...1).contains(q) else { throw APIError.badRequest("quality must be 0.05…1.") }
            options.quality = q
        }
        if let side = obj["maxSide"] as? Int { options.maxPixelSide = max(16, side) }
        if let bytes = obj["maxBytes"] as? Int { options.maxBytes = max(1_000, bytes) }
        return try await render(session, options: options)
    }

    // MARK: Editing

    /// "Requested by Flimmer" over the canvas, when a sibling app makes the change.
    private static func showRequester(_ r: AgentAPI.Request, in session: EditorSession) {
        guard let sibling = AgentAPI.sibling(r) else { return }
        session.showToast(String(localized: "Requested by \(sibling)"))
    }

    private static func steps(_ session: EditorSession, _ r: AgentAPI.Request) async throws -> Response {
        let obj = try json(r)
        guard let raw = obj["steps"] as? [Any], !raw.isEmpty else {
            throw APIError.badRequest("Send {\"steps\": [{\"op\": \"…\", \"params\": {…}}]}. GET /api/v1/operations lists the ops.")
        }
        let allowPaid = obj["allowPaid"] as? Bool ?? false
        var steps: [AgentStep] = []
        for (i, item) in raw.enumerated() {
            guard var step = item as? [String: Any], let op = step["op"] as? String else {
                throw APIError.badRequest("Step \(i) needs an \"op\".")
            }
            guard AgentPlanner.op(named: op) != nil else {
                throw APIError(404, "not_found", "Step \(i): unknown op \"\(op)\". GET /api/v1/operations lists them.")
            }
            if step["params"] == nil { step["params"] = [String: Any]() }
            guard JSONSerialization.isValidJSONObject(step),
                  let data = try? JSONSerialization.data(withJSONObject: step),
                  let decoded = try? JSONDecoder().decode(AgentStep.self, from: data) else {
                throw APIError.badRequest("Step \(i): \"params\" must be an object.")
            }
            if AgentAPI.paidOps.contains(op) {
                guard allowPaid else {
                    throw APIError(402, "paid_not_allowed", "Step \(i) (\(op)) calls OpenRouter and costs money. Pass \"allowPaid\": true to allow it.")
                }
                guard session.ai.hasAPIKey else {
                    throw APIError(402, "paid_not_allowed", "Step \(i) (\(op)) needs an OpenRouter key, and none is saved in Glimmer › Settings.")
                }
            }
            steps.append(decoded)
        }
        showRequester(r, in: session)
        // Paid steps take a while: they always run as a job, and so does any request that asks.
        if obj["async"] as? Bool == true || steps.contains(where: { AgentAPI.paidOps.contains($0.op) }) {
            let job = AgentJobs.Job(kind: "steps", documentID: session.agentID)
            AgentJobs.shared.add(job)
            let total = Double(steps.count)
            job.task = Task { @MainActor in
                job.status = "running"
                let results = await session.ai.runAPISteps(steps) { done in job.progress = Double(done) / total }
                job.result = ["results": stepList(results), "document": detail(session)]
                if let failed = results.firstIndex(where: { $0.status == "failed" }) {
                    job.status = "failed"
                    job.error = ["code": "step_failed", "step": failed,
                                 "message": "Step \(failed) (\(results[failed].op)) failed: \(results[failed].error ?? "")"]
                } else if results.contains(where: { $0.status == "cancelled" }) {
                    job.status = "cancelled"
                } else {
                    job.status = "done"
                    job.progress = 1
                }
                job.finished = Date()
            }
            return .json(["job": job.json], status: 202)
        }
        let results = await session.ai.runAPISteps(steps)
        let list = stepList(results)
        if let failed = results.firstIndex(where: { $0.status == "failed" }) {
            return .json(["error": ["code": "step_failed", "step": failed,
                                    "message": "Step \(failed) (\(results[failed].op)) failed: \(results[failed].error ?? "")"] as [String: Any],
                          "results": list, "document": detail(session)], status: 422)
        }
        return .json(["results": list, "document": detail(session)])
    }

    private static func stepList(_ results: [AIController.APIStepResult]) -> [[String: Any]] {
        results.enumerated().map { i, res in
            var d: [String: Any] = ["index": i, "op": res.op, "status": res.status]
            if let e = res.error { d["error"] = e }
            return d
        }
    }

    private static func undoRedo(_ session: EditorSession, redo: Bool) throws -> Response {
        guard let undo = session.undoManager else { throw APIError.unprocessable("no_history", "The document has no undo history yet.") }
        if redo {
            guard undo.canRedo else { throw APIError.unprocessable("nothing_to_redo", "Nothing to redo.") }
            undo.redo()
        } else {
            guard undo.canUndo else { throw APIError.unprocessable("nothing_to_undo", "Nothing to undo.") }
            undo.undo()
        }
        return .json(["document": detail(session)])
    }
}
