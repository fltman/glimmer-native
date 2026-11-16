import Foundation
import GlimmerCore

// The series' sibling protocol (the-apps/SIBLINGS.md): Glimmer's assistant asks
// Flimmer and Jämmer for things through their local agent APIs, exactly like an
// outside agent, with `X-Sibling: glimmer`. Everything stays on 127.0.0.1.

/// Which build this is. Debug builds carry `.debug` on their bundle id and talk to the
/// siblings' debug builds (series rule), so tests never reach the real apps.
public enum AppIdentity {
    public static let ownBundleID = Bundle.main.bundleIdentifier ?? "com.brattoo.glimmer"
    public static var isDebugBuild: Bool { isDebug(ownBundleID) }
    /// A debug build, or its guest copy for a visiting test (`.debug.guest`, SIBLINGS.md §1: a copy with a container of its own).
    public static func isDebug(_ bundleID: String) -> Bool { bundleID.hasSuffix(".debug") || bundleID.hasSuffix(".debug.guest") }
    /// Glimmer's own id in this build (com.brattoo.glimmer or com.brattoo.glimmer.debug).
    public static var glimmerBundleID: String { "com.brattoo.glimmer" + (isDebugBuild ? ".debug" : "") }
}

/// A sibling app Glimmer can ask for things.
public enum SiblingApp: String, CaseIterable, Sendable {
    case flimmer, jammer

    /// `app.name` in its `GET /api/v1/status`; a port counts only when this matches exactly.
    public var appName: String { self == .jammer ? "Jammer" : "Flimmer" }
    public var displayName: String { self == .jammer ? "Jämmer" : "Flimmer" }
    /// The sibling's id in this kind of build: debug builds pair with debug builds.
    public var bundleID: String { bundleID(debug: AppIdentity.isDebugBuild) }
    public func bundleID(debug: Bool) -> String { "com.brattoo.\(rawValue)" + (debug ? ".debug" : "") }

    /// Whether a running app with this bundle id is this sibling, for a build of this kind. A debug
    /// build also accepts the sibling's guest copy (`….debug.guest`); a release build never does.
    public func accepts(bundleID id: String?, debug: Bool = AppIdentity.isDebugBuild) -> Bool {
        guard let id else { return false }
        return id == bundleID(debug: debug) || (debug && id == bundleID(debug: true) + ".guest")
    }

    /// Which copy to open when several are installed (SIBLINGS.md §1): the highest
    /// CFBundleVersion (compared as numbers), then /Applications on a tie, then the most
    /// recently built. Version first: a stale copy elsewhere once won and broke a cold start.
    /// (A running copy is used before any of these.)
    public static func bestCopy(_ copies: [(path: String, build: String, modified: Date)]) -> Int? {
        func build(_ s: String) -> [Int] { s.split(separator: ".").map { Int($0) ?? 0 } }
        func compare(_ a: [Int], _ b: [Int]) -> Int {  // numeric, missing parts count as 0
            for i in 0..<max(a.count, b.count) {
                let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
                if x != y { return x < y ? -1 : 1 }
            }
            return 0
        }
        return copies.indices.max { a, b in
            let c = compare(build(copies[a].build), build(copies[b].build))
            if c != 0 { return c < 0 }
            let inApps = (copies[a].path.hasPrefix("/Applications/"), copies[b].path.hasPrefix("/Applications/"))
            if inApps.0 != inApps.1 { return !inApps.0 }
            return copies[a].modified < copies[b].modified
        }
    }
    /// The header every request that isn't a GET must carry.
    public var agentHeader: String { "X-\(appName)-Agent" }
    /// First port, then the reserved range (SIBLINGS.md §1).
    public var ports: [Int] { self == .jammer ? [9003] + Array(9301...9319) : [9002] + Array(9201...9219) }
    /// What the app is, for the assistant.
    var role: String { self == .jammer ? "audio editor" : "video editor" }

    /// The sibling a tool name like `jammer_gain` belongs to, and the op name.
    public static func split(tool: String) -> (app: SiblingApp, op: String)? {
        for app in allCases where tool.hasPrefix(app.rawValue + "_") {
            let op = String(tool.dropFirst(app.rawValue.count + 1))
            return op.isEmpty ? nil : (app, op)
        }
        return nil
    }
}

/// One entry of a sibling's `GET /api/v1/operations`.
public struct SiblingOperation: Sendable, Equatable {
    public var app: SiblingApp
    public var name: String
    public var description: String
    /// JSON Schema; properties may carry `"x-in": "path"|"query"`.
    public var params: JSONValue
    public var paid: Bool
    public var undoable: Bool
    public var startsJob: Bool
    /// Set for requests that aren't steps; steps go through `/steps`.
    public var call: Call?

