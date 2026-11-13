import Foundation

public enum GlimmerPackageError: Error, Equatable, LocalizedError {
    case notAPackage
    case missingManifest
    case unsupportedFormatVersion(Int)
    case corruptManifest(String)

    public var errorDescription: String? {
        switch self {
        case .notAPackage:
            "The file is not a Glimmer document package."
        case .missingManifest:
            "The document is missing its manifest."
        case .unsupportedFormatVersion(let v):
            "The document was saved by a newer version of Glimmer (format \(v))."
        case .corruptManifest(let reason):
            "The document manifest is damaged: \(reason)"
        }
    }
}

/// Reads and writes the `.glimmer` package layout:
///
/// ```
/// Name.glimmer/
///   manifest.json
/// ```
///
/// Later phases add `layers/`, `smart/` and `thumbnail.png`.
public enum GlimmerPackage {
    public static let manifestFilename = "manifest.json"

    public static func fileWrapper(for manifest: DocumentManifest) throws -> FileWrapper {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let manifestFile = FileWrapper(regularFileWithContents: try encoder.encode(manifest))
        manifestFile.preferredFilename = manifestFilename
        return FileWrapper(directoryWithFileWrappers: [manifestFilename: manifestFile])
    }

    public static func manifest(from wrapper: FileWrapper) throws -> DocumentManifest {
        guard wrapper.isDirectory else { throw GlimmerPackageError.notAPackage }
        guard let data = wrapper.fileWrappers?[manifestFilename]?.regularFileContents else {
            throw GlimmerPackageError.missingManifest
        }
        return try decodeManifest(data)
    }

    static func decodeManifest(_ data: Data) throws -> DocumentManifest {
        struct VersionProbe: Decodable { var formatVersion: Int }
        let decoder = JSONDecoder()

        let version: Int
        do {
            version = try decoder.decode(VersionProbe.self, from: data).formatVersion
        } catch {
            throw GlimmerPackageError.corruptManifest("no format version")
        }
        guard version <= DocumentManifest.currentFormatVersion else {
            throw GlimmerPackageError.unsupportedFormatVersion(version)
        }

        let manifest: DocumentManifest
        do {
            manifest = try decoder.decode(DocumentManifest.self, from: data)
        } catch {
            throw GlimmerPackageError.corruptManifest(String(describing: error))
        }
        let range = 1...DocumentManifest.maxDimension
        guard range.contains(manifest.width), range.contains(manifest.height) else {
            throw GlimmerPackageError.corruptManifest("invalid size \(manifest.width)×\(manifest.height)")
        }
        return manifest
    }
}
