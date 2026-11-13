import Foundation
import Metal
import Synchronization

public enum GlimmerPackageError: Error, Equatable, LocalizedError {
    case notAPackage
    case missingManifest
    case unsupportedFormatVersion(Int)
    case corruptManifest(String)
    case corruptLayer(String)

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
        case .corruptLayer(let reason):
            "A layer in the document is damaged: \(reason)"
        }
    }
}

/// Reads and writes the `.glimmer` package layout:
///
/// ```
/// Name.glimmer/
///   manifest.json
///   layers/<uuid>.tiles
/// ```
public enum GlimmerPackage {
    public static let manifestFilename = "manifest.json"
    public static let layersDirectory = "layers"
    /// Finder/QuickLook previews (PNG), read by the QuickLook extensions.
    public static let quickLookDirectory = "QuickLook"
    public static let thumbnailFilename = "Thumbnail.png"
    public static let previewFilename = "Preview.png"

    // MARK: Write

    /// - Parameter cache: reuses encoded tile files whose tiles haven't changed.
    public static func fileWrapper(for state: DocumentState, cache: EncodedLayerCache? = nil,
                                   quickLook: (thumbnail: Data, preview: Data)? = nil) throws -> FileWrapper {
        var tileFiles: [String: FileWrapper] = [:]
        func addTiles(_ grid: TileGrid, name: String) throws {
            let data = try cache?.data(for: grid) ?? TileCodec.encode(grid)
            let file = FileWrapper(regularFileWithContents: data)
            file.preferredFilename = name
            tileFiles[name] = file
        }

        func record(_ layer: Layer) throws -> LayerRecord {
            let id = layer.id.uuidString
            var r = LayerRecord(id: layer.id, name: layer.name, kind: .raster, visible: layer.isVisible,
                                opacity: layer.opacity, blendMode: layer.blendMode,
                                clipped: layer.isClipped ? true : nil,
                                effects: layer.effects.hasEnabled || layer.effects != LayerEffects() ? layer.effects : nil)
            if let mask = layer.mask {
                r.mask = .init(defaultValue: mask.defaultValue, enabled: mask.isEnabled,
                               density: mask.density, feather: mask.feather)
                try addTiles(mask.tiles, name: "\(id).mask.tiles")
            }
            switch layer.content {
            case .raster(let grid):
                r.kind = .raster
                try addTiles(grid, name: "\(id).tiles")
            case .adjustment(let adjustment):
                r.kind = .adjustment
                r.adjustment = adjustment
            case .fill(let fill):
                r.kind = .fill
                r.fill = fill
            case .smart(let smart):
                r.kind = .smart
                r.smart = .init(width: smart.width, height: smart.height, transform: smart.transform)
                try addTiles(smart.source, name: "\(id).smart.tiles")
            case .text(let text):
                r.kind = .text
                r.text = text
            case .group(let group):
                r.kind = .group
                r.expanded = group.isExpanded
                r.children = try group.children.map(record)
            }
            return r
        }

        var manifest = DocumentManifest(
            width: state.width, height: state.height,
            colorSpace: state.colorSpace, blendSpace: state.blendSpace,
            layers: try state.layers.map(record),
            activeLayerID: state.activeLayerID
        )
        manifest.paths = state.paths.isEmpty ? nil : state.paths
        manifest.aids = state.aids == ViewAids() ? nil : state.aids
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let manifestFile = FileWrapper(regularFileWithContents: try encoder.encode(manifest))
        manifestFile.preferredFilename = manifestFilename

        let layersDir = FileWrapper(directoryWithFileWrappers: tileFiles)
        layersDir.preferredFilename = layersDirectory
        var root: [String: FileWrapper] = [manifestFilename: manifestFile, layersDirectory: layersDir]
        if let quickLook {
            let thumb = FileWrapper(regularFileWithContents: quickLook.thumbnail)
            thumb.preferredFilename = thumbnailFilename
            let preview = FileWrapper(regularFileWithContents: quickLook.preview)
            preview.preferredFilename = previewFilename
            let dir = FileWrapper(directoryWithFileWrappers: [thumbnailFilename: thumb, previewFilename: preview])
            dir.preferredFilename = quickLookDirectory
            root[quickLookDirectory] = dir
        }
        return FileWrapper(directoryWithFileWrappers: root)
    }

