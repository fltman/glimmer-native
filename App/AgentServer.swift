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
            return .json(["app": ["name": "Glimmer", "version": appVersion, "bundleID": AppIdentity.ownBundleID],
                          "api": AgentAPI.version, "port": Int(port),
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
            case ["layers"]:
                try only("POST")
                return try addImage(session, r)
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
                "linkedFile": session.linkedImage.map { ["name": $0.fileName, "format": $0.format.rawValue, "requester": $0.requester] } as Any? ?? NSNull()]
    }

    static func detail(_ session: EditorSession) -> [String: Any] {
        var d = summary(session)
        let st = session.state
        d["layers"] = st.layers.reversed().map(describe)
        d["activeLayer"] = st.activeLayer.map { ["id": $0.id.uuidString, "name": $0.name] } ?? NSNull()
        if let sel = st.selection?.bounds(in: st.bounds) { d["selectionBounds"] = ["x": sel.x, "y": sel.y, "width": sel.width, "height": sel.height] }
        return d
    }

    /// The tight bounds of a pixel layer's visible content (tile bounds are up to a tile too
    /// big on each side). Kept per layer until its pixels change.
    private static var boundsCache: [UUID: (signature: Int, bounds: PixelRect?)] = [:]
    private static func contentBounds(_ grid: TileGrid, id: UUID) -> PixelRect? {
        let signature = grid.contentSignature.hashValue
        if let hit = boundsCache[id], hit.signature == signature { return hit.bounds }
        let bounds = grid.tileBounds.flatMap { Selection(tiles: grid.mapAlphaOnly()).bounds(in: $0) }
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
        var name = r.query["name"]
        if type.hasPrefix("image/") || type == "application/octet-stream" {
            state = try documentFromImage(r.body, name: name ?? "Image")
        } else {
            let obj = try json(r)
            name = obj["name"] as? String ?? name
            if let b64 = obj["image"] as? String {
                guard let data = Data(base64Encoded: b64, options: .ignoreUnknownCharacters) else {
                    throw APIError.badRequest("\"image\" isn't valid base64.")
                }
                state = try documentFromImage(data, name: name ?? "Image")
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
        } catch let error as ImageImportError {
            throw APIError.badRequest(imageRefusal(error))
        } catch {
            throw APIError.badRequest(imageRefusal(.unreadable))
        }
    }

    /// Why an image wasn't opened, for an agent: what was wrong and what to send instead.
    static func imageRefusal(_ error: ImageImportError) -> String {
        switch error {
        case .tooLarge: error.localizedDescription + " Send a smaller image."
        case .damaged: error.localizedDescription + " Send the whole file."
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
        let obj = try json(r)
        if let preset = obj["preset"] {
            guard preset as? String == "podcast-cover" else { throw APIError.badRequest("preset must be \"podcast-cover\".") }
            return try await podcastCover(session, obj)
        }
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
            guard let key = (try? json(r))?["fromDocument"] as? String, !key.isEmpty else {
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
                throw APIError.internalError(error.localizedDescription)
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
            throw APIError.internalError(error.localizedDescription)
        }
        showRequester(r, in: session)
        var info: [String: Any] = ["id": layer.id.uuidString, "name": layer.name]
        if let b = layerBounds(layer) { info["bounds"] = ["x": b.x, "y": b.y, "width": b.width, "height": b.height] }
        return .json(["layer": info, "document": detail(session)], status: 201)
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
            if let problem = CanvasSteps.malformed(decoded) { throw APIError.badRequest("Step \(i): \(problem)") }
            if AgentAPI.paidOps.contains(op) {
                guard allowPaid else {
                    throw APIError(402, "paid_not_allowed", "Step \(i) (\(op)) calls OpenRouter and costs money. Pass \"allowPaid\": true to allow it. No step of this request was run.")
                }
                guard session.ai.hasAPIKey else {
                    throw APIError(402, "paid_not_allowed", "Step \(i) (\(op)) needs an OpenRouter key, and none is saved in Glimmer › Settings. No step of this request was run.")
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
                    job.error = stepFailure(results, failed)
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
            return .json(["error": stepFailure(results, failed), "results": list, "document": detail(session)], status: 422)
        }
        return .json(["results": list, "document": detail(session)])
    }

    /// A failed step: always `step_failed`, with a `reason` when the step refused for a known reason.
    private static func stepFailure(_ results: [AIController.APIStepResult], _ failed: Int) -> [String: Any] {
        AgentAPI.APIError.stepFailedBody(step: failed, op: results[failed].op, message: results[failed].error ?? "",
                                         reason: results[failed].reason)
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
            let name = undo.redoActionName
            undo.redo()
            return .json(["redone": name, "document": detail(session)])
        }
        guard undo.canUndo else { throw APIError.unprocessable("nothing_to_undo", "Nothing to undo.") }
        let name = undo.undoActionName
        undo.undo()
        return .json(["undone": name, "document": detail(session)])
    }
}