    public struct Call: Sendable, Equatable {
        public var method: String
        public var path: String
    }

    /// Provider tool names allow only `^[a-zA-Z0-9_-]{1,64}$`.
    public var toolName: String { "\(app.rawValue)_\(name)" }

    public init(app: SiblingApp, name: String, description: String, params: JSONValue = .object([:]),
                paid: Bool = false, undoable: Bool = true, startsJob: Bool = false, call: Call? = nil) {
        self.app = app
        self.name = name
        self.description = description
        self.params = params
        self.paid = paid
        self.undoable = undoable
        self.startsJob = startsJob
        self.call = call
    }

    /// Parses a sibling's operation list, skipping malformed entries.
    public static func parse(_ data: Data, app: SiblingApp) -> [SiblingOperation] {
        guard let root = try? JSONDecoder().decode([String: JSONValue].self, from: data),
              case .array(let list)? = root["operations"] else { return [] }
        return list.compactMap { value in
            guard let o = value.object, let name = o["name"]?.string,
                  name.range(of: "^[a-zA-Z0-9_-]{1,40}$", options: .regularExpression) != nil else { return nil }
            var call: Call?
            if let c = o["call"]?.object, let method = c["method"]?.string, let path = c["path"]?.string, path.hasPrefix("/api/") {
                call = Call(method: method.uppercased(), path: path)
            }
            return SiblingOperation(app: app, name: name, description: o["description"]?.string ?? "",
                                    params: o["params"] ?? .object([:]), paid: o["paid"]?.bool ?? false,
                                    undoable: o["undoable"]?.bool ?? true, startsJob: o["startsJob"]?.bool ?? false, call: call)
        }
    }

    /// A name in `params` that the sibling's schema doesn't have, when that schema is closed
    /// (`"additionalProperties": false`, SIBLINGS.md §3): the sibling would refuse the call, so
    /// Glimmer refuses first, with the same words, and sends nothing. Nil when every name is
    /// known, or when the sibling's schema is open (an older sibling: it decides for itself).
    /// `document` and `rationale` are Glimmer's own additions to the tool and are taken out before this.
    public func stray(in params: [String: JSONValue]) -> (name: String, allowed: [String])? {
        guard let schema = self.params.object, schema["additionalProperties"]?.bool == false, let properties = schema["properties"]?.object else { return nil }
        if let name = params.keys.sorted().first(where: { properties[$0] == nil }) {
            return (name, properties.keys.filter { $0 != "rationale" }.sorted())
        }
        // Settings that depend on a sort (SIBLINGS.md §3, as settled 2026-11-16): a table "x-byType"
        // on the schema object whose properties depend on the sort, with the chooser named beside
        // it in "x-byTypeKey". The table's keys are the chooser's values, each a closed schema.
        // 1. On the operation's own schema: the sort's properties are top-level, beside the chooser.
        if let table = schema["x-byType"]?.object, let chooser = schema["x-byTypeKey"]?.string,
           let sort = params[chooser]?.string, let own = table[sort]?.object?["properties"]?.object {
            // Every name some sort has; one that belongs to another sort than the chosen one is refused.
            var dependent: Set<String> = []
            for other in table.values { dependent.formUnion((other.object?["properties"]?.object ?? [:]).keys) }
            if let name = params.keys.sorted().first(where: { dependent.contains($0) && own[$0] == nil }) {
                // What this sort does take: its own settings and everything that belongs to no sort.
                let valid = properties.keys.filter { $0 != "rationale" && (!dependent.contains($0) || own[$0] != nil) }
                return ("\(name) for \(sort)", valid.sorted())
            }
        }
        // 2. On a nested settings property: the settings are an object of their own.
        for (carrier, nestedSchema) in properties.sorted(by: { $0.key < $1.key }) {
            guard let table = nestedSchema.object?["x-byType"]?.object, let chooser = nestedSchema.object?["x-byTypeKey"]?.string,
                  let given = params[carrier]?.object, let sort = params[chooser]?.string, let nested = table[sort]?.object,
                  nested["additionalProperties"]?.bool == false, let allowed = nested["properties"]?.object else { continue }
            if let name = given.keys.sorted().first(where: { allowed[$0] == nil }) {
                return ("\(name) in \(carrier)", allowed.keys.sorted())
            }
        }
        return nil
    }

