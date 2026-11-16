import Foundation
import GlimmerCore

/// Image models of services other than OpenRouter: OpenAI, Google, fal and Hedra. Each takes
/// the one request shape all of Glimmer's picture features use (a prompt and up to a few
/// pictures in, one picture out), built from the service's documentation as read on
/// 2026-11-16. None has been tried with a real call; each stays hidden until one has.
///
/// The pictures always travel in the request as bytes (rule 10 of the-apps/PROVIDERS.md):
/// nothing here makes a service fetch from the Mac, and nothing is put on public storage.
enum ImageHTTP {
    /// Sends `request` and returns the body of a 2xx answer; anything else is the service's own words.
    static func send(_ request: URLRequest, provider: String, session: URLSession) async throws -> Data {
        let data: Data, response: URLResponse
        do { (data, response) = try await session.data(for: request) } catch {
            throw OpenRouterError.network(error.localizedDescription)
        }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw ProviderHTTPError(provider: provider, status: http.statusCode, message: ProviderHTTPError.message(from: data))
        }
        return data
    }

    static func json(_ data: Data, provider: String) throws -> [String: Any] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ProviderHTTPError(provider: provider, status: 200, message: "The answer wasn't in the form Glimmer expects.")
        }
        return json
    }

    static func post(_ url: URL, headers: [String: String], body: [String: Any]) throws -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 300
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    /// The picture in a base64 string or a `data:` URL.
    static func picture(base64 text: String) -> Data? {
        let encoded = text.hasPrefix("data:") ? text.split(separator: ",", maxSplits: 1).last.map(String.init) ?? "" : text
        return Data(base64Encoded: encoded, options: .ignoreUnknownCharacters)
    }

    static func result(_ data: Data?, provider: String, said: String? = nil) throws -> AIImageResult {
        guard let data, !data.isEmpty, let image = try? ImageImporter.image(from: data) else {
            throw OpenRouterError.noImageInResponse(said ?? "\(provider) returned no picture.")
        }
        return AIImageResult(image: RGBAImage(image), cost: nil)
    }
}

/// OpenAI's Image API: `POST /v1/images/generations`, and `POST /v1/images/edits` with the
/// input pictures as data URLs ("A fully qualified URL or base64-encoded data URL"). The
/// answer is base64 in `data[0].b64_json`.
public struct OpenAIImageModel: ImageModel {
    let key: String, model: String, baseURL: URL, session: URLSession
    public init(key: String, model: String, baseURL: URL = URL(string: "https://api.openai.com/v1")!, session: URLSession = .shared) {
        self.key = key; self.model = model; self.baseURL = baseURL; self.session = session
    }

    public func generate(prompt: String, images: [RGBAImage], seed: Int?) async throws -> AIImageResult {
        var body: [String: Any] = ["model": model, "prompt": prompt, "n": 1]
        let path: String
        if images.isEmpty {
            path = "images/generations"
        } else {
            path = "images/edits"
            body["images"] = images.map { ["image_url": "data:image/png;base64," + $0.limited(toMaxSide: 2048).pngData().base64EncodedString()] }
        }
        let request = try ImageHTTP.post(baseURL.appending(path: path), headers: ["Authorization": "Bearer \(key)"], body: body)
        let json = try ImageHTTP.json(try await ImageHTTP.send(request, provider: "OpenAI", session: session), provider: "OpenAI")
        let encoded = ((json["data"] as? [[String: Any]])?.first?["b64_json"] as? String).flatMap(ImageHTTP.picture(base64:))
        return try ImageHTTP.result(encoded, provider: "OpenAI")
    }
}

/// Google's image models through `generateContent` (the form with a documented REST body):
/// the prompt and the input pictures as `inline_data` parts; the picture comes back as an
/// inline part among the answer's parts.
public struct GoogleImageModel: ImageModel {
    let key: String, model: String, baseURL: URL, session: URLSession
    public init(key: String, model: String, baseURL: URL = URL(string: "https://generativelanguage.googleapis.com/v1")!, session: URLSession = .shared) {
        self.key = key; self.model = model; self.baseURL = baseURL; self.session = session
    }

