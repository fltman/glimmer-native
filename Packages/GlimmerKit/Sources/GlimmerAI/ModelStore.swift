import CoreML
import CryptoKit
import Foundation

/// On-device models Glimmer downloads when the person asks (Apple's Core ML conversions
/// on Hugging Face, at a pinned commit, every file checked), then compiles and keeps in Application Support.
/// A model that isn't on the Mac yet couldn't be fetched (offline, or the server didn't answer).
public struct ModelDownloadError: LocalizedError, Equatable {
    public let model: String
    public let underlying: String

    public init(model: String, underlying: String) {
        self.model = model
        self.underlying = underlying
    }

    public var errorDescription: String? {
        var why = underlying.trimmingCharacters(in: .whitespaces)
        // The system's "The operation couldn’t be completed." says nothing; keep what follows it.
        for filler in ["The operation couldn’t be completed.", "The operation couldn't be completed."] where why.hasPrefix(filler) {
            why = String(why.dropFirst(filler.count)).trimmingCharacters(in: .whitespaces)
        }
        if why.isEmpty { why = "no connection" }
        while why.hasSuffix(".") { why.removeLast() }
        return "This needs the model “\(model)”, which Glimmer downloads once, and the download didn't work: \(why). "
            + "Connect to the internet and try again. Everything that doesn't need this model keeps working offline."
    }
}

public enum OnDeviceModel: String, CaseIterable, Sendable {
    case depth
    case segmentAnything

    public var title: String {
        switch self {
        case .depth: "Depth (Depth Anything V2 Small)"
        case .segmentAnything: "Magic Select (SAM 2.1 Tiny)"
        }
    }

    /// Its entry in the register: source, pinned commit, every file's checksum, license.
    public var requirement: Requirement {
        switch self {
        case .depth: .depthAnything
        case .segmentAnything: .segmentAnything
        }
    }

    public static func with(requirement id: String) -> OnDeviceModel? { allCases.first { $0.requirement.id == id } }

    /// "apple/coreml-sam2.1-tiny"
    var repository: String { requirement.source.url.replacingOccurrences(of: "https://huggingface.co/", with: "") }

    /// The .mlpackage directories this model consists of.
    var packages: [String] {
        var seen: [String] = []
        for file in requirement.files {
            let package = String(file.path.split(separator: "/").first ?? "")
            if !seen.contains(package) { seen.append(package) }
        }
        return seen
    }

    public var approximateSize: String {
        ByteCountFormatter.string(fromByteCount: Int64(requirement.sizeBytes ?? 0), countStyle: .file)
    }
}

/// A model a feature needs isn't on this Mac. Nothing was downloaded: the person downloads it
/// in Glimmer's window (the question sheet, or Settings › Models), never an API call.
public struct ModelMissingError: LocalizedError, Equatable, Sendable {
    public let missing: [OnDeviceModel]

    public init(_ missing: [OnDeviceModel]) { self.missing = missing }

    public var errorDescription: String? {
        let names = missing.map { "“\($0.title)”" }.joined(separator: " and ")
        return "This needs \(missing.count == 1 ? "the model" : "the models") \(names), which \(missing.count == 1 ? "isn't" : "aren't") downloaded yet. "
            + "Download \(missing.count == 1 ? "it" : "them") in Glimmer › Settings › Models, then try again."
    }
}

/// A downloaded file isn't the one the register lists: the model is not installed.
public struct ModelChecksumError: LocalizedError, Equatable, Sendable {
    public let model: String
    public let file: String
    public let reason: String

    public var errorDescription: String? {
        "The download of “\(model)” didn't match its published checksum (\(file): \(reason)), so Glimmer didn't install it. "
            + "Nothing of it was kept. Try again later; if it keeps happening, check Settings › Models › Download from."
    }
}

/// An MLModel that can cross actors (Core ML predictions are thread-safe).
public final class LoadedModel: @unchecked Sendable {
    public let model: MLModel
    init(_ model: MLModel) { self.model = model }

    public func prediction(from input: MLFeatureProvider) async throws -> MLFeatureProvider {
        try await model.prediction(from: input)
    }
}

