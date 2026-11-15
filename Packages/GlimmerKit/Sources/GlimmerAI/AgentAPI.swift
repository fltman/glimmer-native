import Foundation

/// The local HTTP API that lets other agents drive Glimmer: request parsing,
/// the security rules, the error format, the operation list and the agent
/// guide. Pure, so it's tested without a socket; the app owns the listener.
public enum AgentAPI {
    public static let version = "v1"
    /// Header every state-changing request must carry (a web page can't add it
    /// without a CORS preflight, which the server never grants).
    public static let agentHeader = "X-Glimmer-Agent"
    public static let preferredPort: UInt16 = 9001
    /// 9001 first, then Glimmer's own fallback range (Flimmer uses 9002 and 9201–9219,
    /// Jämmer 9003 and 9301–9319), so which app gets which port never depends on launch order.
    public static let candidatePorts: [UInt16] = [9001] + Array(9101...9119)

    /// Steps that call OpenRouter and cost money. Everything else runs on the Mac.
    public static var paidOps: Set<String> { Set(AgentPlanner.ops.filter(\.isAIJob).map(\.name)) }

    // MARK: Siblings

    /// Header a sibling app (Flimmer, Jämmer) adds with its slug. It grants nothing;
    /// Glimmer logs it and shows who asked.
    public static let siblingHeader = "X-Sibling"
    static let siblingNames = ["glimmer": "Glimmer", "flimmer": "Flimmer", "jammer": "Jämmer"]

    /// The app named by `X-Sibling`, for display: the known siblings by name, anything
    /// else reduced to at most 32 letters, digits and hyphens. Nil without the header.
    public static func sibling(_ r: Request) -> String? {
        guard let raw = r.headers[siblingHeader.lowercased()] else { return nil }
        let slug = String(raw.trimmingCharacters(in: .whitespaces).lowercased()
            .filter { ($0.isASCII && ($0.isLetter || $0.isNumber)) || $0 == "-" }.prefix(32))
        guard !slug.isEmpty else { return nil }
        return siblingNames[slug] ?? slug.prefix(1).uppercased() + slug.dropFirst()
    }

    // MARK: HTTP

    public struct Request: Sendable, Equatable {
        public var method: String
        public var path: String
        public var query: [String: String]
        /// Header names lowercased.
        public var headers: [String: String]
        public var body: Data

        public init(method: String, path: String, query: [String: String] = [:], headers: [String: String] = [:], body: Data = Data()) {
            self.method = method
            self.path = path
            self.query = query
            self.headers = headers
            self.body = body
        }

        /// Path components after the leading slash ("/api/v1/documents/x" → ["api","v1","documents","x"]).
        public var segments: [String] { path.split(separator: "/").map(String.init) }
    }

    public enum ParseResult: Equatable {
        /// More bytes are needed.
        case incomplete
        case request(Request)
        case invalid(String)
    }

    /// Largest accepted body (an uncompressed 8K image fits).
    public static let maxBody = 256 * 1024 * 1024