    /// A table of settings per sort that doesn't name its chooser ("x-byTypeKey"): Glimmer does
    /// not guess which property chooses, so those settings go unchecked, and the plan says so.
    /// Returns where the table is ("the step" or the property's name), or nil.
    public func uncheckedTable(for params: [String: JSONValue]) -> String? {
        guard let schema = self.params.object else { return nil }
        if schema["x-byType"] != nil, schema["x-byTypeKey"]?.string == nil { return "the step" }
        for (carrier, nested) in (schema["properties"]?.object ?? [:]).sorted(by: { $0.key < $1.key }) where params[carrier] != nil {
            if nested.object?["x-byType"] != nil, nested.object?["x-byTypeKey"]?.string == nil { return carrier }
        }
        return nil
    }

    /// The function tool for the assistant: the sibling's description and schema as they
    /// are, minus the `x-in` markers, plus `document` when the op doesn't name one itself.
    public var toolSchema: [String: Any] {
        var schema = (params.any as? [String: Any]) ?? [:]
        var properties = (schema["properties"] as? [String: Any]) ?? [:]
        for (key, value) in properties {
            if var p = value as? [String: Any] { p.removeValue(forKey: "x-in"); properties[key] = p }
        }
        if properties["id"] == nil {
            properties["document"] = ["type": "string",
                                      "description": "Optional. The \(app.displayName) document id or name; default: the one in front."]
        }
        properties["rationale"] = ["type": "string", "description": "One short sentence: why this step."]
        schema["type"] = "object"
        schema["properties"] = properties
        if schema["required"] == nil { schema["required"] = [String]() }
        var text = "In \(app.displayName) (the \(app.role), a separate app): \(description)"
        if startsJob { text += " Takes a while." }
        return ["type": "function", "function": ["name": toolName, "description": text, "parameters": schema]]
    }
}

/// An open document in a sibling.
public struct SiblingDocument: Sendable, Equatable {
    public var id: String
    public var name: String
    public var duration: Double?
    /// The document in the sibling's front window, when the sibling says so.
    public var frontmost = false
}

public enum SiblingError: Error, LocalizedError, Equatable {
    case notRunning(SiblingApp)
    case noDocument(SiblingApp, String?)
    case unknownOperation(String)
    case paid(String)
    case failed(SiblingApp, String)
    /// The step carries a name the sibling's operation doesn't have; nothing was sent.
    case strayParameter(String, String, [String])

    public var errorDescription: String? {
        switch self {
        case .strayParameter(let tool, let name, let allowed):
            allowed.isEmpty ? String(localized: "\(tool) has no parameter named \(name). It takes none.")
                            : String(localized: "\(tool) has no parameter named \(name). It has: \(allowed.joined(separator: ", ")).")
        case .notRunning(let app): String(localized: "\(app.displayName) is not running.")
        case .noDocument(let app, let key?): String(localized: "\(app.displayName) has no open document “\(key)”.")
        case .noDocument(let app, nil): String(localized: "\(app.displayName) has no open document.")
        case .unknownOperation(let name): String(localized: "Unknown step “\(name)”.")
        case .paid(let name): String(localized: "“\(name)” costs money in the other app, so Glimmer doesn't ask for it.")
        case .failed(let app, let message): "\(app.displayName): \(message)"
        }
    }
}

/// Waveform columns from a sibling, reduced to one amplitude per column (0…1).
public struct SiblingWaveform: Sendable, Equatable {
    public var amplitudes: [Double]
    public var documentName: String

    /// Jämmer's `{"waveform": {"tracks": [{"channels": [[[min, max], …]]}]}}`: the loudest
    /// track and channel per column.
    public static func parse(_ data: Data, documentName: String) -> SiblingWaveform? {
        guard let root = try? JSONDecoder().decode([String: JSONValue].self, from: data),
              case .array(let tracks)? = root["waveform"]?.object?["tracks"] else { return nil }
        var amps: [Double] = []
        for track in tracks {
            guard case .array(let channels)? = track.object?["channels"] else { continue }
            for channel in channels {
                guard case .array(let columns) = channel else { continue }
                if amps.count < columns.count { amps += Array(repeating: 0, count: columns.count - amps.count) }
                for (i, column) in columns.enumerated() {
                    guard case .array(let mm) = column, mm.count == 2, let lo = mm[0].number, let hi = mm[1].number else { continue }
                    amps[i] = max(amps[i], min(1, max(abs(lo), abs(hi))))
                }
            }
        }
        return amps.isEmpty ? nil : SiblingWaveform(amplitudes: amps, documentName: documentName)
    }

