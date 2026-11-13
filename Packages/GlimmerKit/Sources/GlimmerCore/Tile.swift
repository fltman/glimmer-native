import Metal
import Synchronization

/// The process-wide Metal device. Glimmer requires Apple silicon (unified memory),
/// so tiles live in `.shared` textures that both CPU and GPU can access without copies.
public enum GPU {
    public static let device: MTLDevice = {
        guard let device = MTLCreateSystemDefaultDevice() else {
            fatalError("Glimmer requires a Metal-capable GPU")
        }
        return device
    }()
}

public enum TileGeometry {
    public static let size = 256
    public static let pixelFormat = MTLPixelFormat.rgba16Float
    public static let bytesPerPixel = 8
    public static let bytesPerRow = size * bytesPerPixel
    public static let byteCount = size * bytesPerRow
}

public struct TileCoord: Hashable, Sendable, Comparable {
    public var x: Int
    public var y: Int

    public init(_ x: Int, _ y: Int) {
        self.x = x
        self.y = y
    }

    /// Top-left pixel of this tile in document space.
    public var origin: SIMD2<Int> { SIMD2(x * TileGeometry.size, y * TileGeometry.size) }

    public var rect: PixelRect {
        PixelRect(x: x * TileGeometry.size, y: y * TileGeometry.size,
                  width: TileGeometry.size, height: TileGeometry.size)
    }

    public static func < (a: TileCoord, b: TileCoord) -> Bool {
        a.y != b.y ? a.y < b.y : a.x < b.x
    }
}

/// Integer pixel rectangle, y-down.
public struct PixelRect: Equatable, Hashable, Sendable {
    public var x: Int
    public var y: Int
    public var width: Int
    public var height: Int

    public init(x: Int, y: Int, width: Int, height: Int) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public var maxX: Int { x + width }
    public var maxY: Int { y + height }
    public var isEmpty: Bool { width <= 0 || height <= 0 }

    public func intersection(_ other: PixelRect) -> PixelRect {
        let x0 = max(x, other.x), y0 = max(y, other.y)
        let x1 = min(maxX, other.maxX), y1 = min(maxY, other.maxY)
        return PixelRect(x: x0, y: y0, width: max(0, x1 - x0), height: max(0, y1 - y0))
    }

    public func offsetBy(_ dx: Int, _ dy: Int) -> PixelRect {
        PixelRect(x: x + dx, y: y + dy, width: width, height: height)
    }

    /// Tiles that overlap this rect.
    public var tileCoords: [TileCoord] {
        guard !isEmpty else { return [] }
        let s = TileGeometry.size
        let tx0 = Self.floorDiv(x, s), ty0 = Self.floorDiv(y, s)
        let tx1 = Self.floorDiv(maxX - 1, s), ty1 = Self.floorDiv(maxY - 1, s)
        var result: [TileCoord] = []
        result.reserveCapacity((tx1 - tx0 + 1) * (ty1 - ty0 + 1))
        for ty in ty0...ty1 {
            for tx in tx0...tx1 { result.append(TileCoord(tx, ty)) }
        }
        return result
    }

    static func floorDiv(_ a: Int, _ b: Int) -> Int {
        a >= 0 ? a / b : -((-a + b - 1) / b)
    }
}

/// An immutable GPU texture with a never-reused identity.
///
/// Textures are never written after a `TileTexture` is created (copy-on-write
/// discipline), so identity comparison is a valid change test for caches,
/// undo and incremental saves.
public final class TileTexture: @unchecked Sendable {
    private static let nextID = Atomic<UInt64>(1)

    public let id: UInt64
    public let texture: MTLTexture

    public init(_ texture: MTLTexture) {
        self.id = Self.nextID.add(1, ordering: .relaxed).oldValue
        self.texture = texture
    }

    /// A new, uninitialized tile-sized texture (shared storage).
    public static func makeTexture(device: MTLDevice = GPU.device) -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: TileGeometry.pixelFormat,
            width: TileGeometry.size, height: TileGeometry.size, mipmapped: false)
        descriptor.usage = [.shaderRead, .renderTarget]
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            fatalError("Out of GPU memory allocating a tile")
        }
        return texture
    }
}

/// One 256×256 block of premultiplied, linear, extended-sRGB pixels.
public enum Tile: Sendable {
    /// Every pixel has this colour (premultiplied linear). Costs no texture memory.
    case solid(SIMD4<Float>)
    case texture(TileTexture)