    /// Parses one HTTP/1.1 request from the bytes received so far.
    public static func parse(_ data: Data) -> ParseResult {
        guard let headerEnd = data.range(of: Data("\r\n\r\n".utf8)) else {
            return data.count > 64 * 1024 ? .invalid("Headers too large.") : .incomplete
        }
        guard let head = String(data: data[data.startIndex..<headerEnd.lowerBound], encoding: .utf8) else {
            return .invalid("Headers are not UTF-8.")
        }
        var lines = head.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst().split(separator: " ")
        guard requestLine.count >= 2 else { return .invalid("Malformed request line.") }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()] =
                line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let length = Int(headers["content-length"] ?? "0") ?? -1
        guard length >= 0 else { return .invalid("Bad Content-Length.") }
        guard length <= maxBody else { return .invalid("Body too large.") }
        if headers["transfer-encoding"]?.lowercased().contains("chunked") == true {
            return .invalid("Chunked bodies aren't supported; send Content-Length.")
        }
        let bodyStart = headerEnd.upperBound
        guard data.count - (bodyStart - data.startIndex) >= length else { return .incomplete }
        let body = data[bodyStart..<(bodyStart + length)]
        let target = String(requestLine[1])
        let parts = target.split(separator: "?", maxSplits: 1)
        var query: [String: String] = [:]
        if parts.count > 1 {
            for pair in parts[1].split(separator: "&") {
                let kv = pair.split(separator: "=", maxSplits: 1).map { String($0).removingPercentEncoding ?? String($0) }
                query[kv[0]] = kv.count > 1 ? kv[1] : ""
            }
        }
        let path = (String(parts.first ?? "/").removingPercentEncoding ?? "/")
        return .request(Request(method: String(requestLine[0]).uppercased(), path: path.isEmpty ? "/" : path,
                                query: query, headers: headers, body: Data(body)))
    }

    public struct Response: Sendable {
        public var status: Int
        public var contentType: String
        public var body: Data
        public var extraHeaders: [String: String]

        public init(status: Int, contentType: String, body: Data, extraHeaders: [String: String] = [:]) {
            self.status = status
            self.contentType = contentType
            self.body = body
            self.extraHeaders = extraHeaders
        }

        public static func json(_ object: Any, status: Int = 200) -> Response {
            let data = (try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])) ?? Data("{}".utf8)
            return Response(status: status, contentType: "application/json; charset=utf-8", body: data + Data("\n".utf8))
        }

        public static func text(_ string: String, contentType: String = "text/markdown; charset=utf-8", status: Int = 200) -> Response {
            Response(status: status, contentType: contentType, body: Data(string.utf8))
        }

        public static func error(_ error: APIError) -> Response {
            var body: [String: Any] = ["code": error.code, "message": error.message]
            if let details = error.details { body["details"] = details }
            if let reason = error.reason { body["reason"] = reason }
            return .json(["error": body], status: error.status)
        }

        /// The bytes to send (one request per connection).
        public var serialized: Data {
            var head = "HTTP/1.1 \(status) \(Self.reason(status))\r\n"
            head += "Content-Type: \(contentType)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n"
            head += "Cache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\n"
            for (k, v) in extraHeaders.sorted(by: { $0.key < $1.key }) { head += "\(k): \(v)\r\n" }
            return Data((head + "\r\n").utf8) + body
        }

        static func reason(_ status: Int) -> String {
            [200: "OK", 201: "Created", 400: "Bad Request", 402: "Payment Required", 403: "Forbidden",
             404: "Not Found", 405: "Method Not Allowed", 409: "Conflict", 413: "Payload Too Large",
             422: "Unprocessable Content", 500: "Internal Server Error", 503: "Service Unavailable"][status] ?? "Status"
        }
    }

    public struct APIError: Error, Sendable, Equatable {
        public var status: Int
        public var code: String
        public var message: String
        public var details: [String: String]?
        /// For `unprocessable`: which precondition wasn't met, as a short machine-readable word.
        public var reason: String?

        public init(_ status: Int, _ code: String, _ message: String, details: [String: String]? = nil, reason: String? = nil) {
            self.status = status
            self.code = code
            self.message = message
            self.details = details
            self.reason = reason
        }

        /// 422 for a request (not a step batch) whose precondition isn't met, such as nothing to undo.
        public static func unprocessable(_ reason: String, _ m: String) -> APIError { APIError(422, "unprocessable", m, reason: reason) }

        /// The error body of a failed step in a step batch (or job). Always `step_failed`, as in
        /// SIBLINGS.md; a step that refused for a known reason adds `reason`
        /// (`would_rasterize_text`, `bad_corners`, `group_has_mask`…).
        public static func stepFailedBody(step: Int, op: String, message: String, reason: String?) -> [String: Any] {
            var e: [String: Any] = ["code": "step_failed", "step": step, "message": "Step \(step) (\(op)) failed: \(message)"]
            if let reason { e["reason"] = reason }
            return e
        }

        public static func badRequest(_ m: String) -> APIError { APIError(400, "bad_request", m) }
        public static func notFound(_ m: String) -> APIError { APIError(404, "not_found", m) }
        public static func forbidden(_ m: String) -> APIError { APIError(403, "forbidden", m) }
        public static func notAvailable(_ m: String) -> APIError { APIError(409, "not_available", m) }
        public static func internalError(_ m: String) -> APIError { APIError(500, "internal", m) }
    }

    /// The security rules, checked before routing:
    /// - the Host must be this machine (stops DNS rebinding),
    /// - requests from web pages (an Origin header) are refused,
    /// - anything that changes state needs the agent header.
    public static func check(_ request: Request, port: UInt16) -> APIError? {
        let host = (request.headers["host"] ?? "").lowercased()
        let allowed = ["127.0.0.1", "localhost", "[::1]"].flatMap { ["\($0):\(port)", $0] }
        guard allowed.contains(host) else {
            return .forbidden("Host must be 127.0.0.1:\(port) or localhost:\(port).")
        }
        if request.headers["origin"] != nil {
            return .forbidden("Requests from web pages are not accepted. Call the API from a local process (curl, a script, an agent).")
        }
        if request.method != "GET", request.method != "HEAD", request.headers[agentHeader.lowercased()] != "1" {
            return .forbidden("Add the header \(agentHeader): 1 to every POST request.")
        }
        return nil
    }

    // MARK: Operations

    /// The operations `POST /steps` accepts, from the same list the built-in
    /// assistant uses, so the API, the guide and the executor can't drift apart.
    /// The shape is the series' sibling protocol: `params` is a JSON Schema, and every
    /// step is undoable (a whole `steps` request is one undo step).
    /// Requests that aren't steps carry `call` (method and path; `{id}` is the document).
    public static var operations: [[String: Any]] {
        (AgentPlanner.ops.map { op in
            ["name": op.name, "description": op.description, "params": AgentPlanner.paramsSchema(op),
             "paid": paidOps.contains(op.name), "undoable": true, "startsJob": op.startsJob] as [String: Any]
        } + endpointOperations).map { op in
            var op = op
            op["tier"] = coreOps.contains(op["name"] as? String ?? "") ? "core" : "advanced"
            return op
        }
    }

    /// The operations a sibling's assistant takes first when it can offer only a few tools
    /// (SIBLINGS.md §3): the everyday edits, a cover's parts, selection and export.
    public static let coreOps: Set<String> = [
        "add_adjustment", "apply_preset", "apply_filter", "add_text", "add_waveform", "auto_enhance", "auto_color",
        "select_subject", "remove_background", "generate_layer", "image_edit_composite", "export", "image", "undo",
    ]

    static let formats = ["png", "jpeg", "heic", "tiff", "webp"]

    /// The requests besides `steps` that a sibling's assistant may call as tools. Params
    /// marked `"x-in": "path"` or `"query"` go there; the rest go in the JSON body.
    static var endpointOperations: [[String: Any]] {
        func op(_ name: String, _ description: String, _ method: String, _ path: String,
                _ properties: [String: Any] = [:], undoable: Bool = false) -> [String: Any] {
            var properties = properties
            properties["id"] = ["type": "string", "x-in": "path", "description": "The document id (GET /api/v1/documents)."]
            return ["name": name, "description": description,
             "params": ["type": "object", "properties": properties, "required": ["id"]] as [String: Any],
             "paid": false, "undoable": undoable, "startsJob": false,
             "call": ["method": method, "path": "/api/\(version)/documents/{id}/\(path)"]]
        }
        let format: [String: Any] = ["type": "string", "enum": formats, "description": "Optional. Default png."]
        let maxSide: [String: Any] = ["type": "integer", "minimum": 16, "description": "Optional. Scale so the longer side fits, in pixels."]
        return [
            op("export", "Render the document to an image file and return its bytes (JSON body). With preset podcast-cover: the centre square at exactly 3000 or 1400 pixels, JPEG or PNG, under maxBytes.", "POST", "export", [
                "preset": ["type": "string", "enum": ["podcast-cover"],
                           "description": "Optional. podcast-cover: square cover art in podcast sizes (format jpeg by default, or png)."],
                "size": ["type": "integer", "enum": [3000, 1400],
                         "description": "Optional, with preset. Side in pixels. Default 3000, or 1400 when 3000 can't meet maxBytes."],
                "format": format,
                "quality": ["type": "number", "minimum": 0.05, "maximum": 1, "description": "Optional. JPEG, HEIC and WebP quality."],
                "maxSide": maxSide,
                "maxBytes": ["type": "integer", "minimum": 1000, "description": "Optional. Largest file size in bytes (JPEG, HEIC, WebP)."],
            ]),
            op("image", "The flattened image as bytes.", "GET", "image",
               ["format": format.merging(["x-in": "query"]) { $1 }, "maxSide": maxSide.merging(["x-in": "query"]) { $1 }]),
            op("undo", "Undo the last change (a whole steps request is one).", "POST", "undo"),
            op("redo", "Redo the last undone change.", "POST", "redo"),
        ]
    }

    // MARK: Guide

    /// The guide an agent fetches first: what Glimmer is and exactly how to drive it.
    public static func guide(port: UInt16, appVersion: String) -> String {
        let base = "http://127.0.0.1:\(port)"
        var s = """
        # Glimmer: guide for agents

        Glimmer \(appVersion) is a native macOS photo editor with layers, adjustment layers, filters, selections, text and on-device AI (subject, people and sky selection, auto enhance, perspective correction). This page tells an agent how to drive the running app through its local HTTP API.

        - Base URL: `\(base)` (this Mac only; the server listens on loopback). Glimmer uses port 9001, or the first free port from 9101 to 9119 when 9001 is taken; the address in Glimmer's **Help › Agent Access** window is always the real one.
        - Check that `app.name` in `GET /api/v1/status` is `"Glimmer"` before you send changes, so you never edit with a different app that happens to listen on the port.
        - Every POST needs the header **`\(agentHeader): 1`**. Without it you get `403 forbidden`.
        - Don't send an `Origin` header: requests that look like they come from a web page are refused.
        - Images travel in request and response bodies. The API never reads or writes file paths.
        - Edits land in open document windows that the user can see, and can be undone. One `steps` request is one undo step.
        - Steps that cost money (OpenRouter) are refused unless you pass `"allowPaid": true`. Everything else runs on the Mac, free.

        ## Quick start

        Run these in order. Replace `photo.jpg` with any image.

        ```sh
        BASE=\(base)

        # 1. Is Glimmer there? Check that app.name is "Glimmer" before you change anything.
        curl -s $BASE/api/v1/status
        # → {"app": {"name": "Glimmer", "version": "…"}, "api": "v1", "documents": […], …}

        # 2. Open an image as a new document. The reply contains its id.
        curl -s -X POST -H '\(agentHeader): 1' -H 'Content-Type: image/jpeg' \\
             --data-binary @photo.jpg $BASE/api/v1/documents
        # → {"document": {"id": "8F0C…", "width": 3840, "height": 2160, …}}
        ID=8F0C…

        # 3. Edit it: automatic tone and colour, then a little more vibrance.
        curl -s -X POST -H '\(agentHeader): 1' -H 'Content-Type: application/json' \\
             -d '{"steps": [{"op": "auto_enhance"},
                            {"op": "add_adjustment", "params": {"type": "vibrance", "params": {"vibrance": 0.25}}}]}' \\
             $BASE/api/v1/documents/$ID/steps

        # 4. Look at the result (PNG, at most 1024 px).
        curl -s "$BASE/api/v1/documents/$ID/image?maxSide=1024" -o preview.png

        # 5. Export it as a JPEG under 500 kB.
        curl -s -X POST -H '\(agentHeader): 1' -H 'Content-Type: application/json' \\
             -d '{"format": "jpeg", "quality": 0.9, "maxBytes": 500000}' \\
             $BASE/api/v1/documents/$ID/export -o result.jpg
        ```

        Opening a document answers `201 Created`. To start from a blank canvas instead, send `-H 'Content-Type: application/json' -d '{"width": 1600, "height": 900, "background": "white"}'` in step 2. To send the image inside JSON: `-d '{"image": "<base64 of the file>", "name": "Holiday"}'`.

        ## Endpoints

        | Method | Path | What it does |
        |---|---|---|
        | GET | `/glimmer` | This guide (Markdown). |
        | GET | `/api/v1/status` | `app.name` (always `"Glimmer"`), `app.version`, the API version, the port, the open documents and the running `jobs`. |
        | GET | `/api/v1/operations` | Every step operation: `{"operations": [{"name", "description", "params", "paid", "undoable", "startsJob"}]}`. `params` is a JSON Schema, so an assistant can use the operations as tools as they are. Steps run through `steps`; the other requests (`export`, `image`, `undo`, `redo`) carry `call: {method, path}`, and their params marked `"x-in": "path"` or `"query"` go there (the rest in the JSON body). `tier` is `"core"` for the everyday operations and `"advanced"` for the rest, for assistants that can offer only a few tools. |
        | GET | `/api/v1/documents` | The open documents. The one whose window is in front has `"frontmost": true`; an image Flimmer or Jämmer handed over to edit has `linkedFile` (`name`, `format`, `requester`), and ⌘S writes it back. |
        | POST | `/api/v1/documents` | Open an image (raw bytes with `?name=…`, or JSON `{"image": "<base64>", "name": "…"}`) or create a blank document (JSON `{"width", "height", "background": "white"\\|"black"\\|"transparent", "name"}`). `name` names the document's window. Glimmer's untouched start document is replaced instead of leaving an empty window. |
        | GET | `/api/v1/documents/{id}` | Size, layers (top first, each with `bounds` in document pixels when it has content), the active layer and whether there is a selection. |
        | GET | `/api/v1/documents/{id}/image` | The flattened image. Query: `format=png\\|jpeg`, `maxSide=<px>`. |
        | POST | `/api/v1/documents/{id}/steps` | Run steps in order. Body: `{"steps": [{"op": "…", "params": {…}}], "allowPaid": false, "async": false}`. Answers 200 when done, or 202 with a job (see Long jobs). |
        | GET | `/api/v1/jobs` | Recent jobs (see Long jobs). |
        | GET | `/api/v1/jobs/{id}` | One job: status, progress and, when finished, the result. |
        | DELETE | `/api/v1/jobs/{id}` | Cancel a job that is still running. |
        | POST | `/api/v1/documents/{id}/undo` | Undo the last step (a whole `steps` request counts as one). |
        | POST | `/api/v1/documents/{id}/redo` | Redo. |
        | POST | `/api/v1/documents/{id}/export` | The finished image as bytes. Body: `{"format": "png\\|jpeg\\|heic\\|tiff\\|webp", "quality": 0.9, "maxSide": 2048, "maxBytes": 500000}`; all optional (PNG by default). |

        Document ids are stable while the window is open. Use `GET /api/v1/documents` to find documents the user opened.

        ### Steps

        A steps request runs every step in order and stops at the first failure; later steps are reported as `skipped`. The reply lists each step:

        ```json
        {"results": [{"index": 0, "op": "auto_enhance", "status": "done"},
                     {"index": 1, "op": "apply_filter", "status": "failed", "error": "There's no pixel layer to work on."}],
         "document": {…}}
        ```

        Which layer a step acts on:

        - Most operations act on the **active layer**, inside the **selection** when there is one. Make a selection with `select_subject`, `select_people`, `select_sky` or `select_all`, and clear it with `deselect`.
        - New layers (adjustments, text, fills, `new_layer`) become the active layer.
        - Filters, `fill` and `remove_background` need a pixel layer. If the active layer isn't one, Glimmer uses the topmost visible pixel layer, so `add_adjustment` followed by `apply_filter` still filters the photo.
        - Use `select_layer` with a name or id from `GET /api/v1/documents/{id}` to pick a layer yourself.

        Common requests: black and white is `add_adjustment` with `"type": "black_white"`; a vignette is `apply_filter` with `"type": "vignette"`; a finished look is `apply_preset`.

        ### Long jobs

        Steps that call OpenRouter can take a minute, so a `steps` request that contains a paid step always runs as a job, and so does any request with `"async": true`. Such a request answers `202 Accepted` at once:

        ```json
        {"job": {"id": "C1A2…", "kind": "steps", "document": "8F0C…", "status": "running", "progress": 0}}
        ```

        Poll `GET /api/v1/jobs/{id}` until `status` is `done`, `failed` or `cancelled` (it starts as `queued` or `running`). `progress` goes from 0 to 1 as steps finish. A finished job carries the same `result` a direct request would have returned (`results` and `document`), and a failed one also has `error` (`{"code": "step_failed", "message": "…", "step": 1}`). `DELETE /api/v1/jobs/{id}` cancels a running job; steps that didn't run are reported as `cancelled`. Running jobs are also listed under `jobs` in `GET /api/v1/status`. Finished jobs are kept for a while (the 50 most recent).

        ```sh
        JOB=$(curl -s -X POST -H '\(agentHeader): 1' -d '{"steps": [{"op": "auto_enhance"}], "async": true}' \
              $BASE/api/v1/documents/$ID/steps | python3 -c 'import json,sys; print(json.load(sys.stdin)["job"]["id"])')
        curl -s $BASE/api/v1/jobs/$JOB
        ```

        ### Requests from other apps

        Glimmer's siblings, Flimmer and Jämmer, call this API like any agent and add `X-Sibling: <their slug>` (for example `X-Sibling: flimmer`). Glimmer logs it and shows "Requested by Flimmer" in the window it changes. The header grants nothing extra.

        ### Export size limits

        **Podcast covers:** `POST /api/v1/documents/{id}/export` with `{"preset": "podcast-cover", "maxBytes": 512000}` returns the centre square of the image at exactly 3000 × 3000 pixels, as an opaque JPEG (or `"format": "png"`). Only the quality goes down to meet `maxBytes`; when 3000 can't, it's 1400 × 1400, and `"size": 3000` or `1400` fixes the size. If the limit can't be met, the answer is `422 unprocessable` with `reason` `over_byte_limit`.

        `maxSide` scales the image so its longer side fits. `maxBytes` (JPEG, HEIC and WebP only; PNG and TIFF ignore it) lowers the quality until the file fits, and scales the image down too if even low quality is too big, so the limit is met.

        ## Errors

        Errors are JSON: `{"error": {"code": "…", "message": "…"}}`. A failed step also gives its index: `{"error": {"code": "step_failed", "message": "…", "step": 1}}`.

        | Status | Code | Meaning |
        |---|---|---|
        | 400 | `bad_request` | The body or a parameter is malformed. The message says which. |
        | 402 | `paid_not_allowed` | A step costs money and `allowPaid` wasn't `true` (or no OpenRouter key is saved in Glimmer). |
        | 403 | `forbidden` | Missing `\(agentHeader): 1`, an `Origin` header, or a Host other than this Mac. |
        | 404 | `not_found` | No such document, path or operation. |
        | 405 | `method_not_allowed` | Wrong HTTP method for the path. |
        | 413 | `too_large` | Body over 256 MB. |
        | 422 | `step_failed` | A step ran and failed. `error.step` is its index; `results` has the status of every step. When the step refused for a known reason, `error.reason` says which (`would_rasterize_text`, `bad_corners`, `group_has_mask`, `cannot_transform`). |
        | 422 | `unprocessable` | A request other than steps can't be done right now; `error.reason` says why (`nothing_to_undo`, `nothing_to_redo`, `no_history`, `over_byte_limit`). |
        | 500 | `internal` | Glimmer failed unexpectedly. The message has the detail. |

        ## Operations

        These are the `op` values for `steps`, with their `params`. The same list is available as JSON from `GET /api/v1/operations`.

        """
        for op in AgentPlanner.ops {
            s += "\n### `\(op.name)`\(paidOps.contains(op.name) ? " (paid)" : "")\n\n\(op.description)\n"
            if op.params.isEmpty {
                s += "\nNo params: `{\"op\": \"\(op.name)\"}`\n"
                continue
            }
            s += "\n| Param | Type | Description |\n|---|---|---|\n"
            for p in op.params {
                var description = p.description.replacingOccurrences(of: "|", with: "\\|")
                if let options = p.options {
                    let list = options.count > 40 ? options.prefix(40).joined(separator: "`, `") + "` … (see /api/v1/operations)"
                        : options.joined(separator: "`, `") + "`"
                    description += " One of: `" + list
                }
                s += "| `\(p.name)` | \(p.type) | \(description) |\n"
            }
        }
        s += """

        ## Good to know

        - Adjustment layers are non-destructive; filters change pixels. Prefer `add_adjustment` for tone and colour.
        - `auto_enhance` and `auto_color` add editable adjustment layers, worked out on the Mac.
        - After a step, `GET /api/v1/documents/{id}/image` shows you what the user sees.
        - The user may be editing the same document. Read the document before you act on it, and keep requests small.

        """
        return s
    }
}
