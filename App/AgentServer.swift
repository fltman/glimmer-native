import AppKit
import GlimmerAI
import GlimmerCore
import GlimmerRender
import Network
import OSLog
import UniformTypeIdentifiers
import simd

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
            return .error(.internalError(AgentAPI.words(for: error)))
        }
    }

    private static func dispatch(_ r: AgentAPI.Request, port: UInt16) async throws -> Response {
        let s = r.segments
        func only(_ methods: String...) throws {
            guard methods.contains(r.method) else {
                throw APIError(405, "method_not_allowed", "\(r.method) isn't allowed here; use \(methods.joined(separator: " or ")).")
            }
        }
        // A query parameter the path doesn't take is refused by name, not passed over (the series' rule, 2026-11-16).
        if s.count > 2, s[0] == "api", s[1] == "v1",
           let message = StepParameters.strayMessage(r.query.keys, allowed: StepParameters.queryParameters(path: Array(s.dropFirst(2)), method: r.method), what: "\(r.method) \(r.path)") {
            throw APIError.badRequest(message)
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
            return .json(["app": ["name": "Glimmer", "version": appVersion, "bundleID": AppIdentity.ownBundleID],
                          // The process answering: a caller that started its own copy checks it is talking to that one.
                          "api": AgentAPI.version, "port": Int(port), "pid": Int(ProcessInfo.processInfo.processIdentifier),
                          "documents": AgentRegistry.shared.sessions.map(summary),
                          "jobs": AgentJobs.shared.running.map(\.json),
                          // Which services have a key (never the key): paid steps need the one they use.
                          "providerKeys": Self.providerKeys(), "linkJournal": LinkJournal.shared.summary])
        #if DEBUG
        case ["api", "v1", "debug", "journal-idle"]:
            // Whether the link journal has written everything asked of it (debug builds only: the restart test
            // stops the app hard "after a step", and must know that the step's write is done, not guess with a sleep).
            return .json(["idle": LinkJournal.shared.isIdle])
        case ["api", "v1", "debug", "journal-stop"]:
            // Arms a stop of this very process in the middle of the next journal write (debug builds only): after the
            // first changed file ("file"), with the new copy complete but not in place ("swap"), or in place with the
            // record not yet written again ("record"). The restart test then reads what a launch finds.
            try only("POST")
            let at = (try? JSONSerialization.jsonObject(with: r.body) as? [String: Any])?["at"] as? String ?? ""
            guard let point: LinkJournalWriter.StopPoint = ["file": .afterFiles(1), "swap": .beforeSwap, "record": .beforeRecord][at] else {
                throw APIError.badRequest("at: file, swap or record")
            }
            LinkJournal.shared.stopNextWriteAt = point
            return .json(["armed": at])
        case ["api", "v1", "debug", "fixture"]:
            // States for the accessibility checks (debug builds only; see DebugFixtures.swift).
            try only("POST")
            let name = (try? JSONSerialization.jsonObject(with: r.body) as? [String: Any])?["name"] as? String ?? ""
            guard let session = AgentRegistry.shared.front ?? AgentRegistry.shared.sessions.first, session.ai.showFixture(name) else {
                throw APIError.unprocessable("unknown_fixture", "No fixture named “\(name)”.")
            }
            return .json(["fixture": name])
        #if GLIMMER_RAW
        case ["api", "v1", "debug", "raw"]:
            // A RAW file from the request's body opened as File › Open… would (debug builds only, for the
            // GUI checks: a sandboxed test copy can't read the sample folder). Not part of the agent API.
            try only("POST")
            let failure: Error? = await withCheckedContinuation { done in
                DocumentOpener.shared.openRawFile(r.body, fileName: r.query["name"] ?? "sample.dng") { done.resume(returning: $0) }
            }
            if let failure { throw APIError.unprocessable("raw_not_developed", AgentAPI.words(for: failure)) }
            return .json(["opened": true])
        case ["api", "v1", "debug", "raw-develop-trace"]:
            try only("GET")
            return .json(["last": RawDevelopTrace.last])
        case ["api", "v1", "debug", "raw-draft-timing"]:
            // Measuring only: the draft for the front document's RAW layer, as the Develop sheet makes it
            // (one kept decoder, the real development scaled down), over a run of changed settings.
            try only("POST")
            guard let raw = (AgentRegistry.shared.front ?? AgentRegistry.shared.sessions.first)?.activeLayer?.raw else {
                throw APIError.unprocessable("no_raw_layer", "The front document's active layer has no RAW file.")
            }
            let data = raw.data
            let measured: (decoder: Double, changes: [Double], draft: String, full: String) = try await Task.detached(priority: .userInitiated) {
                var began = Date()
                let draft = try RawDraft(data)
                let made = Date().timeIntervalSince(began)
                let info = try RawDevelopment.info(data)
                var changes: [Double] = []
                // The first is the picture when the sheet opens; then the warm-up the sheet does; then a slider dragged: exposure up in steps, then temperature.
                var warm = 0.0
                for step in 0..<16 {
                    if step == 1 { began = Date(); draft.warmUp(from: RawSettings()); warm = (Date().timeIntervalSince(began) * 1000).rounded() }
                    var s = RawSettings()
                    if step > 0 { s.exposure = Double(min(step, 8)) * 0.1 }
                    if step > 8 { s.temperature = info.temperature * (1 + Double(step - 8) * 0.02) }
                    began = Date()
                    _ = try draft.picture(s)
                    changes.append((Date().timeIntervalSince(began) * 1000).rounded())
                }
                return ((made * 1000).rounded(), changes + [warm], "\(draft.width)×\(draft.height)", "\(info.width)×\(info.height)")
            }.value
            return .json(["decoderMs": measured.decoder, "firstPictureMs": measured.changes[0], "changesMs": Array(measured.changes.dropFirst().dropLast()), "warmUpMs": measured.changes.last ?? 0,
                          "draft": measured.draft, "full": measured.full])
        #endif
        #endif
        case ["api", "v1", "operations"]:
            try only("GET")
            return .json(["operations": AgentAPI.operations])
        case ["api", "v1", "requirements"]:
            // What may need installing, from the register. Reading it downloads nothing.
            try only("GET")
            return .json(["items": Requirement.installable.map(requirementJSON)])
        case ["api", "v1", "settings", "open"]:
            // Only opens a pane of Settings for the person; it changes no setting and starts nothing.
            try only("POST")
            let pane = try json(r, "settings.open")["pane"] as? String ?? "general"
            guard SettingsView.panes.contains(pane) else {
                throw APIError.badRequest("pane must be one of: \(SettingsView.panes.joined(separator: ", ")).")
            }
            SettingsView.open(pane: pane)
            return .json(["opened": pane])
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
                _ = try json(r, "undo")
                return try undoRedo(session, redo: p.last == "redo")
            case ["export"]:
                try only("POST")
                return try await export(session, r)
            case ["layers"]:
                try only("POST")
                return try addImage(session, r)
            #if GLIMMER_RAW
            case let rest where rest.count == 4 && rest[0] == "layers" && rest[2] == "raw" && rest[3] == "info":
                try only("GET")
                let key = rest[1].removingPercentEncoding ?? rest[1]
                let layers = session.state.allLayers
                guard let layer = layers.first(where: { $0.id.uuidString.caseInsensitiveCompare(key) == .orderedSame }) ?? layers.first(where: { $0.name == key }) else {
                    throw APIError.notFound("No layer “\(key)” in this document.")
                }
                do { return .json(["raw": try AIController.rawInfo(layer)]) }
                catch let e as AIController.StepError { throw APIError.unprocessable(e.reason ?? "not_raw", e.errorDescription ?? "This layer has no RAW file.") }
            #endif
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
        return ["id": session.agentID, "name": session.explicitName ?? st.layers.first?.name ?? "Untitled", "width": st.width, "height": st.height,
                "layerCount": st.allLayers.count, "hasSelection": st.selection != nil,
                "frontmost": AgentRegistry.shared.front === session,
                "startDocument": session.isUntouchedBlank && !session.madeByAPI,
                "linkedFile": Self.linkedFile(session) as Any? ?? NSNull()]
    }

    static func detail(_ session: EditorSession) -> [String: Any] {
        var d = summary(session)
        let st = session.state
        d["layers"] = st.layers.reversed().map(describe)
        d["activeLayer"] = st.activeLayer.map { ["id": $0.id.uuidString, "name": $0.name] } ?? NSNull()
        if let sel = st.selection?.bounds(in: st.bounds) { d["selectionBounds"] = ["x": sel.x, "y": sel.y, "width": sel.width, "height": sel.height] }
        // A document made from a Photoshop file says what came through and what did not.
        #if GLIMMER_PSD
        if let report = session.importReport {   // in English here; the window says it in the person's language
            var r: [String: Any] = ["source": report.source, "layersInFile": report.layersInFile, "layersKept": report.layersKept,
                                    "flattened": report.flattened, "looksTheSame": report.looksTheSame, "summary": report.lines.first ?? "",
                                    "notes": report.notes.map { ["layer": $0.layer ?? NSNull(), "kind": $0.kind.rawValue, "what": $0.what, "changesLook": $0.changesLook] as [String: Any] }]
            if let mean = report.meanDifference, let share = report.shareVisiblyDifferent {
                r["differenceFromFile"] = ["mean": mean, "shareVisiblyDifferent": share]
            }
            d["importReport"] = r
        }
        #endif
        return d
    }

    /// The tight bounds of a pixel layer's visible content (tile bounds are up to a tile too
    /// big on each side). Kept per layer until its pixels change.
    private static var boundsCache: [UUID: (signature: Int, bounds: PixelRect?)] = [:]
    private static let tileBounds = TileBoundsCache()
    private static func contentBounds(_ grid: TileGrid, id: UUID) -> PixelRect? {
        let signature = grid.contentSignature.hashValue
        if let hit = boundsCache[id], hit.signature == signature { return hit.bounds }
        // Per tile, remembered by the tile's identity: a step that changed a few tiles reads those few again, not the
        // layer. (Reading a 24-megapixel layer through after every pixel step cost about two seconds of each answer.)
        let bounds = grid.contentBounds(cache: tileBounds)
        if boundsCache.count > 2000 { boundsCache.removeAll() }
        boundsCache[id] = (signature, bounds)
        return bounds
    }

    /// Where a layer's content is, in document pixels (nil for adjustments and plain fills).
    static func layerBounds(_ layer: Layer) -> PixelRect? {
        switch layer.content {
        case .raster(let grid): return contentBounds(grid, id: layer.id)
        case .text(let t): return t.bounds
        case .smart(let s):
            let z = s.sourceSize
            let c = [SIMD2(0, 0), SIMD2(z.x, 0), z, SIMD2(0, z.y)].map(s.transform.apply)
            let lo = c.reduce(c[0], simd_min), hi = c.reduce(c[0], simd_max)
            return PixelRect(x: Int(lo.x.rounded(.down)), y: Int(lo.y.rounded(.down)),
                             width: Int((hi.x - lo.x).rounded(.up)), height: Int((hi.y - lo.y).rounded(.up)))
        default:
            guard let r = layer.vectorMask?.controlBounds else { return nil }
            return PixelRect(x: Int(r.minX), y: Int(r.minY), width: Int(r.width.rounded(.up)), height: Int(r.height.rounded(.up)))
        }
    }

    /// `layerBounds` cut down to what the layer's mask lets through.
    static func visibleBounds(_ layer: Layer) -> PixelRect? {
        guard let r = layerBounds(layer) else { return nil }
        guard let m = layer.mask, m.isEnabled, m.defaultValue == 0, layer.vectorMask == nil else { return r }
        return Selection(tiles: m.tiles).bounds(in: r) ?? r
    }

    static func describe(_ layer: Layer) -> [String: Any] {
        var d: [String: Any] = ["id": layer.id.uuidString, "name": layer.name, "visible": layer.isVisible,
                                "opacity": layer.opacity, "blendMode": layer.blendMode.rawValue, "hasMask": layer.mask != nil]
        if let r = visibleBounds(layer) { d["bounds"] = ["x": r.x, "y": r.y, "width": r.width, "height": r.height] }
        // The words of a layer that was text in an imported file and is pixels now.
        if let words = layer.formerText { d["formerText"] = words }
        #if GLIMMER_RAW
        // A layer opened from a camera's RAW file: it can be developed again (`develop_raw`).
        if let raw = AIController.describeRaw(layer) { d["raw"] = raw }
        #endif
        switch layer.content {
        case .raster: d["kind"] = "pixels"
        case .adjustment(let a): d["kind"] = "adjustment"; d["adjustment"] = a.kind.rawValue
        case .text(let t):
            d["kind"] = "text"
            d["text"] = t.string
            if let runs = t.styles, !runs.isEmpty {
                // In characters (grapheme clusters), like style_text's from and length.
                d["styles"] = runs.map { run -> [String: Any] in
                    let c = t.characterRange(of: run.range)
                    var o: [String: Any] = ["from": c.from, "length": c.length]
                    if let f = run.fontName { o["fontName"] = f }
                    if let s = run.size { o["size"] = s }
                    if let col = run.color { o["color"] = col.hexString }
                    return o
                }
            }
        case .group(let g): d["kind"] = "group"; d["children"] = g.children.reversed().map(describe)
        case .fill: d["kind"] = "fill"
        case .smart: d["kind"] = "smartObject"
        }
        return d
    }

    /// The request's JSON body. `kind` names what it is for (`StepParameters.bodyParameters`): a
    /// name the body doesn't have a place for is refused, not passed over.
    private static func json(_ r: AgentAPI.Request, _ kind: String) throws -> [String: Any] {
        if r.body.isEmpty { return [:] }
        guard let obj = try? JSONSerialization.jsonObject(with: r.body) as? [String: Any] else {
            throw APIError.badRequest("The body isn't a JSON object.")
        }
        if let allowed = StepParameters.bodyParameters[kind], let message = StepParameters.strayMessage(obj.keys, allowed: allowed, what: "The body of \(r.method) \(r.path)") {
            throw APIError.badRequest(message)
        }
        return obj
    }

    private static func createDocument(_ r: AgentAPI.Request) async throws -> Response {
        let type = (r.headers["content-type"] ?? "").lowercased()
        var state: DocumentState
        var name = r.query["name"]
        if type.hasPrefix("image/") || type == "application/octet-stream" {
            state = try await documentFromBytes(r.body, name: name ?? "Image")
        } else {
            let obj = try json(r, "documents")
            name = obj["name"] as? String ?? name
            if let b64 = obj["image"] as? String {
                guard let data = Data(base64Encoded: b64, options: .ignoreUnknownCharacters) else {
                    throw APIError.badRequest("\"image\" isn't valid base64.")
                }
                state = try await documentFromBytes(data, name: name ?? "Image")
            } else if let w = obj["width"] as? Int, let h = obj["height"] as? Int {
                guard (1...30_000).contains(w), (1...30_000).contains(h) else {
                    throw APIError.badRequest("width and height must be 1…30000 pixels.")
                }
                if let tooLarge = DocumentLimits.refusal(width: w, height: h) { throw APIError.unprocessable("too_large", tooLarge) }
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
        name = name.map { String($0.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200)) }
        // Glimmer's untouched start document becomes this one, instead of leaving an empty
        // window behind (as opening an image does). Documents the API made are never reused.
        if let blank = AgentRegistry.shared.sessions.first(where: { $0.isUntouchedBlank && !$0.madeByAPI }) {
            blank.replaceUntouched(with: state)
            blank.madeByAPI = true
            if let name, !name.isEmpty { blank.setDocumentName(name) }
            showRequester(r, in: blank)
            #if GLIMMER_PSD
            DocumentOpener.shared.claimImportReport(for: blank)
            #endif
            return .json(["document": detail(blank)], status: 201)
        }
        let marker = state.layers.first?.id
        DocumentOpener.shared.createDocument(state)
        // The window opens asynchronously; wait for its session to register.
        for _ in 0..<100 {
            if let session = AgentRegistry.shared.sessions.first(where: { $0.state.layers.first?.id == marker }) {
                session.madeByAPI = true
                if let name, !name.isEmpty { session.setDocumentName(name) }
                showRequester(r, in: session)
                #if GLIMMER_PSD
                DocumentOpener.shared.claimImportReport(for: session)   // before the answer, so it carries the report
                #endif
                return .json(["document": detail(session)], status: 201)
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw APIError.internalError("The document window didn't open in time.")
    }

    /// A camera's RAW file becomes a RAW layer (developed away from the main thread); everything else as before.
    private static func documentFromBytes(_ data: Data, name: String) async throws -> DocumentState {
        #if GLIMMER_RAW
        // By what the bytes are, or, for a camera file the system's reader doesn't know at all, by the name it was sent with.
        if DocumentOpener.isRawData(data) || DocumentOpener.isRawFile(URL(fileURLWithPath: name)) {
            // The size is read from the header first: a file too large for this Mac is refused before anything is decoded.
            do { _ = try RawDevelopment.info(data) } catch let problem as RawDevelopment.Problem {
                throw APIError.unprocessable(problem.tooLarge ? "too_large" : "raw_not_developed", problem.message)
            }
            do {
                let made = try await Task.detached(priority: .userInitiated) { try RawLayer.make(from: data, fileName: name) }.value
                return DocumentState(width: made.width, height: made.height, layers: [made.layer])
            } catch {
                throw APIError.unprocessable("raw_not_developed", (error as? LocalizedError)?.errorDescription ?? "macOS gives no picture for this RAW file.")
            }
        }
        #endif
        return try documentFromImage(data, name: name)
    }

    private static func documentFromImage(_ data: Data, name: String) throws -> DocumentState {
        guard !data.isEmpty else { throw APIError.badRequest("The image body is empty.") }
        // A Photoshop file comes in with its layers; what did not come through is in the answer ("importReport").
        #if GLIMMER_PSD
        if DocumentOpener.isPhotoshopFile(data) {
            do {
                return try DocumentOpener.shared.importPhotoshopFile(data)
            } catch {
                throw APIError.badRequest((error as? LocalizedError)?.errorDescription ?? "Glimmer couldn't read this Photoshop file.")
            }
        }
        #endif
        do {
            let image = try ImageImporter.image(from: data)
            let tiles = try ImageImporter.tiles(from: image)
            return DocumentState(width: image.width, height: image.height, layers: [Layer(name: name, content: .raster(tiles))])
        } catch let error as ImageImportError {
            throw APIError.badRequest(imageRefusal(error))
        } catch {
            throw APIError.badRequest(imageRefusal(.unreadable))
        }
    }

    /// Why an image wasn't opened, for an agent: what was wrong and what to send instead.
    static func imageRefusal(_ error: ImageImportError) -> String {
        switch error {
        case .tooLarge: AgentAPI.words(for: error) + " Send a smaller image."
        case .damaged: AgentAPI.words(for: error) + " Send the whole file."
        case .unreadable: "Glimmer couldn't read this as an image. Send PNG, JPEG, HEIC, TIFF or WebP bytes."
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
        let obj = try json(r, "export")
        if let preset = obj["preset"] {
            guard preset as? String == "podcast-cover" else { throw APIError.badRequest("preset must be \"podcast-cover\".") }
            return try await podcastCover(session, obj)
        }
        #if GLIMMER_PSD
        // A Photoshop file with the layers. What is not written as it is comes back in a header, as JSON.
        if (obj["format"] as? String)?.lowercased() == "psd" {
            guard let metal = MetalContext.shared else { throw APIError.internalError("No Metal GPU available.") }
            let depth = obj["depth"] as? Int ?? 8
            guard depth == 8 || depth == 16 else { throw APIError.badRequest("depth must be 8 or 16.") }
            let flattened = obj["flatten"] as? Bool ?? false
            let snapshot = session.state
            let result: (data: Data, report: PSDExportReport)
            do {
                result = try await Task.detached(priority: .userInitiated) { try PSDExport.data(for: snapshot, depth: depth, flattened: flattened, context: metal) }.value
            } catch let problem as PSDFile.Problem {
                throw APIError.unprocessable("cannot_export", problem.message)
            }
            var report: [String: Any] = ["layersWritten": result.report.layersWritten,
                                         "notes": result.report.notes.map { ["layer": $0.layer ?? NSNull(), "kind": $0.kind.rawValue, "what": $0.what, "changesLook": $0.changesLook] as [String: Any] }]
            if let d = result.report.gammaDifference { report["layersBlendedInGamma"] = ["mean": d.mean, "shareVisiblyDifferent": d.shareVisible] }
            let header = (try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
            // Header values are ASCII: anything else is written as \u escapes, which JSON readers take back.
            let ascii = header.unicodeScalars.map { $0.isASCII ? String($0) : String(format: "\\u%04x", $0.value) }.joined()
            return Response(status: 200, contentType: "image/vnd.adobe.photoshop", body: result.data, extraHeaders: ["X-Glimmer-Export-Report": ascii])
        }
        #endif
        var options = ExportOptions(format: try format(obj["format"] as? String))
        if let q = obj["quality"] as? Double {
            guard (0.05...1).contains(q) else { throw APIError.badRequest("quality must be 0.05…1.") }
            options.quality = q
        }
        if let side = obj["maxSide"] as? Int { options.maxPixelSide = max(16, side) }
        if let bytes = obj["maxBytes"] as? Int { options.maxBytes = max(1_000, bytes) }
        return try await render(session, options: options)
    }

    /// Square cover art in the sizes podcast directories take: the centre square of the
    /// image at exactly 3000 or 1400 pixels, JPEG or PNG, opaque, under `maxBytes`. Without
    /// a `size`, 3000 falls back to 1400 when 3000 can't meet the byte limit.
    private static func podcastCover(_ session: EditorSession, _ obj: [String: Any]) async throws -> Response {
        let format = try format(obj["format"] as? String ?? "jpeg")
        guard format == .jpeg || format == .png else { throw APIError.badRequest("A podcast cover is jpeg or png.") }
        let size = obj["size"] as? Int
        if let size, ![1400, 3000].contains(size) { throw APIError.badRequest("size must be 3000 or 1400.") }
        var options = ExportOptions(format: format, quality: 0.92)
        if let q = obj["quality"] as? Double {
            guard (0.05...1).contains(q) else { throw APIError.badRequest("quality must be 0.05…1.") }
            options.quality = q
        }
        if let bytes = obj["maxBytes"] as? Int {
            guard bytes >= 1_000 else { throw APIError.badRequest("maxBytes must be at least 1000.") }
            options.maxBytes = bytes
        }
        guard let metal = MetalContext.shared else { throw APIError.internalError("No Metal GPU available.") }
        let snapshot = session.state
        let sides = size.map { [$0] } ?? [3000, 1400]
        let opts = options
        do {
            let data = try await Task.detached(priority: .userInitiated) { () throws -> Data in
                let flat = try ImageExporter.flatten(snapshot, context: metal)
                var lastError: Error?
                for side in sides {
                    do {
                        return try ImageExporter.encode(try ImageExporter.squareCover(flat, side: side, background: SIMD3(1, 1, 1)),
                                                        options: opts, keepSize: true)
                    } catch let e as ExportLimitError { lastError = e }
                }
                throw lastError ?? ExportLimitError(smallest: 0, limit: opts.maxBytes ?? 0)
            }.value
            return Response(status: 200, contentType: format.contentType.preferredMIMEType ?? "application/octet-stream", body: data)
        } catch let e as ExportLimitError {
            let hint = format == .png ? " Try jpeg." : (size == 3000 ? " Try size 1400." : "")
            throw APIError.unprocessable("over_byte_limit", "The cover can't get under \(e.limit) bytes: the smallest is \(e.smallest) bytes.\(hint)")
        }
    }

    // MARK: Editing

    /// "Requested by Flimmer" over the canvas, when a sibling app makes the change.
    private static func showRequester(_ r: AgentAPI.Request, in session: EditorSession) {
        guard let sibling = AgentAPI.sibling(r) else { return }
        session.showToast(String(localized: "Requested by \(sibling)"))
    }

    /// `add_image`: the body's image becomes a new layer, one undo step of its own.
    private static func addImage(_ session: EditorSession, _ r: AgentAPI.Request) throws -> Response {
        let type = (r.headers["content-type"] ?? "").lowercased()
        // An app sends the image's bytes; an assistant, which has none, names an open document.
        var source: EditorSession?
        if !(type.hasPrefix("image/") || type == "application/octet-stream") {
            guard let key = try json(r, "layers")["fromDocument"] as? String, !key.isEmpty else {
                throw APIError.badRequest("Send the image's bytes with Content-Type: image/…, or JSON {\"fromDocument\": \"<document id>\"}. The options go in the query.")
            }
            guard let other = AgentRegistry.shared.session(key) else {
                throw APIError.unprocessable("unknown_document", "No open document with id \(key). GET /api/v1/documents lists them.")
            }
            guard other !== session else {
                throw APIError.unprocessable("same_document", "fromDocument is this document. Name another open document.")
            }
            source = other
        }
        let fitName = r.query["fit"] ?? "contain"
        guard let fit = CanvasSteps.Fit(rawValue: fitName) else { throw APIError.badRequest("fit must be contain, cover or none.") }
        func number(_ key: String) throws -> Double? {
            guard let text = r.query[key] else { return nil }
            guard let v = Double(text), v.isFinite, abs(v) <= 1e6 else { throw APIError.badRequest("\(key) must be a number.") }
            return v
        }
        let x = try number("x"), y = try number("y")
        let smart: Bool
        switch r.query["smartObject"] ?? "true" {
        case "true", "1": smart = true
        case "false", "0": smart = false
        default: throw APIError.badRequest("smartObject must be true or false.")
        }
        let image: CGImage
        if let source {
            do {
                image = try ImageExporter.flattenedSRGB(source.state, context: source.ai.metal)
            } catch {
                throw APIError.internalError(AgentAPI.words(for: error))
            }
        } else {
            guard !r.body.isEmpty else { throw APIError.unprocessable("bad_image", "The image body is empty.") }
            do {
                image = try ImageImporter.image(from: r.body)
            } catch ImageImportError.tooLarge(let w, let h) {
                throw APIError.unprocessable("too_large", imageRefusal(.tooLarge(w, h)))
            } catch let error as ImageImportError {
                throw APIError.unprocessable("bad_image", imageRefusal(error))
            } catch {
                throw APIError.unprocessable("bad_image", imageRefusal(.unreadable))
            }
        }
        guard image.width <= CanvasSteps.maxSide, image.height <= CanvasSteps.maxSide else {
            throw APIError.unprocessable("too_large", "The image is \(image.width) × \(image.height); the most is \(CanvasSteps.maxSide) pixels a side.")
        }
        let name = (r.query["name"]?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : String($0.prefix(200)) }
        let layer: Layer
        do {
            layer = try session.addImageLayer(image, name: name ?? source.flatMap { $0.explicitName ?? $0.state.layers.first?.name } ?? String(localized: "Image"), fit: fit, x: x, y: y, smartObject: smart)
        } catch {
            throw APIError.internalError(AgentAPI.words(for: error))
        }
        showRequester(r, in: session)
        var info: [String: Any] = ["id": layer.id.uuidString, "name": layer.name]
        if let b = layerBounds(layer) { info["bounds"] = ["x": b.x, "y": b.y, "width": b.width, "height": b.height] }
        return .json(["layer": info, "document": detail(session)], status: 201)
    }

    private static func steps(_ session: EditorSession, _ r: AgentAPI.Request) async throws -> Response {
        let obj = try json(r, "steps")
        guard let raw = obj["steps"] as? [Any], !raw.isEmpty else {
            throw APIError.badRequest("Send {\"steps\": [{\"op\": \"…\", \"params\": {…}}]}. GET /api/v1/operations lists the ops.")
        }
        let allowPaid = obj["allowPaid"] as? Bool ?? false
        // Said on every call, never remembered: `allowPaid` alone does not mean "whatever it costs".
        let allowUnknownPrice = obj[PaidPrice.consentParameter] as? Bool ?? false
        var steps: [AgentStep] = []
        for (i, item) in raw.enumerated() {
            guard var step = item as? [String: Any], let op = step["op"] as? String else {
                throw APIError.badRequest("Step \(i) needs an \"op\".")
            }
            guard AgentPlanner.op(named: op) != nil else {
                throw APIError(404, "not_found", "Step \(i): unknown op \"\(op)\". GET /api/v1/operations lists them.")
            }
            // A step's own names: a setting put beside "op" instead of inside "params" would otherwise vanish.
            if let message = StepParameters.strayMessage(step.keys, allowed: StepParameters.bodyParameters["step"]!, what: "Step \(i)") {
                throw APIError.badRequest(message + " An operation's settings go inside \"params\". No step of this request was run.")
            }
            if step["params"] == nil { step["params"] = [String: Any]() }
            guard JSONSerialization.isValidJSONObject(step),
                  let data = try? JSONSerialization.data(withJSONObject: step),
                  let decoded = try? JSONDecoder().decode(AgentStep.self, from: data) else {
                throw APIError.badRequest("Step \(i): \"params\" must be an object.")
            }
            // The unknown name first: "crop needs width…" would hide that "widht" was the trouble.
            if let stray = StepParameters.stray(in: decoded) { throw APIError.badRequest("Step \(i): \(stray.message) No step of this request was run.") }
            if let problem = CanvasSteps.malformed(decoded) { throw APIError.badRequest("Step \(i): \(problem)") }
            // A step that needs a model not on this Mac: refused before anything runs, never downloaded.
            if let ids = Requirement.models(forOp: op, command: decoded.string("id")) {
                let missing = ids.filter { id in OnDeviceModel.with(requirement: id).map { !ModelStore.shared.isInstalled($0) } ?? false }
                if !missing.isEmpty { throw APIError.modelMissing(step: i, op: op, ids: missing) }
            }
            if AgentAPI.paidOps.contains(op) {
                // The picture service chosen in Glimmer's Settings: said by name, since that is where the picture goes.
                let service = AIController.imageProvider
                guard allowPaid else {
                    throw APIError(402, "paid_not_allowed", "Step \(i) (\(op)) calls \(service.name) and costs money. Pass \"allowPaid\": true to allow it. No step of this request was run.")
                }
                guard AIController.hasImageKey else {
                    throw APIError(402, "paid_not_allowed", "Step \(i) (\(op)) needs a key for \(service.name), the picture service chosen in Glimmer, and none is saved in Glimmer › Settings. No step of this request was run.")
                }
                guard PaidPrice.known(op: op, service: service.slug) != nil || allowUnknownPrice else {
                    throw APIError.unprocessable(PaidPrice.reason, "Step \(i) (\(op)) is paid, and Glimmer does not know its price in advance: \(service.name) states none. Pass \"allowUnknownPrice\": true as well to run it without knowing the price. No step of this request was run.")
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
                let results = await session.ai.runAPISteps(steps, allowUnknownPrice: allowUnknownPrice) { done in job.progress = Double(done) / total }
                job.result = ["results": stepList(results), "document": detail(session)]
                if let failed = results.firstIndex(where: { $0.status == "failed" }) {
                    job.status = "failed"
                    job.error = stepFailure(results, failed)
                } else if results.contains(where: { $0.status == "canceled" }) {
                    job.status = "canceled"
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
            return .json(["error": stepFailure(results, failed), "results": list, "document": detail(session)], status: 422)
        }
        return .json(["results": list, "document": detail(session)])
    }

    /// One item of `GET /api/v1/requirements`: the register's entry, and whether it is on this Mac.
    static func requirementJSON(_ r: Requirement) -> [String: Any] {
        if let model = OnDeviceModel.with(requirement: r.id) {
            let installed = ModelStore.shared.isInstalled(model)
            return r.json(installed: installed, installedVersion: installed ? r.source.commit : nil)
        }
        // A tool the person installs: Glimmer doesn't look for it, so it doesn't say.
        return r.json(installed: nil, installedVersion: nil)
    }

    /// Present or missing per offered service that needs a key.
    static func providerKeys() -> [String: Bool] {
        var status = ProviderKeys.keychain.status()
        // A debug copy may get OpenRouter's key from its environment instead of the keychain.
        status["openrouter"] = ((try? AIController.apiKey()) ?? nil) != nil
        return status
    }

    /// What waits to be saved back, and how the document came to be open: `recovered` after a stop (a crash, a kill),
    /// `kept` when the person left it knowingly (Quit, or Keep for Later). Both go when the edits are saved back.
    private static func addWaiting(_ session: EditorSession, to d: inout [String: Any]) {
        if session.hasUnreturnedEdits { d["unreturnedSteps"] = session.unreturnedSteps }
        if session.recovered { d[session.keptFromLastTime ? "kept" : "recovered"] = true }
    }

    /// `linkedFile` of a document: the file it saves back to. `available` is false when the
    /// document was linked before a restart and the file can no longer be reached or written.
    static func linkedFile(_ session: EditorSession) -> [String: Any]? {
        if let link = session.linkedImage {
            var d: [String: Any] = ["name": link.fileName, "format": link.format.rawValue, "requester": link.requester, "available": true]
            Self.addWaiting(session, to: &d)
            return d
        }
        if let broken = session.brokenLink {
            // The reason in English: the window's own sentence (`broken.reason`) is in the person's language.
            var d: [String: Any] = ["name": broken.link.fileName, "requester": broken.link.requester, "available": false,
                                    "reason": EditorSession.linkTroubleForAgent(path: broken.link.path, name: broken.link.fileName, requester: broken.link.requester)]
            Self.addWaiting(session, to: &d)
            if let format = LinkedImage.format(for: URL(fileURLWithPath: broken.link.path)) { d["format"] = format.rawValue }
            return d
        }
        return nil
    }

    /// A failed step: always `step_failed`, with a `reason` when the step refused for a known reason.
    private static func stepFailure(_ results: [AIController.APIStepResult], _ failed: Int) -> [String: Any] {
        var body = AgentAPI.APIError.stepFailedBody(step: failed, op: results[failed].op, message: results[failed].error ?? "",
                                                    reason: results[failed].reason)
        if results[failed].hard { body["hard"] = true }
        if let ids = results[failed].requirements, let first = ids.first { body["requirement"] = first; body["requirements"] = ids }
        return body
    }

    private static func stepList(_ results: [AIController.APIStepResult]) -> [[String: Any]] {
        results.enumerated().map { i, res in
            var d: [String: Any] = ["index": i, "op": res.op, "status": res.status]
            if let e = res.error { d["error"] = e }
            if let info = res.info { d["info"] = info }
            return d
        }
    }

    private static func undoRedo(_ session: EditorSession, redo: Bool) throws -> Response {
        guard let undo = session.undoManager else { throw APIError.unprocessable("no_history", "The document has no undo history yet.") }
        if redo {
            guard undo.canRedo else { throw APIError.unprocessable("nothing_to_redo", "Nothing to redo.") }
            let name = GlimmerDocument.englishActionNames[undo.redoActionName] ?? undo.redoActionName
            undo.redo()
            return .json(["redone": name, "document": detail(session)])
        }
        guard undo.canUndo else { throw APIError.unprocessable("nothing_to_undo", "Nothing to undo.") }
        let name = GlimmerDocument.englishActionNames[undo.undoActionName] ?? undo.undoActionName
        undo.undo()
        return .json(["undone": name, "document": detail(session)])
    }
}
