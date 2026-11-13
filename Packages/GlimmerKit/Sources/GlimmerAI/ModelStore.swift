import CoreML
import Foundation

/// On-device models Glimmer downloads on first use (Apple's Core ML conversions
/// on Hugging Face), then compiles and keeps in Application Support.
public enum OnDeviceModel: String, CaseIterable, Sendable {
    case depth
    case segmentAnything

    public var title: String {
        switch self {
        case .depth: "Depth (Depth Anything V2 Small)"
        case .segmentAnything: "Magic Select (SAM 2.1 Tiny)"
        }
    }

    var repository: String {
        switch self {
        case .depth: "apple/coreml-depth-anything-v2-small"
        case .segmentAnything: "apple/coreml-sam2.1-tiny"
        }
    }

    /// The .mlpackage directories this model consists of.
    var packages: [String] {
        switch self {
        case .depth: ["DepthAnythingV2SmallF16.mlpackage"]
        case .segmentAnything: ["SAM2_1TinyImageEncoderFLOAT16.mlpackage",
                                "SAM2_1TinyPromptEncoderFLOAT16.mlpackage",
                                "SAM2_1TinyMaskDecoderFLOAT16.mlpackage"]
        }
    }

    public var approximateSize: String {
        switch self {
        case .depth: "48 MB"
        case .segmentAnything: "78 MB"
        }
    }

    static let packageFiles = ["Manifest.json", "Data/com.apple.CoreML/model.mlmodel",
                               "Data/com.apple.CoreML/weights/weight.bin"]
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

    public init(root: URL? = nil) {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        self.root = root ?? support.appending(path: "Glimmer/Models")
        self.sourceOverride = ProcessInfo.processInfo.environment["GLIMMER_MODELS_DIR"].map { URL(fileURLWithPath: $0) }
    }

    public func isInstalled(_ model: OnDeviceModel) -> Bool {
        model.packages.allSatisfy { FileManager.default.fileExists(atPath: compiledURL($0).path) }
            || (sourceOverride.map { dir in model.packages.allSatisfy { FileManager.default.fileExists(atPath: dir.appending(path: $0).path) } } ?? false)
    }

    func compiledURL(_ package: String) -> URL {
        root.appending(path: package.replacingOccurrences(of: ".mlpackage", with: ".mlmodelc"))
    }

    /// Downloads (if needed), compiles and loads one package of `model`.
    public func load(_ package: String, of model: OnDeviceModel,
                     progress: (@Sendable (Double) -> Void)? = nil) async throws -> LoadedModel {
        if let m = loaded[package] { return m }
        let compiled = compiledURL(package)
        if !FileManager.default.fileExists(atPath: compiled.path) {
            let source: URL
            if let dir = sourceOverride, FileManager.default.fileExists(atPath: dir.appending(path: package).path) {
                source = dir.appending(path: package)
            } else {
                source = try await download(package, from: model.repository, progress: progress)
            }
            let temp = try await MLModel.compileModel(at: source)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: compiled)
            try FileManager.default.moveItem(at: temp, to: compiled)
        }
        let config = MLModelConfiguration()
        config.computeUnits = .all
        let m = LoadedModel(try MLModel(contentsOf: compiled, configuration: config))
        loaded[package] = m
        return m
    }

    /// Removes a downloaded model.
    public func remove(_ model: OnDeviceModel) throws {
        for package in model.packages {
            loaded[package] = nil
            try? FileManager.default.removeItem(at: compiledURL(package))
        }
    }

    private func download(_ package: String, from repository: String,
                          progress: (@Sendable (Double) -> Void)?) async throws -> URL {
        let staging = FileManager.default.temporaryDirectory.appending(path: "glimmer-models/\(UUID().uuidString)/\(package)")
        for (i, file) in OnDeviceModel.packageFiles.enumerated() {
            let url = URL(string: "https://huggingface.co/\(repository)/resolve/main/\(package)/\(file)")!
            let (temp, response) = try await URLSession.shared.download(from: url)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                throw URLError(.badServerResponse)
            }
            let dest = staging.appending(path: file)
            try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: temp, to: dest)
            progress?(Double(i + 1) / Double(OnDeviceModel.packageFiles.count))
        }
        return staging
    }
}
