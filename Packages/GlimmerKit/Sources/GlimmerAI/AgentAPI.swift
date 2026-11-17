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
        /// (`would_rasterize_text`, `bad_corners`…).
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

    /// An error in the words an agent is told: English whatever language the app shows.
    /// Glimmer's own errors are written in English and translated only where the window shows them.
    /// The system's errors come in the Mac's language, so of those only the domain and code are passed on.
    public static func words(for error: Error) -> String {
        if let own = (error as? LocalizedError)?.errorDescription, !(error is CocoaError), !(error is URLError) { return own }
        let ns = error as NSError
        if ns.domain.hasPrefix("NS") || ns.domain.hasPrefix("kCF") || ns.domain == "SwiftUI" || error is CocoaError || error is URLError {
            return "The system reported an error (\(ns.domain) \(ns.code))."
        }
        return (error as? LocalizedError)?.errorDescription ?? String(describing: error)
    }

    // MARK: Operations

    /// The operations `POST /steps` accepts, from the same list the built-in
    /// assistant uses, so the API, the guide and the executor can't drift apart.
    /// The shape is the series' sibling protocol: `params` is a JSON Schema, and every
    /// step is undoable (a whole `steps` request is one undo step).
    /// Requests that aren't steps carry `call` (method and path; `{id}` is the document).
    public static var operations: [[String: Any]] {
        (AgentPlanner.ops.map { op in
            var entry = ["name": op.name, "description": op.description, "params": AgentPlanner.paramsSchema(op),
                         "paid": paidOps.contains(op.name), "undoable": true, "startsJob": op.startsJob] as [String: Any]
            // A paid operation says what it costs, or that Glimmer doesn't know (then the call needs `allowUnknownPrice`).
            if paidOps.contains(op.name) { entry["price"] = NSNull(); entry["priceKnown"] = false }
            return entry
        } + endpointOperations).map { op in
            var op = op
            op["tier"] = coreOps.contains(op["name"] as? String ?? "") ? "core" : "advanced"
            return op
        }
    }

    /// The operations a sibling's assistant takes first when it can offer only a few tools
    /// (SIBLINGS.md §3): the everyday edits, a cover's parts, selection and export.
    public static let coreOps: Set<String> = [
        "add_adjustment", "add_text", "add_waveform", "auto_enhance",
        "select_subject", "remove_background", "generate_layer", "image_edit_composite", "export", "image", "undo",
        "crop", "resize_image", "set_layer", "add_image",
    ]

    static let formats = ["png", "jpeg", "heic", "tiff", "webp"]

    /// The requests besides `steps` that a sibling's assistant may call as tools. Params
    /// marked `"x-in": "path"` or `"query"` go there; the rest go in the JSON body.
    static var endpointOperations: [[String: Any]] {
        func op(_ name: String, _ description: String, _ method: String, _ path: String,
                _ properties: [String: Any] = [:], undoable: Bool = false) -> [String: Any] {
            var properties = properties
            properties["id"] = ["type": "string", "x-in": "path", "description": "The document id (GET /api/v1/documents)."]
            // `rationale` goes where the operation's other values go: in the query when the body is not JSON.
            let inQuery = method == "GET" || properties.values.contains { ($0 as? [String: Any])?["x-in"] as? String == "query" }
            properties["rationale"] = inQuery ? StepParameters.rationaleSchema.merging(["x-in": "query"]) { $1 } : StepParameters.rationaleSchema
            return ["name": name, "description": description,
             "params": ["type": "object", "properties": properties, "required": ["id"], "additionalProperties": false] as [String: Any],
             "paid": false, "undoable": undoable, "startsJob": false,
             "call": ["method": method, "path": "/api/\(version)/documents/{id}/\(path)"]]
        }
        let format: [String: Any] = ["type": "string", "enum": formats, "description": "Optional. Default png."]
        let maxSide: [String: Any] = ["type": "integer", "minimum": 16, "description": "Optional. Scale so the longer side fits, in pixels."]
        return [
            op("export", "Render the document to an image file and return its bytes (JSON body). With preset podcast-cover: the center square at exactly 3000 or 1400 pixels, JPEG or PNG, under maxBytes.", "POST", "export", [
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
            op("add_image", "Add an image as a new layer in an open document, to combine two images. Two ways to give the image, both open to any caller: send its bytes as the request body (PNG, JPEG, HEIC, TIFF or WebP; Content-Type image/… or application/octet-stream), or, when you have no bytes to send (an assistant calling this as a tool), give fromDocument: another open document, whose picture becomes the layer. The other options go in the query. The new layer lands above the active layer and becomes the active one. One undo step. Answers 201 with {layer: {id, name, bounds}}.", "POST", "layers", [
                "fromDocument": ["type": "string", "description": "The id of another open document; its flattened picture becomes the new layer. Leave out when the body is image bytes."],
                "name": ["type": "string", "x-in": "query", "description": "Optional. The layer's name (default: the source document's name, or Image)."],
                "fit": ["type": "string", "enum": CanvasSteps.Fit.allCases.map(\.rawValue), "x-in": "query",
                        "description": "Optional. contain (default): scaled down to fit the canvas, never up. cover: scaled to cover the whole canvas. none: at its own size."],
                "x": ["type": "number", "x-in": "query", "description": "Optional. Left edge in document pixels (default: centerd)."],
                "y": ["type": "number", "x-in": "query", "description": "Optional. Top edge in document pixels (default: centerd)."],
                "smartObject": ["type": "boolean", "x-in": "query",
                                "description": "Optional. true (default) keeps the image's own pixels, so later scaling doesn't soften it; false makes a plain pixel layer."],
            ], undoable: true),
            op("undo", "Undo the last change (a whole steps request is one).", "POST", "undo"),
            op("redo", "Redo the last undone change.", "POST", "redo"),
        ]
    }

    // MARK: Guide

    /// The guide an agent fetches first: what Glimmer is and exactly how to drive it.
    /// What the guide says about taking an object out of a photo; depends on whether this
    /// build has Heal Selection (Config/Features.xcconfig).
    /// A build without the feature has no text about it at all, whatever `heal` says.
    static func objectRemovalNote(heal: Bool) -> String {
        let patch = "Free steps can cut out a subject (`remove_background`), cover an area with a color (`fill`) or patch it with a copy of another part (`select_rect` with a `feather`, then `run_command` `layer.viaCopy`, which copies the selected, feathered part of the active layer to a new layer, then `transform_layer` with `moveX`/`moveY` to put the copy over the object)."
        #if GLIMMER_HEAL
        if heal {
            return "To take something out of a photo: select it (`select_rect`, or `select_subject` when it is the main subject), then `heal_selection` fills the area from what surrounds it, on the Mac and free. It suits dust, scratches, wires and things up to about 120 px across on grass, sky, walls and the like; it copies existing image, it does not invent, so a large object or one in front of a complicated scene needs `inpaint_selection` (paid). An area over about 120 px across is refused with `area_too_large` unless `allowLarge` is true, and over 250 px or too much work always (`hard` is then true). " + patch
        }
        #endif
        return "Removing an object from a photo has no free operation: `inpaint_selection` (paid) is the only one. " + patch
    }

    /// Whether this build opens Photoshop files with their layers (Config/Features.xcconfig).
    public static var hasPSD: Bool {
        #if GLIMMER_PSD
        true
        #else
        false
        #endif
    }

    /// The guide's line about Photoshop files; a build without the import has no text about it.
    static func photoshopNote(psd: Bool) -> String {
        #if GLIMMER_PSD
        if psd {
            return "- A Photoshop file (PSD or PSB bytes) sent to `POST /api/v1/documents` opens with its layers. The reply's `document.importReport` says what came through: `layersInFile`, `layersKept`, `flattened` (true when only the file's own flattened picture could be used), `notes` (one per thing that did not come through: `layer`, `what`, `changesLook`), `looksTheSame`, and `differenceFromFile` (Glimmer's picture against the one saved in the file: `mean` on a scale of 0 to 255 and `shareVisiblyDifferent` from 0 to 1). Read it before you rely on the layers: text, smart objects, adjustment layers, fill layers and effects are not editable or are left out, and the notes say which. The same report is shown to the person in the window.\n- `POST /api/v1/documents/{id}/export` with `{\"format\": \"psd\"}` returns a Photoshop file with the layers (`\"depth\"`: 8 or 16; `\"flatten\": true` merges everything into one layer). The response header `X-Glimmer-Export-Report` holds JSON: `layersWritten`, `notes` (what is written as pixels or left out, each with `layer`, `kind`, `what`, `changesLook`), and for a document that blends in linear light `layersBlendedInGamma` (how different the layers will look in other programs). Glimmer reads these files back itself and macOS shows their picture; the layers have not been tried in Photoshop.\n"
        }
        #endif
        return ""
    }

    /// Whether this build has Heal Selection (Config/Features.xcconfig).
    public static var hasHeal: Bool {
        #if GLIMMER_HEAL
        true
        #else
        false
        #endif
    }

    /// `heal`: whether the guide describes Heal Selection. The app passes nothing (what it was
    /// built with); the site's copy is written for what a release has.
    /// Whether this build develops RAW files (Config/Features.xcconfig).
    public static var hasRAW: Bool {
        #if GLIMMER_RAW
        true
        #else
        false
        #endif
    }

    static func rawNote(raw: Bool) -> String {
        #if GLIMMER_RAW
        if raw {
            return "- A camera's RAW file (DNG, CR3, RAF, ORF, RW2 and others; the bytes sent to `POST /api/v1/documents`) opens as a layer that keeps the file: the layer has `raw` (`fileName`, `byteCount`, `settings`, `process`, `pixelsAsDeveloped`), and `develop_raw` develops it again with other settings, without loss. `GET /api/v1/documents/{id}/layers/{layer}/raw/info` says what the file allows. If macOS's decoder gives no picture for the file, the answer is 422 `raw_not_developed` with the reason; another recording mode of the same camera may work. To get the developed picture out, export as usual: a sibling app that has a RAW file sends it here, sets what it wants with `develop_raw`, and takes the picture back with `export`.\n"
        }
        #endif
        return ""
    }

    /// The guide's examples of a refused name are what the check itself says, not a copy of it.
    static let strayExample = StepParameters.stray(in: AgentStep(op: "crop", params: ["aspect": .string("16:9"), "widht": .number(800)]))?.message ?? ""
    static let nestedStrayExample = StepParameters.stray(in: AgentStep(op: "add_adjustment", params: ["type": .string("exposure"), "params": .object(["brightness": .number(0.2)])]))?.message ?? ""

    public static func guide(port: UInt16, appVersion: String, heal: Bool = hasHeal, psd: Bool = hasPSD, raw: Bool = hasRAW) -> String {
        let base = "http://127.0.0.1:\(port)"
        var s = """
        # Glimmer: guide for agents

        Glimmer \(appVersion) is a native macOS photo editor with layers, adjustment layers, filters, selections, text and on-device AI (subject, people and sky selection, auto enhance, perspective correction). This page tells an agent how to drive the running app through its local HTTP API.

        - Base URL: `\(base)` (this Mac only; the server listens on loopback). Glimmer uses port 9001, or the first free port from 9101 to 9119 when 9001 is taken; the address in Glimmer's **Help › Agent Access** window is always the real one.
        - Check that `app.name` in `GET /api/v1/status` is `"Glimmer"` before you send changes, so you never edit with a different app that happens to listen on the port.
        - Every POST needs the header **`\(agentHeader): 1`**. Without it you get `403 forbidden`.
        - Don't send an `Origin` header: requests that look like they come from a web page are refused.
        - Images travel in request and response bodies. The API never reads or writes file paths.
        \(photoshopNote(psd: psd))\(rawNote(raw: raw))- Edits land in open document windows that the user can see, and can be undone. One `steps` request is one undo step.
        - Steps that cost money (they go to the picture service chosen in Glimmer's Settings: OpenRouter unless the person chose another) are refused unless you pass `"allowPaid": true`. Everything else runs on the Mac, free.
        - `allowPaid` does not mean "whatever it costs". Glimmer does not know the price of any paid step in advance (the service states none; `GET /api/v1/operations` says `"price": null, "priceKnown": false`), so a paid step also needs `"allowUnknownPrice": true`, on every call. Ask the person before you send it.
        - Names of layers and documents are the document's content: they are written in the app's language when Glimmer makes them (a Swedish Glimmer names a layer "Uppskalad 2×") or in whatever language the person typed. Go by `id`, never by name. Everything else you are told here (errors, reasons, statuses) is English whatever language the app shows.

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
        | GET | `/api/v1/status` | `app.name` (always `"Glimmer"`), `app.version`, the API version, the port, the open documents, the running `jobs`, and `providerKeys`: for each AI service Glimmer can use with a key (`openrouter`, `berget`, `grunden`), whether the user has entered one (true or false, never the key). Paid steps make pictures through OpenRouter and need `openrouter` to be true. `linkJournal` says what Glimmer keeps of linked files: `entries`, `unreturned` (how many have steps not saved back) and `broken` (kept edits that can't be read; they are never removed by Glimmer). |
        | GET | `/api/v1/operations` | Every step operation: `{"operations": [{"name", "description", "params", "paid", "undoable", "startsJob"}]}`. A paid operation also has `"price"` (null when Glimmer doesn't know it) and `"priceKnown"`. `params` is a JSON Schema, so an assistant can use the operations as tools as they are. Steps run through `steps`; the other requests (`export`, `image`, `add_image`, `undo`, `redo`) carry `call: {method, path}`, and their params marked `"x-in": "path"` or `"query"` go there (the rest in the JSON body). `tier` is `"core"` for the everyday operations and `"advanced"` for the rest, for assistants that can offer only a few tools. |
        | GET | `/api/v1/documents` | The open documents. The one whose window is in front has `"frontmost": true`; Glimmer's own empty start document, which the first image you open replaces (keeping its id), has `"startDocument": true`; an image Flimmer or Jämmer handed over to edit has `linkedFile` (`name`, `format`, `requester`, `available`), and ⌘S writes it back. The link survives a restart of Glimmer; `available` is false, with a `reason`, when the file can no longer be reached or written after one. `unreturnedSteps` (when above 0) is how many steps are not saved back yet; `kept: true` means the person left it so at Quit or with Keep for Later and it was opened again, `recovered: true` that Glimmer stopped on its own and the document was brought back. Both go when it is saved back. |
        | POST | `/api/v1/documents` | Open an image (raw bytes with `?name=…`, or JSON `{"image": "<base64>", "name": "…"}`) or create a blank document (JSON `{"width", "height", "background": "white"\\|"black"\\|"transparent", "name"}`). `name` names the document's window and, for an image, its layer. Glimmer's untouched start document is replaced instead of leaving an empty window. |
        | GET | `/api/v1/documents/{id}` | Size, layers (top first, each with `bounds` in document pixels when it has content), the active layer and whether there is a selection. |
        | GET | `/api/v1/documents/{id}/image` | The flattened image. Query: `format=png\\|jpeg`, `maxSide=<px>`. |
        | POST | `/api/v1/documents/{id}/steps` | Run steps in order. Body: `{"steps": [{"op": "…", "params": {…}}], "allowPaid": false, "allowUnknownPrice": false, "async": false}`. Answers 200 when done, or 202 with a job (see Long jobs). |
        | GET | `/api/v1/jobs` | Recent jobs (see Long jobs). |
        | GET | `/api/v1/jobs/{id}` | One job: status, progress and, when finished, the result. |
        | DELETE | `/api/v1/jobs/{id}` | Cancel a job that is still running. |
        | POST | `/api/v1/documents/{id}/layers` | Add an image as a new layer (`add_image`). Body: the image's bytes, as when you open a document, or JSON `{"fromDocument": "<id>"}` to use another open document's picture. Query: `name`; `fit` against the canvas (`contain`, the default: scaled down to fit inside it, never up; `cover`: scaled to cover it; `none`: its own size); `x`, `y`: where its top-left goes after fitting (default: centred); `smartObject=true\\|false`. Answers 201 with `{"layer": {"id", "name", "bounds"}, "document": …}`. One undo step. |
        | POST | `/api/v1/documents/{id}/undo` | Undo the last change (a whole `steps` request counts as one; the selection goes back too). Answers `{"undone": "<name of the change>", "document": …}`; a steps request is named `Agent Edit`. |
        | POST | `/api/v1/documents/{id}/redo` | Redo. Answers `{"redone": "<name>", "document": …}`. |
        | POST | `/api/v1/documents/{id}/export` | The finished image as bytes. Body: `{"format": "png\\|jpeg\\|heic\\|tiff\\|webp", "quality": 0.9, "maxSide": 2048, "maxBytes": 500000}`; all optional (PNG by default). `"preset": "podcast-cover"` with `"size": 3000\\|1400` gives square cover art (see Export size limits). |

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
        - A request with a paid step and no `allowPaid` is refused as a whole (402) before any step runs.
        - A request with a paid step whose price Glimmer doesn't know, and no `allowUnknownPrice`, is refused as a whole (422, `error.reason` `unknown_price`) before any step runs. Today that is every paid step.

        A step may also return `info`, facts about what it did. `style_text` returns `{"matches": 2, "ranges": [{"from": 6, "length": 5}, …]}`, the ranges it actually styled.

        **Styling words:** to make one word stand out, add the text, then style the word in the same request (one undo step):

        ```json
        {"steps": [{"op": "add_text", "params": {"text": "Summer sale today", "position": "center"}},
                   {"op": "style_text", "params": {"match": "sale", "bold": true, "color": "#E0303A"}}]}
        ```

        Prefer `match`. `from` and `length` count characters as grapheme clusters (Swift Characters), not code points or UTF-16 units: 👍🏽, 🇸🇪 and an å written as a + ring each count as 1, while JavaScript's `length` counts them as 4, 4 and 2. A text layer with styled words lists them under `styles` in `GET /api/v1/documents/{id}`, in the same units: `[{"from": 7, "length": 4, "fontName": "HelveticaNeue-Bold", "color": "#E0303A"}]`. Without `match` or `from`, the whole text is styled. Refusals come as `step_failed` with `reason` `not_text`, `no_match`, `bad_range` or `unknown_font` (and `bad_color`, `bad_size` or `nothing_to_style` for parameters that don't make sense).

        Common requests: black and white is `add_adjustment` with `"type": "black_white"`; a vignette is `apply_filter` with `"type": "vignette"`; a finished look is `apply_preset`.

        ### Long jobs

        Paid steps can take a minute, so a `steps` request that contains a paid step always runs as a job, and so does any request with `"async": true`. Such a request answers `202 Accepted` at once:

        ```json
        {"job": {"id": "C1A2…", "kind": "steps", "document": "8F0C…", "status": "running", "progress": 0}}
        ```

        Poll `GET /api/v1/jobs/{id}` until `status` is `done`, `failed` or `canceled` (it starts as `queued` or `running`; these five are all there are). Changed 2026-11-17: a stopped job and a stopped step were spelled `cancelled` before; accept both if you may meet an older Glimmer, and treat any status you do not know as an end, not as "still running". `progress` goes from 0 to 1 as steps finish. A finished job carries the same `result` a direct request would have returned (`results` and `document`), and a failed one also has `error` (`{"code": "step_failed", "message": "…", "step": 1}`). `DELETE /api/v1/jobs/{id}` cancels a running job; steps that didn't run are reported as `cancelled`. Running jobs are also listed under `jobs` in `GET /api/v1/status`. Finished jobs are kept for a while (the 50 most recent).

        ```sh
        JOB=$(curl -s -X POST -H '\(agentHeader): 1' -d '{"steps": [{"op": "auto_enhance"}], "async": true}' \
              $BASE/api/v1/documents/$ID/steps | python3 -c 'import json,sys; print(json.load(sys.stdin)["job"]["id"])')
        curl -s $BASE/api/v1/jobs/$JOB
        ```

        ### Requests from other apps

        Glimmer's siblings, Flimmer and Jämmer, call this API like any agent and add `X-Sibling: <their slug>` (for example `X-Sibling: flimmer`). Glimmer logs it and shows "Requested by Flimmer" in the window it changes. The header grants nothing extra.

        ### Export size limits

        **Podcast covers:** `POST /api/v1/documents/{id}/export` with `{"preset": "podcast-cover", "maxBytes": 512000}` returns the centre square of the image at exactly 3000 × 3000 pixels, as an opaque JPEG (or `"format": "png"`). Only the quality goes down to meet `maxBytes`; when 3000 can't, it's 1400 × 1400, and `"size": 3000` or `1400` fixes the size. If the limit can't be met, the answer is `422 unprocessable` with `reason` `over_byte_limit`.

        `maxSide` scales the image down so its longer side fits; it never enlarges. The podcast preset is the exception: it always gives its exact size, enlarging a smaller image. `quality` defaults to 0.9. `maxBytes` (JPEG, HEIC and WebP only; PNG and TIFF ignore it) lowers the quality until the file fits, and scales the image down too if even low quality is too big, so the limit is met.

        ## Errors

        Errors are JSON: `{"error": {"code": "…", "message": "…"}}`. A failed step also gives its index: `{"error": {"code": "step_failed", "message": "…", "step": 1}}`.

        A name that an operation or an endpoint doesn't have is never passed over. The message names it and lists what there is, and nothing was applied (in a `steps` request, no step ran). For `{"steps": [{"op": "crop", "params": {"aspect": "16:9", "widht": 800}}]}` the answer is 400 with:

        ```json
        {"error": {"code": "bad_request", "message": "Step 0: \(strayExample) No step of this request was run."}}
        ```

        The same goes for a setting inside `params` of `add_adjustment`, `apply_filter` and `add_layer_effect` ("\(nestedStrayExample)"), for a setting put beside `"op"` instead of inside `"params"`, and for query parameters.

        | Status | Code | Meaning |
        |---|---|---|
        | 400 | `bad_request` | The body or a parameter is malformed, or carries a name that isn't one of its parameters. The message says which. |
        | 402 | `paid_not_allowed` | A step costs money and `allowPaid` wasn't `true` (or no key is saved in Glimmer for the picture service chosen there; the message names the service). The request is checked before anything runs: no step of it was run. |
        | 403 | `forbidden` | Missing `\(agentHeader): 1`, an `Origin` header, or a Host other than this Mac. |
        | 404 | `not_found` | No such document, path or operation. |
        | 405 | `method_not_allowed` | Wrong HTTP method for the path. |
        | 413 | `too_large` | Body over 256 MB. |
        | 422 | `step_failed` | A step ran and failed. `error.step` is its index; `results` has the status of every step. When the step refused for a known reason, `error.reason` says which (`would_rasterize_text`, `bad_corners`, `cannot_transform`, `not_text`, `no_match`, `bad_range`, `unknown_font`, `bad_rect`, `no_selection`, `bad_aspect`, `bad_size`, `too_large`, `bad_anchor`, `bad_color`, `unknown_layer`, `ambiguous_target`, `unknown_blend_mode`, `bad_opacity`, `nothing_to_set`). `group_has_mask` is no longer returned: layer masks now follow a transform. |
        | 422 | `unprocessable`, reason `unknown_price` | A step is paid, Glimmer doesn't know its price in advance, and `allowUnknownPrice` wasn't `true`. Checked after `allowPaid` (402 comes first) and before anything runs: no step of the request was run. |
        | 422 | `unprocessable` | A request other than steps can't be done right now; `error.reason` says why (`nothing_to_undo`, `nothing_to_redo`, `no_history`, `over_byte_limit`, `bad_image`, `too_large`, `unknown_document`, `same_document`). |
        | 500 | `internal` | Glimmer failed unexpectedly. The message has the detail. |

        ## Operations

        These are the `op` values for `steps`, with their `params`. The same list is available as JSON from `GET /api/v1/operations`.

        """
        for op in AgentPlanner.ops where (heal || op.name != "heal_selection") && (raw || op.name != "develop_raw") {
            s += "\n### `\(op.name)`\(paidOps.contains(op.name) ? " (paid)" : "")\n\n\(op.description)\n"
            if op.params.isEmpty {
                s += "\nNo params: `{\"op\": \"\(op.name)\"}`\n"
                continue
            }
            s += "\n| Param | Type | Description |\n|---|---|---|\n"
            for p in op.params {
                var description = p.description.replacingOccurrences(of: "|", with: "\\|")
                if !description.localizedCaseInsensitiveContains("optional") { description = "Required. " + description }
                if let options = p.options {
                    description += options.count > 40 ? " One of the ids in the table below."
                        : " One of: `" + options.joined(separator: "`, `") + "`"
                }
                s += "| `\(p.name)` | \(p.type) | \(description) |\n"
            }
            if op.name == "run_command" {
                s += "\n| Command id | What it does |\n|---|---|\n"
                for d in AgentPlanner.runnableCommands {
                    s += "| `\(d.id.rawValue)` | \(d.title.replacingOccurrences(of: "…", with: "")) |\n"
                }
            }
        }
        s += """

        ## Good to know

        - A parameter an operation or an endpoint doesn't have is refused by name with 400, and nothing is applied: in a `steps` request no step runs. Settings go inside a step's `params`; the settings of `add_adjustment`, `apply_filter` and `add_layer_effect` are checked against their `type`. So a 200 means every value you sent was used.
        - Adjustment layers are non-destructive; filters change pixels. Prefer `add_adjustment` for tone and colour.
        - `auto_enhance` and `auto_color` add editable adjustment layers, worked out on the Mac.
        - After a step, `GET /api/v1/documents/{id}/image` shows you what the user sees.
        - To combine two images: open the first as a document, then send the second to `POST /api/v1/documents/{id}/layers` (its bytes, or `fromDocument` if it is already open as a document). Either way works for any caller. Place it with `x` and `y` when you add it, or afterwards with `transform_layer` (`moveX`, `moveY`); blend it with `set_layer`, cut it out with `remove_background`.
        - `resize_canvas` adds room around the image (`crop` can only take room away). To get a shape such as 16:9: `crop` with `aspect` cuts the image down to it; `resize_canvas` with `aspect` and `anchor` adds room instead, for example beside a person for a title. Use `crop` when the image has more than you need, `resize_canvas` when it has too little.
        - `crop`, `resize_image`, `resize_canvas` and `select_rect` count in document pixels, from the top-left corner. A crop that contradicts itself (a rectangle and an aspect, say) is a 400, not a failed step.
        - What leaves the Mac through this API: nothing, except for paid steps. A paid step sends its prompt and the picture it works on (the document, or the selected area) to the picture service chosen in Glimmer's Settings (OpenRouter unless the person chose another; a refusal names it), billed to the user's key there, and only with `allowPaid: true` and `allowUnknownPrice: true`. The API never calls a text model: you are the one planning, so the text service chosen in Glimmer's Settings (OpenRouter, Berget or Grunden) is not used by anything you send here.
        - \(objectRemovalNote(heal: heal))
        - A layer's `bounds` are where its visible content is, in document pixels, after its mask; they can reach outside the canvas when content hangs over the edge.
        - `maxSide` only ever makes an image smaller.
        - Size limits: a side is at most 30000 pixels; an opened image at most 256 megapixels; and a canvas may not need more than two fifths of the Mac's memory for one layer (8 bytes a pixel: 800 megapixels on a 16 GB Mac). A new document, `resize_image` or `resize_canvas` beyond that is refused with reason `too_large` and the numbers. Many large layers make a document slow long before that: 60 layers at 6000 × 4000 take about 5.5 GB.
        - The user may be editing the same document. Read the document before you act on it, and keep requests small.

        """
        return s
    }
}