    // MARK: Read

    public static func state(from wrapper: FileWrapper) throws -> DocumentState {
        guard wrapper.isDirectory else { throw GlimmerPackageError.notAPackage }
        guard let data = wrapper.fileWrappers?[manifestFilename]?.regularFileContents else {
            throw GlimmerPackageError.missingManifest
        }
        let manifest = try decodeManifest(data)
        let files = wrapper.fileWrappers?[layersDirectory]?.fileWrappers ?? [:]

        func tiles(_ name: String, for record: LayerRecord) throws -> TileGrid {
            guard let data = files[name]?.regularFileContents else {
                throw GlimmerPackageError.corruptLayer("missing pixels for “\(record.name)”")
            }
            return try TileCodec.decode(data)
        }

        func layer(_ r: LayerRecord) throws -> Layer {
            let id = r.id.uuidString
            let content: LayerContent
            switch r.kind {
            case .raster:
                content = .raster(try tiles("\(id).tiles", for: r))
            case .adjustment:
                guard let a = r.adjustment else { throw GlimmerPackageError.corruptLayer("adjustment “\(r.name)”") }
                content = .adjustment(a)
            case .fill:
                guard let f = r.fill else { throw GlimmerPackageError.corruptLayer("fill “\(r.name)”") }
                content = .fill(f)
            case .smart:
                guard let s = r.smart else { throw GlimmerPackageError.corruptLayer("smart object “\(r.name)”") }
                content = .smart(SmartObject(source: try tiles("\(id).smart.tiles", for: r),
                                             width: s.width, height: s.height, transform: s.transform))
            case .text:
                guard let t = r.text else { throw GlimmerPackageError.corruptLayer("text “\(r.name)”") }
                content = .text(t)
            case .group:
                content = .group(LayerGroup(children: try (r.children ?? []).map(layer), isExpanded: r.expanded ?? true))
            }
            var mask: LayerMask?
            if let m = r.mask {
                mask = LayerMask(tiles: try tiles("\(id).mask.tiles", for: r), defaultValue: m.defaultValue,
                                 isEnabled: m.enabled, density: min(max(m.density, 0), 1), feather: max(0, m.feather))
            }
            return Layer(id: r.id, name: r.name, isVisible: r.visible, opacity: min(max(r.opacity, 0), 1),
                         blendMode: r.blendMode, mask: mask, isClipped: r.clipped ?? false,
                         effects: r.effects ?? LayerEffects(), content: content)
        }

        let layers = try manifest.layers.map(layer)
        var state = DocumentState(
            width: manifest.width, height: manifest.height,
            colorSpace: manifest.colorSpace, blendSpace: manifest.blendSpace, layers: layers)
        if state.path(of: manifest.activeLayerID) != nil { state.activeLayerID = manifest.activeLayerID }
        state.paths = manifest.paths ?? []
        state.aids = manifest.aids ?? ViewAids()
        return state
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

/// Remembers encoded layer files by tile identity so autosave only re-encodes
/// layers that changed. Safe to use from the background writer.
public final class EncodedLayerCache: Sendable {
    private let entries = Mutex<[Int: Data]>([:])
    private let limit: Int

    public init(limit: Int = 64) {
        self.limit = limit
    }

    public func data(for tiles: TileGrid) throws -> Data {
        let key = tiles.contentSignature
        if let hit = entries.withLock({ $0[key] }) { return hit }
        let data = try TileCodec.encode(tiles)
        entries.withLock { dict in
            if dict.count >= limit { dict.removeAll() }
            dict[key] = data
        }
        return data
    }
}

/// Binary layer pixel format (little-endian):
///
/// ```
/// "GLTL" | version u32 | tileSize u32 | count u32
/// per tile: x i32 | y i32 | kind u8
///   kind 0 (solid): r g b a f32
///   kind 1 (lzfse):  byteCount u32 | LZFSE(Float16 RGBA, 256×256, row-major)
/// ```
public enum TileCodec {
    static let magic: [UInt8] = Array("GLTL".utf8)
    static let version: UInt32 = 1

    public static func encode(_ grid: TileGrid) throws -> Data {
        var out = Data()
        out.append(contentsOf: magic)
        out.appendLE(version)
        out.appendLE(UInt32(TileGeometry.size))
        out.appendLE(UInt32(grid.count))
        for coord in grid.tiles.keys.sorted() {
            out.appendLE(Int32(coord.x))
            out.appendLE(Int32(coord.y))
            switch grid[coord]! {
            case .solid(let c):
                out.append(0)
                for v in [c.x, c.y, c.z, c.w] { out.appendLE(v.bitPattern) }
            case .texture:
                out.append(1)
                let raw = grid[coord]!.pixels().withUnsafeBytes { Data($0) }
                let compressed = try (raw as NSData).compressed(using: .lzfse) as Data
                out.appendLE(UInt32(compressed.count))
                out.append(compressed)
            }
        }
        return out
    }

    public static func decode(_ data: Data) throws -> TileGrid {
        var reader = ByteReader(data: data)
        guard try reader.bytes(4) == magic else { throw GlimmerPackageError.corruptLayer("bad magic") }
        let version: UInt32 = try reader.read()
        guard version <= Self.version else { throw GlimmerPackageError.corruptLayer("tile format \(version)") }
        let size: UInt32 = try reader.read()
        guard size == TileGeometry.size else { throw GlimmerPackageError.corruptLayer("tile size \(size)") }
        let count: UInt32 = try reader.read()

        var grid = TileGrid()
        for _ in 0..<count {
            let x: Int32 = try reader.read()
            let y: Int32 = try reader.read()
            let kind: UInt8 = try reader.read()
            let coord = TileCoord(Int(x), Int(y))
            switch kind {
            case 0:
                let r: UInt32 = try reader.read(), g: UInt32 = try reader.read()
                let b: UInt32 = try reader.read(), a: UInt32 = try reader.read()
                grid[coord] = .solid(SIMD4(Float(bitPattern: r), Float(bitPattern: g),
                                           Float(bitPattern: b), Float(bitPattern: a)))
            case 1:
                let length: UInt32 = try reader.read()
                let compressed = try reader.data(Int(length))
                let raw: Data
                do {
                    raw = try (compressed as NSData).decompressed(using: .lzfse) as Data
                } catch {
                    throw GlimmerPackageError.corruptLayer("tile \(x),\(y) does not decompress")
                }
                guard raw.count == TileGeometry.byteCount else {
                    throw GlimmerPackageError.corruptLayer("tile \(x),\(y) has \(raw.count) bytes")
                }
                let texture = TileTexture.makeTexture()
                raw.withUnsafeBytes { bytes in
                    texture.replace(region: MTLRegionMake2D(0, 0, TileGeometry.size, TileGeometry.size),
                                    mipmapLevel: 0, withBytes: bytes.baseAddress!,
                                    bytesPerRow: TileGeometry.bytesPerRow)
                }
                grid[coord] = .texture(TileTexture(texture))
            default:
                throw GlimmerPackageError.corruptLayer("unknown tile kind \(kind)")
            }
        }
        return grid
    }
}

private struct ByteReader {
    let data: Data
    var offset = 0

    mutating func bytes(_ n: Int) throws -> [UInt8] {
        [UInt8](try self.data(n))
    }

    mutating func data(_ n: Int) throws -> Data {
        guard n >= 0, offset + n <= data.count else {
            throw GlimmerPackageError.corruptLayer("truncated")
        }
        let start = data.startIndex + offset
        offset += n
        return data.subdata(in: start..<(start + n))
    }

    mutating func read<T: FixedWidthInteger>() throws -> T {
        let bytes = try data(MemoryLayout<T>.size)
        return bytes.withUnsafeBytes { T(littleEndian: $0.loadUnaligned(as: T.self)) }
    }
}

private extension Data {
    mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }
}