    public func generate(prompt: String, images: [RGBAImage], seed: Int?) async throws -> AIImageResult {
        var parts: [[String: Any]] = [["text": prompt]]
        for image in images {
            parts.append(["inline_data": ["mime_type": "image/png", "data": image.limited(toMaxSide: 2048).pngData().base64EncodedString()]])
        }
        let request = try ImageHTTP.post(baseURL.appending(path: "models/\(model):generateContent"), headers: ["x-goog-api-key": key],
                                         body: ["contents": [["parts": parts]]])
        let json = try ImageHTTP.json(try await ImageHTTP.send(request, provider: "Google", session: session), provider: "Google")
        let answer = ((json["candidates"] as? [[String: Any]])?.first?["content"] as? [String: Any])?["parts"] as? [[String: Any]] ?? []
        var said: [String] = []
        for part in answer {
            if let text = part["text"] as? String { said.append(text) }
            let inline = (part["inlineData"] ?? part["inline_data"]) as? [String: Any]
            if let encoded = inline?["data"] as? String, let data = ImageHTTP.picture(base64: encoded) {
                return try ImageHTTP.result(data, provider: "Google")
            }
        }
        return try ImageHTTP.result(nil, provider: "Google", said: said.isEmpty ? nil : said.joined(separator: " "))
    }
}

/// fal, through its direct endpoint `https://fal.run/<model id>`. Input pictures go as data
/// URIs in `image_urls` and the result is asked for as a data URI (`sync_mode`), so nothing
/// is uploaded to fal's storage, which is public by default, and the result is not kept in
/// its request history. If a model refuses data URIs the call fails with fal's own message;
/// Glimmer never falls back to an upload.
public struct FalImageModel: ImageModel {
    let key: String, model: String, editModel: String, baseURL: URL, session: URLSession
    /// `editModel`: the model id for requests with input pictures (fal has separate ids for editing, usually `<id>/edit`).
    public init(key: String, model: String, editModel: String? = nil, baseURL: URL = URL(string: "https://fal.run")!, session: URLSession = .shared) {
        self.key = key; self.model = model; self.editModel = editModel ?? model + "/edit"; self.baseURL = baseURL; self.session = session
    }

    public func generate(prompt: String, images: [RGBAImage], seed: Int?) async throws -> AIImageResult {
        var body: [String: Any] = ["prompt": prompt, "num_images": 1, "sync_mode": true]
        if !images.isEmpty {
            body["image_urls"] = images.map { "data:image/png;base64," + $0.limited(toMaxSide: 2048).pngData().base64EncodedString() }
        }
        if let seed { body["seed"] = seed }
        let request = try ImageHTTP.post(baseURL.appending(path: images.isEmpty ? model : editModel), headers: ["Authorization": "Key \(key)"], body: body)
        let json = try ImageHTTP.json(try await ImageHTTP.send(request, provider: "fal", session: session), provider: "fal")
        guard let url = (json["images"] as? [[String: Any]])?.first?["url"] as? String else {
            return try ImageHTTP.result(nil, provider: "fal")
        }
        // With sync_mode the picture is in the answer. A plain URL would mean it was stored on
        // fal's side after all: it is not fetched, and the call fails rather than pretend.
        guard url.hasPrefix("data:") else {
            throw ProviderHTTPError(provider: "fal", status: 200, message: "fal returned a link instead of the picture itself. Glimmer asked for the picture in the answer and doesn't fetch stored results.")
        }
        return try ImageHTTP.result(ImageHTTP.picture(base64: url), provider: "fal")
    }
}

