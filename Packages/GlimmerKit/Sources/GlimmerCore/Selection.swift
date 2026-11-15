import CoreGraphics
import Foundation

/// A soft pixel selection in document space: 1 = selected, 0 = not.
/// Stored tiles hold the value in every channel; missing tiles use `defaultValue`.
public struct Selection: Sendable {
    public var tiles: TileGrid
    public var defaultValue: Float

    public init(tiles: TileGrid = TileGrid(), defaultValue: Float = 0) {
        self.tiles = tiles
        self.defaultValue = defaultValue
    }

    public enum Operation: Sendable {
        case replace, add, subtract, intersect
    }

    public static func all() -> Selection { Selection(defaultValue: 1) }

    // MARK: Shapes

    public static func rectangle(_ r: CGRectLike) -> Selection {
        rasterize(bounds: r.pixelBounds) { x, y in
            // Exact area of the pixel square inside the rectangle.
            let w = max(0, min(Double(x + 1), r.maxX) - max(Double(x), r.minX))
            let h = max(0, min(Double(y + 1), r.maxY) - max(Double(y), r.minY))
            return Float(w * h)
        }
    }

    public static func ellipse(in r: CGRectLike) -> Selection {
        let cx = (r.minX + r.maxX) / 2, cy = (r.minY + r.maxY) / 2
        let rx = max((r.maxX - r.minX) / 2, 1e-6), ry = max((r.maxY - r.minY) / 2, 1e-6)
        return rasterize(bounds: r.pixelBounds) { x, y in
            // Approximate signed distance to the ellipse edge, 1 px anti-aliasing.
            let dx = (Double(x) + 0.5 - cx) / rx, dy = (Double(y) + 0.5 - cy) / ry
            let f = (dx * dx + dy * dy).squareRoot()
            let d = (f - 1) * min(rx, ry)
            return Float(min(max(0.5 - d, 0), 1))
        }
    }

    /// A closed polygon (lasso), anti-aliased, even-odd filled.
    public static func polygon(_ points: [SIMD2<Double>]) -> Selection { polygons([points]) }