    /// Feeds the tile's identity (not its pixels) into `hasher`.
    public func combineIdentity(into hasher: inout Hasher) {
        switch self {
        case .solid(let c):
            hasher.combine(0)
            hasher.combine(c.x.bitPattern); hasher.combine(c.y.bitPattern)
            hasher.combine(c.z.bitPattern); hasher.combine(c.w.bitPattern)
        case .texture(let t):
            hasher.combine(1)
            hasher.combine(t.id)
        }
    }

    /// Raw Float16 RGBA pixels, row-major, 256×256.
    public func pixels() -> [Float16] {
        var result = [Float16](repeating: 0, count: TileGeometry.size * TileGeometry.size * 4)
        switch self {
        case .solid(let c):
            let h = [Float16(c.x), Float16(c.y), Float16(c.z), Float16(c.w)]
            for i in stride(from: 0, to: result.count, by: 4) {
                result[i] = h[0]; result[i + 1] = h[1]; result[i + 2] = h[2]; result[i + 3] = h[3]
            }
        case .texture(let t):
            result.withUnsafeMutableBytes { buffer in
                t.texture.getBytes(buffer.baseAddress!, bytesPerRow: TileGeometry.bytesPerRow,
                                   from: MTLRegionMake2D(0, 0, TileGeometry.size, TileGeometry.size),
                                   mipmapLevel: 0)
            }
        }
        return result
    }

    /// Builds a tile from 256×256 Float16 RGBA pixels. Returns nil when fully
    /// transparent and `.solid` when uniform.
    public static func make(
        pixels: UnsafeRawPointer, bytesPerRow: Int, device: MTLDevice = GPU.device
    ) -> Tile? {
        let size = TileGeometry.size
        let first = pixels.loadUnaligned(as: UInt64.self)
        var uniform = true
        var anyVisible = false
        for row in 0..<size {
            let rowPtr = pixels + row * bytesPerRow
            for col in 0..<size {
                let px = rowPtr.loadUnaligned(fromByteOffset: col * 8, as: UInt64.self)
                if px != first { uniform = false }
                // Alpha is the top 16 bits (little-endian RGBA); ignore the sign bit.
                if (px >> 48) & 0x7FFF != 0 { anyVisible = true }
                if !uniform && anyVisible { break }
            }
            if !uniform && anyVisible { break }
        }
        guard anyVisible else { return nil }
        if uniform {
            let h = pixels.loadUnaligned(as: SIMD4<Float16>.self)
            return .solid(SIMD4<Float>(h))
        }
        let texture = TileTexture.makeTexture(device: device)
        texture.replace(region: MTLRegionMake2D(0, 0, size, size), mipmapLevel: 0,
                        withBytes: pixels, bytesPerRow: bytesPerRow)
        return .texture(TileTexture(texture))
    }
}

/// A sparse grid of tiles. Missing coordinates are fully transparent.
/// Value semantics: copying a grid copies references to immutable tiles.
public struct TileGrid: Sendable {
    public private(set) var tiles: [TileCoord: Tile]

    public init(_ tiles: [TileCoord: Tile] = [:]) {
        self.tiles = tiles
    }

    public subscript(coord: TileCoord) -> Tile? {
        get { tiles[coord] }
        set { tiles[coord] = newValue }
    }

    public var isEmpty: Bool { tiles.isEmpty }
    public var count: Int { tiles.count }

    /// A grid filled with one colour over every tile touching `rect`.
    public static func solid(_ color: SIMD4<Float>, covering rect: PixelRect) -> TileGrid {
        var grid = TileGrid()
        for coord in rect.tileCoords { grid[coord] = .solid(color) }
        return grid
    }

    /// Bounding rect of all stored tiles (tile-aligned), nil when empty.
    public var tileBounds: PixelRect? {
        guard let first = tiles.keys.first else { return nil }
        var minX = first.x, minY = first.y, maxX = first.x, maxY = first.y
        for c in tiles.keys {
            minX = min(minX, c.x); minY = min(minY, c.y)
            maxX = max(maxX, c.x); maxY = max(maxY, c.y)
        }
        let s = TileGeometry.size
        return PixelRect(x: minX * s, y: minY * s, width: (maxX - minX + 1) * s, height: (maxY - minY + 1) * s)
    }

    /// Hash of the tile identities. Equal grids hash equal; any edit changes it.
    public var contentSignature: Int {
        var hasher = Hasher()
        for coord in tiles.keys.sorted() {
            hasher.combine(coord)
            tiles[coord]!.combineIdentity(into: &hasher)
        }
        return hasher.finalize()
    }
}