public actor ModelStore {
    public static let shared = ModelStore()

    /// Where compiled models live. Tests can point at pre-downloaded packages with
    /// the GLIMMER_MODELS_DIR environment variable.
    let root: URL
    private let sourceOverride: URL?
    private var loaded: [String: LoadedModel] = [:]

    /// Where this store downloads from; nil means `ModelStore.source` (Settings › Models). Tests name a sample server.
    private let downloadSource: URL?

    public init(root: URL? = nil, source: URL? = nil) {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        self.root = root ?? support.appending(path: "Glimmer/Models")
        self.sourceOverride = ProcessInfo.processInfo.environment["GLIMMER_MODELS_DIR"].map { URL(fileURLWithPath: $0) }
        self.downloadSource = source
    }

    /// Where models are downloaded from: Hugging Face (Apple's Core ML conversions)
    /// unless Settings › Models names a mirror with the same paths (<repository>/resolve/<commit>/<file>).
    public static let defaultSource = "https://huggingface.co"
    public static let sourceKey = "models.source"
    public static var source: URL {
        let text = (UserDefaults.standard.string(forKey: sourceKey) ?? "").trimmingCharacters(in: .whitespaces)
        if let url = URL(string: text), ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host() != nil { return url }
        return URL(string: defaultSource)!
    }

    /// True when every package of `model` is compiled on this Mac (or in GLIMMER_MODELS_DIR for tests).
    public nonisolated func isInstalled(_ model: OnDeviceModel) -> Bool {
        model.packages.allSatisfy { FileManager.default.fileExists(atPath: compiledURL($0).path) }
            || (sourceOverride.map { dir in model.packages.allSatisfy { FileManager.default.fileExists(atPath: dir.appending(path: $0).path) } } ?? false)
    }

    /// Those of `models` that aren't on this Mac.
    public nonisolated func missing(_ models: [OnDeviceModel]) -> [OnDeviceModel] { models.filter { !isInstalled($0) } }

    nonisolated func compiledURL(_ package: String) -> URL {
        root.appending(path: package.replacingOccurrences(of: ".mlpackage", with: ".mlmodelc"))
    }

    /// Loads one package of `model`. Never downloads: a model that isn't on the Mac throws
    /// `ModelMissingError`, and the window asks the person (see `download`).
    public func load(_ package: String, of model: OnDeviceModel) async throws -> LoadedModel {
        if let m = loaded[package] { return m }
        let compiled = compiledURL(package)
        if !FileManager.default.fileExists(atPath: compiled.path) {
            guard let dir = sourceOverride, FileManager.default.fileExists(atPath: dir.appending(path: package).path) else {
                throw ModelMissingError([model])
            }
            try await install(compiling: dir.appending(path: package), to: compiled)
        }
        let config = MLModelConfiguration()
        config.computeUnits = .all
        let m = LoadedModel(try MLModel(contentsOf: compiled, configuration: config))
        loaded[package] = m
        return m
    }

    private var inFlight: [OnDeviceModel: Task<Void, Error>] = [:]

    /// Downloads `model` at its pinned commit, checks every file against the register, then
    /// compiles it. Only the person's click in Glimmer's window calls this. A file whose
    /// size or checksum is wrong stops it: nothing is installed and nothing is kept.
    public func download(_ model: OnDeviceModel, progress: (@Sendable (Double) -> Void)? = nil) async throws {
        if let running = inFlight[model] { return try await running.value }
        let task = Task { try await self.performDownload(model, progress: progress) }
        inFlight[model] = task
        defer { inFlight[model] = nil }
        try await task.value
    }

    private func performDownload(_ model: OnDeviceModel, progress: (@Sendable (Double) -> Void)?) async throws {
        let r = model.requirement
        guard let commit = r.source.commit else { throw URLError(.badURL) }
        let base = (downloadSource ?? Self.source).appending(path: "\(model.repository)/resolve/\(commit)")
        let staging = FileManager.default.temporaryDirectory.appending(path: "glimmer-models/\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: staging) }
        do {
            try await Self.fetchVerified(r.files, from: base, into: staging, model: model.title, progress: progress)
        } catch let e as ModelChecksumError {
            throw e
        } catch {
            throw ModelDownloadError(model: model.title, underlying: (error as NSError).localizedDescription)
        }
        for package in model.packages where !FileManager.default.fileExists(atPath: compiledURL(package).path) {
            try await install(compiling: staging.appending(path: package), to: compiledURL(package))
        }
    }

    private func install(compiling package: URL, to compiled: URL) async throws {
        let temp = try await MLModel.compileModel(at: package)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: compiled)
        try FileManager.default.moveItem(at: temp, to: compiled)
    }

    /// Removes a downloaded model.
    public func remove(_ model: OnDeviceModel) throws {
        for package in model.packages {
            loaded[package] = nil
            try? FileManager.default.removeItem(at: compiledURL(package))
        }
    }

    /// Fetches `files` from `base/<path>` into `staging/<path>`, each checked as it arrives:
    /// its size, then its SHA-256 or (for a file kept in git) its git blob id. The first file that
    /// differs throws `ModelChecksumError`, and the caller drops the whole folder.
    static func fetchVerified(_ files: [Requirement.File], from base: URL, into staging: URL, model: String,
                              session: URLSession = .shared, progress: (@Sendable (Double) -> Void)?) async throws {
        let total = Double(max(files.reduce(0) { $0 + $1.size }, 1))
        var done = 0
        for file in files {
            let (temp, response) = try await session.download(from: base.appending(path: file.path))
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                try? FileManager.default.removeItem(at: temp)
                throw URLError(.badServerResponse)
            }
            let dest = staging.appending(path: file.path)
            try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: temp, to: dest)
            if let problem = try FileChecksum.mismatch(at: dest, expected: file) {
                throw ModelChecksumError(model: model, file: file.path, reason: problem)
            }
            done += file.size
            progress?(Double(done) / total)
        }
    }
}

/// SHA-256 and git blob ids of files, read in pieces (a model's weights are tens of MB).
enum FileChecksum {
    /// Why the file at `url` isn't `expected`, or nil when it is.
    static func mismatch(at url: URL, expected: Requirement.File) throws -> String? {
        let size = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? -1
        guard size == expected.size else { return "\(size) bytes, not \(expected.size)" }
        if let sha = expected.sha256 {
            let found = try sha256(of: url)
            return found == sha ? nil : "SHA-256 \(found), not \(sha)"
        }
        if let blob = expected.gitBlob {
            let found = try gitBlob(of: url, size: size)
            return found == blob ? nil : "git blob \(found), not \(blob)"
        }
        return "the register lists no checksum for it"
    }

    static func sha256(of url: URL) throws -> String {
        var hash = SHA256()
        try read(url) { hash.update(data: $0) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// git's id of a file: SHA-1 of "blob <size>\0" followed by the bytes.
    static func gitBlob(of url: URL, size: Int) throws -> String {
        var hash = Insecure.SHA1()
        hash.update(data: Data("blob \(size)\u{0}".utf8))
        try read(url) { hash.update(data: $0) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func read(_ url: URL, _ body: (Data) -> Void) throws {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty { body(chunk) }
    }
}