    /// The union of several polygons (each filled even-odd), rasterized in one pass:
    /// combining them one by one costs a full selection merge per polygon.
    public static func polygons(_ list: [[SIMD2<Double>]]) -> Selection {
        let list = list.filter { $0.count >= 3 }
        guard !list.isEmpty else { return Selection() }
        let points = list.flatMap { $0 }
        let xs = points.map(\.x), ys = points.map(\.y)
        let x0 = Int(xs.min()!.rounded(.down)) - 1, y0 = Int(ys.min()!.rounded(.down)) - 1
        let x1 = Int(xs.max()!.rounded(.up)) + 1, y1 = Int(ys.max()!.rounded(.up)) + 1
        let w = x1 - x0, h = y1 - y0
        guard w > 0, h > 0, w * h < 400_000_000,
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else {
            return Selection()
        }
        ctx.setShouldAntialias(true)
        ctx.setFillColor(gray: 1, alpha: 1)
        // Flip so rows run top-down like document space.
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: 1, y: -1)
        for polygon in list {
            ctx.beginPath()
            ctx.move(to: CGPoint(x: polygon[0].x - Double(x0), y: polygon[0].y - Double(y0)))
            for p in polygon.dropFirst() { ctx.addLine(to: CGPoint(x: p.x - Double(x0), y: p.y - Double(y0))) }
            ctx.closePath()
            ctx.fillPath(using: .evenOdd)
        }
        guard let data = ctx.data else { return Selection() }
        let bytes = data.assumingMemoryBound(to: UInt8.self)
        let rect = PixelRect(x: x0, y: y0, width: w, height: h)
        return rasterize(bounds: rect) { x, y in Float(bytes[(y - y0) * w + (x - x0)]) / 255 }
    }

    /// Builds a selection from per-pixel values over `bounds` (everything else 0).
    public static func rasterize(bounds: PixelRect, _ value: (Int, Int) -> Float) -> Selection {
        var grid = TileGrid()
        let s = TileGeometry.size
        var buffer = [Float16](repeating: 0, count: s * s * 4)
        for coord in bounds.tileCoords {
            for i in buffer.indices { buffer[i] = 0 }
            let part = coord.rect.intersection(bounds)
            for y in part.y..<part.maxY {
                for x in part.x..<part.maxX {
                    let v = Float16(value(x, y))
                    let o = ((y - coord.rect.y) * s + (x - coord.rect.x)) * 4
                    buffer[o] = v; buffer[o + 1] = v; buffer[o + 2] = v; buffer[o + 3] = v
                }
            }
            buffer.withUnsafeBytes {
                if let tile = Tile.make(pixels: $0.baseAddress!, bytesPerRow: TileGeometry.bytesPerRow) {
                    grid[coord] = tile
                }
            }
        }
        return Selection(tiles: grid)
    }

    /// Builds a selection from a mask covering `rect` (values 0...1, row-major).
    public static func from(mask: [Float], rect: PixelRect) -> Selection {
        rasterize(bounds: rect) { x, y in mask[(y - rect.y) * rect.width + (x - rect.x)] }
    }

    // MARK: Combining

    public func combined(with other: Selection, _ op: Operation) -> Selection {
        func f(_ a: Float, _ b: Float) -> Float {
            switch op {
            case .replace: b
            case .add: max(a, b)
            case .subtract: a * (1 - b)
            case .intersect: min(a, b)
            }
        }
        if op == .replace { return other }
        var grid = TileGrid()
        let coords = Set(tiles.tiles.keys).union(other.tiles.tiles.keys)
        for coord in coords {
            let a = tile(at: coord).pixels(), b = other.tile(at: coord).pixels()
            var out = [Float16](repeating: 0, count: a.count)
            for i in stride(from: 0, to: a.count, by: 4) {
                let v = Float16(f(Float(a[i + 3]), Float(b[i + 3])))
                out[i] = v; out[i + 1] = v; out[i + 2] = v; out[i + 3] = v
            }
            out.withUnsafeBytes {
                grid[coord] = Tile.make(pixels: $0.baseAddress!, bytesPerRow: TileGeometry.bytesPerRow) ?? .solid(.zero)
            }
        }
        var result = Selection(tiles: grid, defaultValue: f(defaultValue, other.defaultValue))
        result.dropDefaultTiles()
        return result
    }

    public func inverted() -> Selection {
        var grid = TileGrid()
        for (coord, tile) in tiles.tiles {
            let p = tile.pixels()
            var out = [Float16](repeating: 0, count: p.count)
            for i in stride(from: 0, to: p.count, by: 4) {
                let v = Float16(1 - Float(p[i + 3]))
                out[i] = v; out[i + 1] = v; out[i + 2] = v; out[i + 3] = v
            }
            out.withUnsafeBytes {
                grid[coord] = Tile.make(pixels: $0.baseAddress!, bytesPerRow: TileGeometry.bytesPerRow) ?? .solid(.zero)
            }
        }
        return Selection(tiles: grid, defaultValue: 1 - defaultValue)
    }

    /// Removes stored tiles that equal the default value.
    mutating func dropDefaultTiles() {
        for (coord, tile) in tiles.tiles {
            if case .solid(let c) = tile, c.w == defaultValue { tiles[coord] = nil }
            if tile.isTransparentSolid, defaultValue == 0 { tiles[coord] = nil }
        }
    }

    // MARK: Reading

    public func tile(at coord: TileCoord) -> Tile {
        tiles[coord] ?? .solid(SIMD4(repeating: defaultValue))
    }

    /// Selection values (0...1) for `rect`, row-major.
    public func values(in rect: PixelRect) -> [Float] {
        var out = [Float](repeating: defaultValue, count: max(0, rect.width * rect.height))
        let s = TileGeometry.size
        for coord in rect.tileCoords {
            guard let tile = tiles[coord] else { continue }
            let p = tile.pixels()
            let part = coord.rect.intersection(rect)
            for y in part.y..<part.maxY {
                for x in part.x..<part.maxX {
                    out[(y - rect.y) * rect.width + (x - rect.x)] = Float(p[((y - coord.rect.y) * s + (x - coord.rect.x)) * 4 + 3])
                }
            }
        }
        return out
    }

    /// Tight bounds of selected pixels within `limit` (nil when nothing is selected).
    public func bounds(in limit: PixelRect) -> PixelRect? {
        if defaultValue > 0 { return limit }
        var minX = Int.max, minY = Int.max, maxX = Int.min, maxY = Int.min
        let s = TileGeometry.size
        for (coord, tile) in tiles.tiles {
            let part = coord.rect.intersection(limit)
            guard !part.isEmpty else { continue }
            if case .solid(let c) = tile {
                guard c.w > 0 else { continue }
                minX = min(minX, part.x); minY = min(minY, part.y)
                maxX = max(maxX, part.maxX); maxY = max(maxY, part.maxY)
                continue
            }
            let p = tile.pixels()
            for y in part.y..<part.maxY {
                for x in part.x..<part.maxX where p[((y - coord.rect.y) * s + (x - coord.rect.x)) * 4 + 3] > 0.002 {
                    minX = min(minX, x); minY = min(minY, y)
                    maxX = max(maxX, x + 1); maxY = max(maxY, y + 1)
                }
            }
        }
        guard minX < maxX else { return nil }
        return PixelRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// A layer mask with the same shape.
    public var asMask: LayerMask { LayerMask(tiles: tiles, defaultValue: defaultValue) }
}

extension Tile {
    var isTransparentSolid: Bool {
        if case .solid(let c) = self { return c == .zero }
        return false
    }
}

/// A floating-point rectangle (CoreGraphics-free so Core stays portable).
public struct CGRectLike: Equatable, Sendable {
    public var minX: Double, minY: Double, maxX: Double, maxY: Double

    public init(x0: Double, y0: Double, x1: Double, y1: Double) {
        minX = min(x0, x1); maxX = max(x0, x1)
        minY = min(y0, y1); maxY = max(y0, y1)
    }

    public var width: Double { maxX - minX }
    public var height: Double { maxY - minY }

    var pixelBounds: PixelRect {
        let x0 = Int(minX.rounded(.down)), y0 = Int(minY.rounded(.down))
        return PixelRect(x: x0, y: y0, width: Int(maxX.rounded(.up)) - x0, height: Int(maxY.rounded(.up)) - y0)
    }
}