    public enum Style: String, CaseIterable, Sendable { case bars, wave }

    /// The waveform as a closed vector path filling `rect` (y grows downward), mirrored
    /// around its middle and scaled so the loudest column reaches the edges. Bars are one
    /// rectangle each; `wave` is a single outline through the column peaks.
    public func path(in rect: CGRectLike, style: Style, gap: Double = 0.35) -> VectorPath {
        let n = amplitudes.count
        let peak = max(amplitudes.max() ?? 0, 1e-6)
        let mid = (rect.minY + rect.maxY) / 2
        let half = (rect.maxY - rect.minY) / 2
        let step = (rect.maxX - rect.minX) / Double(max(n, 1))
        // Quiet columns keep a sliver, so silence still reads as a line.
        func h(_ a: Double) -> Double { max(half * a / peak, min(half, max(1, half * 0.02))) }
        var name = "Waveform"
        if !documentName.isEmpty { name += " – " + documentName }
        switch style {
        case .bars:
            let w = max(1, step * (1 - min(max(gap, 0), 0.9)))
            let subpaths = amplitudes.enumerated().map { i, a -> Subpath in
                let x = rect.minX + Double(i) * step + (step - w) / 2
                let y = h(a)
                return Subpath(anchors: [SIMD2(x, mid - y), SIMD2(x + w, mid - y), SIMD2(x + w, mid + y), SIMD2(x, mid + y)].map { PathAnchor($0) },
                               isClosed: true)
            }
            return VectorPath(name: name, subpaths: subpaths)
        case .wave:
            let xs = (0..<n).map { rect.minX + (Double($0) + 0.5) * step }
            let top = zip(xs, amplitudes).map { SIMD2($0, mid - h($1)) }
            let bottom = zip(xs, amplitudes).reversed().map { SIMD2($0, mid + h($1)) }
            let anchors = [SIMD2(rect.minX, mid)] + top + [SIMD2(rect.maxX, mid)] + bottom
            return VectorPath(name: name, subpaths: [Subpath(anchors: anchors.map { PathAnchor($0) }, isClosed: true)])
        }
    }
}