/// Hedra's v3 API: input pictures are uploaded as bytes (`POST /v3/files`, a private upload
/// handle that expires after an hour), the job is submitted (`POST /v3/models/<model>`),
/// waited for (`GET /v3/jobs/<id>/status`) and its result downloaded from a signed URL,
/// which is used once and never logged.
public struct HedraImageModel: ImageModel {
    let key: String, model: String, baseURL: URL, session: URLSession
    let pollInterval: Duration, deadline: Duration
    public init(key: String, model: String, baseURL: URL = URL(string: "https://api.hedra.com/v3")!, session: URLSession = .shared,
                pollInterval: Duration = .seconds(3), deadline: Duration = .seconds(600)) {
        self.key = key; self.model = model; self.baseURL = baseURL; self.session = session
        self.pollInterval = pollInterval; self.deadline = deadline
    }

    private var headers: [String: String] { ["Authorization": "Key \(key)"] }

    public func generate(prompt: String, images: [RGBAImage], seed: Int?) async throws -> AIImageResult {
        var input: [String: Any] = ["prompt": prompt]
        if !images.isEmpty {
            var handles: [[String: Any]] = []
            for image in images { handles.append(["source": "url", "url": try await upload(image.limited(toMaxSide: 2048).pngData())]) }
            input["images"] = handles
        }
        let submit = try ImageHTTP.post(baseURL.appending(path: "models/\(model)"), headers: headers, body: ["input": input])
        let ack = try ImageHTTP.json(try await ImageHTTP.send(submit, provider: "Hedra", session: session), provider: "Hedra")
        guard let job = ack["job_id"] as? String else {
            throw ProviderHTTPError(provider: "Hedra", status: 202, message: "Hedra didn't return a job to wait for.")
        }
        let start = ContinuousClock.now
        while true {
            try Task.checkCancellation()
            var status = URLRequest(url: baseURL.appending(path: "jobs/\(job)/status"))
            for (name, value) in headers { status.setValue(value, forHTTPHeaderField: name) }
            let state = try ImageHTTP.json(try await ImageHTTP.send(status, provider: "Hedra", session: session), provider: "Hedra")["status"] as? String
            if state == "COMPLETED" { break }
            if state == "FAILED" { throw ProviderHTTPError(provider: "Hedra", status: 200, message: "The job failed at Hedra.") }
            guard ContinuousClock.now - start < deadline else {
                throw ProviderHTTPError(provider: "Hedra", status: 200, message: "Hedra's job didn't finish in time.")
            }
            try await Task.sleep(for: pollInterval)
        }
        var get = URLRequest(url: baseURL.appending(path: "jobs/\(job)"))
        for (name, value) in headers { get.setValue(value, forHTTPHeaderField: name) }
        let result = try ImageHTTP.json(try await ImageHTTP.send(get, provider: "Hedra", session: session), provider: "Hedra")
        guard let output = (result["outputs"] as? [[String: Any]])?.first, output["status"] as? String == "COMPLETED",
              let link = (output["url"] as? String).flatMap(URL.init) else {
            return try ImageHTTP.result(nil, provider: "Hedra")
        }
        // The signed URL carries its own authorisation: no key is sent with it, and it is not written anywhere.
        var download = URLRequest(url: link)
        download.timeoutInterval = 120
        return try ImageHTTP.result(try await ImageHTTP.send(download, provider: "Hedra", session: session), provider: "Hedra")
    }

    /// Uploads a picture's bytes; returns the handle to put in the job's input.
    private func upload(_ png: Data) async throws -> String {
        let boundary = "glimmer-" + UUID().uuidString
        var request = URLRequest(url: baseURL.appending(path: "files"))
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        var body = Data()
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"input.png\"\r\nContent-Type: image/png\r\n\r\n".utf8))
        body.append(png)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        request.httpBody = body
        let json = try ImageHTTP.json(try await ImageHTTP.send(request, provider: "Hedra", session: session), provider: "Hedra")
        guard let handle = json["url"] as? String else {
            throw ProviderHTTPError(provider: "Hedra", status: 200, message: "Hedra didn't return a handle for the uploaded picture.")
        }
        return handle
    }
}