/// Talks to the siblings. Discovery runs off the main thread with short timeouts; the
/// port is remembered and searched again after the first failure.
public actor SiblingClient {
    public static let shared = SiblingClient()

    private let session: URLSession
    private let portTimeout: TimeInterval
    private var ports: [SiblingApp: Int] = [:]
    private var operationCache: [SiblingApp: (ops: [SiblingOperation], at: Date)] = [:]

    public init(session: URLSession? = nil, portTimeout: TimeInterval = 0.3) {
        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.ephemeral
            config.connectionProxyDictionary = [:]
            config.timeoutIntervalForRequest = 120
            self.session = URLSession(configuration: config)
        }
        self.portTimeout = portTimeout
    }

    // MARK: Discovery

    /// The sibling's port, or nil when it isn't running. The first port is tried first,
    /// then the whole reserved range at once.
    public func port(_ app: SiblingApp) async -> Int? {
        if let p = ports[app] { return p }
        // The first port is where the sibling nearly always is; it gets a longer timeout, since a
        // cold first connection on a busy Mac can take longer than the range's 300 ms.
        if await isSibling(app, port: app.ports[0], timeout: max(portTimeout, 1)) { ports[app] = app.ports[0]; return app.ports[0] }
        let found = await withTaskGroup(of: Int?.self) { group in
            for p in app.ports.dropFirst() { group.addTask { await self.isSibling(app, port: p) ? p : nil } }
            var hits: [Int] = []
            for await hit in group { if let hit { hits.append(hit) } }
            return hits.min()
        }
        if let found { ports[app] = found }
        return found
    }

    private func isSibling(_ app: SiblingApp, port: Int, timeout: TimeInterval? = nil) async -> Bool {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/api/v1/status")!, timeoutInterval: timeout ?? portTimeout)
        request.setValue("glimmer", forHTTPHeaderField: AgentAPI.siblingHeader)
        guard let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let root = try? JSONDecoder().decode([String: JSONValue].self, from: data),
              let info = root["app"]?.object, info["name"]?.string == app.appName else { return false }
        // A sibling that says which build it is must be the matching one (debug with debug).
        if let id = info["bundleID"]?.string { return app.accepts(bundleID: id) }
        return true
    }

    /// Which siblings run right now (searched concurrently).
    public func running() async -> [SiblingApp] {
        await withTaskGroup(of: SiblingApp?.self) { group in
            for app in SiblingApp.allCases { group.addTask { await self.port(app) != nil ? app : nil } }
            var apps: [SiblingApp] = []
            for await app in group { if let app { apps.append(app) } }
            return SiblingApp.allCases.filter(apps.contains)
        }
    }

    // MARK: Requests

    /// One request to a sibling: its agent header, `X-Sibling: glimmer`, no Origin. A
    /// connection failure forgets the port and searches once more.
    func send(_ app: SiblingApp, _ method: String, _ path: String, query: [String: String] = [:],
              body: [String: Any]? = nil, retry: Bool = true) async throws -> (Int, Data) {
        guard let port = await port(app) else { throw SiblingError.notRunning(app) }
        var components = URLComponents(string: "http://127.0.0.1:\(port)\(path)")!
        if !query.isEmpty { components.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) } }
        guard let url = components.url else { throw SiblingError.failed(app, "Bad path \(path).") }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("1", forHTTPHeaderField: app.agentHeader)
        request.setValue("glimmer", forHTTPHeaderField: AgentAPI.siblingHeader)
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        do {
            let (data, response) = try await session.data(for: request)
            return ((response as? HTTPURLResponse)?.statusCode ?? 0, data)
        } catch let error as URLError where retry && error.code != .cancelled {
            ports[app] = nil
            operationCache[app] = nil
            return try await send(app, method, path, query: query, body: body, retry: false)
        } catch let error as URLError where error.code != .cancelled {
            throw SiblingError.notRunning(app)
        }
    }

    /// The sibling's error message from `{"error": {"message": …}}`, or the status code.
    static func message(_ status: Int, _ data: Data) -> String {
        let root = try? JSONDecoder().decode([String: JSONValue].self, from: data)
        return root?["error"]?.object?["message"]?.string ?? "HTTP \(status)"
    }

    /// The sibling's operations, cached for a minute.
    public func operations(_ app: SiblingApp) async throws -> [SiblingOperation] {
        if let cached = operationCache[app], Date().timeIntervalSince(cached.at) < 60 { return cached.ops }
        let (status, data) = try await send(app, "GET", "/api/v1/operations")
        guard status == 200 else { throw SiblingError.failed(app, Self.message(status, data)) }
        let ops = SiblingOperation.parse(data, app: app)
        operationCache[app] = (ops, Date())
        return ops
    }

    public func documents(_ app: SiblingApp) async throws -> [SiblingDocument] {
        let (status, data) = try await send(app, "GET", "/api/v1/documents")
        guard status == 200, let root = try? JSONDecoder().decode([String: JSONValue].self, from: data),
              case .array(let list)? = root["documents"] else { throw SiblingError.failed(app, Self.message(status, data)) }
        return list.compactMap { d in
            guard let o = d.object, let id = o["id"]?.string else { return nil }
            return SiblingDocument(id: id, name: o["name"]?.string ?? "", duration: o["duration"]?.number,
                                   frontmost: o["frontmost"]?.bool ?? false)
        }
    }

    /// The document an op works on: by id or name, else the front one, else the first.
    public func document(_ app: SiblingApp, _ key: String?) async throws -> SiblingDocument {
        let docs = try await documents(app)
        let key = key?.trimmingCharacters(in: .whitespaces)
        if let key, !key.isEmpty {
            if let d = docs.first(where: { $0.id.caseInsensitiveCompare(key) == .orderedSame || $0.name.caseInsensitiveCompare(key) == .orderedSame }) { return d }
            throw SiblingError.noDocument(app, key)
        }
        guard let first = docs.first(where: \.frontmost) ?? docs.first else { throw SiblingError.noDocument(app, nil) }
        return first
    }

    // MARK: Tools

    /// Every free operation of every running sibling, as assistant tools, plus a line for
    /// the editor state naming their open documents. Siblings that don't answer are left out.
    public func toolbox() async -> (tools: [SiblingOperation], context: String?) {
        var tools: [SiblingOperation] = []
        var lines: [String] = []
        for app in await running() {
            guard let ops = try? await operations(app) else { continue }
            tools += ops.filter { !$0.paid }
            let docs = (try? await documents(app)) ?? []
            let list = docs.prefix(20).map { d in
                "“\(d.name)” (id \(d.id)\(d.duration.map { String(format: ", %.1f s", $0) } ?? ""))"
            }.joined(separator: ", ")
            lines.append("\(app.displayName) (\(app.role)) is running" + (docs.isEmpty ? " with no open document" : " with: \(list)"))
        }
        guard !lines.isEmpty else { return (tools, nil) }
        let prefixes = Set(tools.map { $0.app.rawValue + "_" }).sorted().joined(separator: ", ")
        return (tools, "[Sibling apps: " + lines.joined(separator: "; ") + ". Tools starting with \(prefixes) run in those apps; the result stays there.]")
    }

    /// Runs one sibling tool: a step through `/steps` (one undo step there), or a request
    /// with `call`, its params placed by `x-in`. Jobs are followed to the end.
    public func perform(tool: String, params: [String: JSONValue]) async throws -> JSONValue {
        guard let (app, name) = SiblingApp.split(tool: tool) else { throw SiblingError.unknownOperation(tool) }
        guard let op = try await operations(app).first(where: { $0.name == name }) else { throw SiblingError.unknownOperation(tool) }
        guard !op.paid else { throw SiblingError.paid(tool) }
        var params = params
        params.removeValue(forKey: "rationale")
        let key = params.removeValue(forKey: "document")?.string ?? params["id"]?.string
        if let stray = op.stray(in: params) { throw SiblingError.strayParameter(tool, stray.name, stray.allowed) }
        let doc = try await document(app, key)
        let status: Int, data: Data
        if let call = op.call {
            let properties = (op.params.object?["properties"]?.object) ?? [:]
            var path = call.path.replacingOccurrences(of: "{id}", with: doc.id)
            var query: [String: String] = [:]
            var body: [String: Any] = [:]
            for (k, v) in params where k != "id" {
                let place = properties[k]?.object?["x-in"]?.string
                if place == "path" {
                    path = path.replacingOccurrences(of: "{\(k)}", with: v.plainString.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? "")
                } else if place == "query" || call.method == "GET" {
                    query[k] = v.plainString
                } else {
                    body[k] = v.any
                }
            }
            (status, data) = try await send(app, call.method, path, query: query, body: call.method == "GET" ? nil : body)
        } else {
            (status, data) = try await send(app, "POST", "/api/v1/documents/\(doc.id)/steps",
                                            body: ["steps": [["op": name, "params": params.mapValues(\.any)]], "allowPaid": false])
        }
        guard (200..<300).contains(status) else { throw SiblingError.failed(app, Self.message(status, data)) }
        let result = (try? JSONDecoder().decode(JSONValue.self, from: data)) ?? .null
        if status == 202, let id = result.object?["job"]?.object?["id"]?.string { return try await follow(app, job: id) }
        return result
    }

    /// Polls `GET /api/v1/jobs/{id}` until the job is done (SIBLINGS.md §2).
    func follow(_ app: SiblingApp, job id: String, interval: Duration = .milliseconds(500)) async throws -> JSONValue {
        while true {
            try await Task.sleep(for: interval)
            let (status, data) = try await send(app, "GET", "/api/v1/jobs/\(id)")
            guard status == 200, let root = try? JSONDecoder().decode([String: JSONValue].self, from: data),
                  let job = root["job"]?.object else { throw SiblingError.failed(app, Self.message(status, data)) }
            switch job["status"]?.string {
            case "done": return job["result"] ?? .null
            case "failed": throw SiblingError.failed(app, job["error"]?.object?["message"]?.string ?? "The job failed.")
            case "cancelled": throw CancellationError()
            default: continue
            }
        }
    }

    /// The waveform of a sibling's document (`GET …/waveform?width=`), one amplitude per column.
    public func waveform(_ app: SiblingApp, document key: String?, columns: Int) async throws -> SiblingWaveform {
        let doc = try await document(app, key)
        let (status, data) = try await send(app, "GET", "/api/v1/documents/\(doc.id)/waveform",
                                            query: ["width": String(min(max(columns, 8), 4_000))])
        guard status == 200 else { throw SiblingError.failed(app, Self.message(status, data)) }
        guard let wave = SiblingWaveform.parse(data, documentName: doc.name) else {
            throw SiblingError.failed(app, String(localized: "The waveform couldn't be read."))
        }
        return wave
    }
}

extension JSONValue {
    public var bool: Bool? { if case .bool(let b) = self { b } else { nil } }
    /// The value as text for a path or query.
    var plainString: String {
        switch self {
        case .string(let s): s
        case .number(let n): n == n.rounded() && abs(n) < 1e15 ? String(Int(n)) : String(n)
        case .bool(let b): b ? "true" : "false"
        default: ""
        }
    }
}
