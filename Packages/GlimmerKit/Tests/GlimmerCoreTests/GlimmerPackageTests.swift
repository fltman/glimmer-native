import CoreGraphics
import Foundation
import Metal
import Testing
@testable import GlimmerCore

/// A tile with a gradient so it can't collapse to `.solid`.
func gradientTile(seed: Float = 0) -> Tile {
    let s = TileGeometry.size
    var px = [Float16](repeating: 0, count: s * s * 4)
    for y in 0..<s {
        for x in 0..<s {
            let i = (y * s + x) * 4
            px[i] = Float16(Float(x) / 255 * 0.5 + seed)
            px[i + 1] = Float16(Float(y) / 255 * 0.5)
            px[i + 2] = Float16(seed)
            px[i + 3] = Float16(0.5 + Float((x + y) % 2) * 0.5)
        }
    }
    return px.withUnsafeBytes { Tile.make(pixels: $0.baseAddress!, bytesPerRow: TileGeometry.bytesPerRow)! }
}

func sampleState() -> DocumentState {
    var grid = TileGrid()
    grid[TileCoord(0, 0)] = gradientTile(seed: 0.1)
    grid[TileCoord(-1, 2)] = gradientTile(seed: 0.3)
    grid[TileCoord(1, 0)] = .solid(SIMD4(0.2, 0.1, 0.05, 0.5))
    let a = Layer(name: "Background", content: .raster(.solid(SIMD4(1, 1, 1, 1), covering: PixelRect(x: 0, y: 0, width: 600, height: 400))))
    let b = Layer(name: "Paint", isVisible: false, opacity: 0.4, blendMode: .multiply, content: .raster(grid))
    return DocumentState(width: 600, height: 400, colorSpace: .displayP3, blendSpace: .gamma, layers: [a, b], activeLayerID: a.id)
}

func assertSamePixels(_ a: TileGrid, _ b: TileGrid) {
    #expect(Set(a.tiles.keys) == Set(b.tiles.keys))
    for (coord, tile) in a.tiles {
        guard let other = b[coord] else { continue }
        #expect(tile.pixels() == other.pixels(), "tile \(coord.x),\(coord.y) differs")
    }
}

@Suite struct GlimmerPackageTests {
    @Test func roundTripIsBitExact() throws {
        let state = sampleState()
        let wrapper = try GlimmerPackage.fileWrapper(for: state)
        let read = try GlimmerPackage.state(from: wrapper)

        #expect(read.width == 600 && read.height == 400)
        #expect(read.colorSpace == .displayP3 && read.blendSpace == .gamma)
        #expect(read.activeLayerID == state.activeLayerID)
        #expect(read.layers.map(\.id) == state.layers.map(\.id))
        #expect(read.layers[1].opacity == 0.4)
        #expect(read.layers[1].blendMode == .multiply)
        #expect(read.layers[1].isVisible == false)
        for (a, b) in zip(state.layers, read.layers) { assertSamePixels(a.tiles, b.tiles) }
        if case .solid(let c) = read.layers[1].tiles[TileCoord(1, 0)]! {
            #expect(c == SIMD4(0.2, 0.1, 0.05, 0.5))
        } else {
            Issue.record("solid tile was not preserved as solid")
        }
    }

    @Test func roundTripThroughDisk() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "rt-\(UUID().uuidString).glimmer")
        defer { try? FileManager.default.removeItem(at: url) }
        let state = sampleState()
        try GlimmerPackage.fileWrapper(for: state).write(to: url, options: .atomic, originalContentsURL: nil)
        let read = try GlimmerPackage.state(from: FileWrapper(url: url))
        for (a, b) in zip(state.layers, read.layers) { assertSamePixels(a.tiles, b.tiles) }
    }

    @Test func encodedLayerCacheReusesUnchangedLayers() throws {
        let cache = EncodedLayerCache()
        let grid = sampleState().layers[1].tiles
        let first = try cache.data(for: grid)
        let second = try cache.data(for: grid)
        #expect(first == second)
        var changed = grid
        changed[TileCoord(5, 5)] = .solid(SIMD4(1, 0, 0, 1))
        #expect(try cache.data(for: changed) != first)
    }

    @Test func rejectsNewerFormat() throws {
        let json = #"{"formatVersion": 99, "width": 10, "height": 10, "colorSpace": "sRGB", "blendSpace": "linear", "layers": []}"#
        #expect(throws: GlimmerPackageError.unsupportedFormatVersion(99)) {
            try GlimmerPackage.decodeManifest(Data(json.utf8))
        }
    }

    @Test(arguments: [
        #"{"width": 10}"#,
        #"{"formatVersion": 1, "width": 0, "height": 10, "colorSpace": "sRGB", "blendSpace": "linear", "layers": []}"#,
        #"{"formatVersion": 1, "width": 10, "height": 10, "colorSpace": "cmyk", "blendSpace": "linear", "layers": []}"#,
    ])
    func rejectsCorruptManifest(json: String) {
        #expect {
            try GlimmerPackage.decodeManifest(Data(json.utf8))
        } throws: { error in
            if case GlimmerPackageError.corruptManifest = error { return true }
            return false
        }
    }

    @Test func rejectsMissingManifestAndFlatFiles() {
        #expect(throws: GlimmerPackageError.missingManifest) {
            try GlimmerPackage.state(from: FileWrapper(directoryWithFileWrappers: [:]))
        }
        #expect(throws: GlimmerPackageError.notAPackage) {
            try GlimmerPackage.state(from: FileWrapper(regularFileWithContents: Data()))
        }
    }

    @Test func rejectsTruncatedTiles() throws {
        var data = try TileCodec.encode(sampleState().layers[1].tiles)
        data.removeLast(100)
        #expect(throws: GlimmerPackageError.self) { try TileCodec.decode(data) }
    }
}

@Suite struct TileTests {
    @Test func classifiesTransparentUniformAndVaried() {
        let s = TileGeometry.size
        let clear = [Float16](repeating: 0, count: s * s * 4)
        #expect(clear.withUnsafeBytes { Tile.make(pixels: $0.baseAddress!, bytesPerRow: TileGeometry.bytesPerRow) } == nil)

        var red = [Float16](repeating: 0, count: s * s * 4)
        for i in stride(from: 0, to: red.count, by: 4) { red[i] = 1; red[i + 3] = 1 }
        let solid = red.withUnsafeBytes { Tile.make(pixels: $0.baseAddress!, bytesPerRow: TileGeometry.bytesPerRow) }
        guard case .solid(let c)? = solid else { Issue.record("expected solid"); return }
        #expect(c == SIMD4(1, 0, 0, 1))

        guard case .texture = gradientTile() else { Issue.record("expected texture"); return }
    }

    @Test func texturePixelsRoundTrip() {
        let tile = gradientTile(seed: 0.25)
        let pixels = tile.pixels()
        let again = pixels.withUnsafeBytes { Tile.make(pixels: $0.baseAddress!, bytesPerRow: TileGeometry.bytesPerRow)! }
        #expect(again.pixels() == pixels)
    }

    @Test func tileCoordsHandleNegativeRects() {
        let r = PixelRect(x: -10, y: -300, width: 20, height: 1)
        #expect(r.tileCoords == [TileCoord(-1, -2), TileCoord(0, -2)])
        #expect(PixelRect(x: 0, y: 0, width: 256, height: 256).tileCoords == [TileCoord(0, 0)])
        #expect(PixelRect(x: 0, y: 0, width: 0, height: 5).tileCoords.isEmpty)
    }

    @Test func signatureChangesWithContent() {
        var grid = TileGrid()
        grid[TileCoord(0, 0)] = gradientTile()
        let before = grid.contentSignature
        #expect(grid.contentSignature == before)
        grid[TileCoord(0, 0)] = gradientTile()  // same pixels, new identity
        #expect(grid.contentSignature != before)
    }
}

@Suite struct DocumentStateTests {
    @Test func newDocumentBackgrounds() {
        let white = DocumentState.new(width: 600, height: 300, background: .white)
        #expect(white.layers.count == 1)
        #expect(white.layers[0].tiles.count == 3 * 2)
        #expect(DocumentState.new(width: 10, height: 10, background: .transparent).layers[0].tiles.isEmpty)
    }

    @Test func layerOperations() {
        var state = DocumentState.new(width: 100, height: 100, background: .white)
        let bg = state.layers[0].id
        state.insertLayerAboveActive(Layer(name: state.nextLayerName(), content: .raster(TileGrid())))
        #expect(state.layers.count == 2 && state.layers[1].name == "Layer 1")
        #expect(state.activeLayerID == state.layers[1].id)

        state.duplicateActiveLayer()
        #expect(state.layers.count == 3 && state.layers[2].name == "Layer 1 copy")

        let moved = state.moveActiveLayer(by: -2)
        #expect(moved)
        #expect(state.layers[0].name == "Layer 1 copy")
        let movedAgain = state.moveActiveLayer(by: -1)
        #expect(!movedAgain)

        state.deleteActiveLayer()
        #expect(state.layers.map(\.id).contains(bg))
        #expect(state.activeLayerID == state.layers[0].id)
    }
}

@Suite struct ImageImporterTests {
    /// 300×200 sRGB image: left half opaque red, right half transparent.
    private func makeImage() -> CGImage {
        let ctx = CGContext(data: nil, width: 300, height: 200, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 150, height: 200))
        return ctx.makeImage()!
    }

    private func pixel(_ grid: TileGrid, _ x: Int, _ y: Int) -> SIMD4<Float> {
        let s = TileGeometry.size
        let coord = TileCoord(PixelRect.floorDiv(x, s), PixelRect.floorDiv(y, s))
        guard let tile = grid[coord] else { return .zero }
        let px = tile.pixels()
        let i = ((y - coord.y * s) * s + (x - coord.x * s)) * 4
        return SIMD4(Float(px[i]), Float(px[i + 1]), Float(px[i + 2]), Float(px[i + 3]))
    }

    @Test func importsWithOriginAndLinearColor() throws {
        let grid = try ImageImporter.tiles(from: makeImage(), origin: SIMD2(250, -10))
        // Image spans x 250..<550, y -10..<190 → tiles x 0...2, y -1...0
        #expect(Set(grid.tiles.keys).isSubset(of: Set(PixelRect(x: 250, y: -10, width: 300, height: 200).tileCoords)))
        let red = pixel(grid, 260, 0)
        #expect(abs(red.x - 1) < 0.002 && red.y < 0.002 && abs(red.w - 1) < 0.002)
        #expect(pixel(grid, 450, 50) == .zero)   // transparent half
        #expect(pixel(grid, 249, 50) == .zero)   // left of the image
        #expect(pixel(grid, 260, 190) == .zero)  // below the image
        #expect(pixel(grid, 260, 189).w > 0.99)  // last row
    }

    @Test func pngDataImport() throws {
        let data = NSMutableData()
        let dest = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, makeImage(), nil)
        #expect(CGImageDestinationFinalize(dest))
        let image = try ImageImporter.image(from: data as Data)
        #expect(image.width == 300 && image.height == 200)
        #expect(throws: ImageImportError.self) { try ImageImporter.image(from: Data([1, 2, 3])) }
    }
}

@Suite struct CommandRegistryTests {
    @Test func idsAreUnique() {
        let ids = CommandRegistry.standard.descriptors.map(\.id)
        #expect(Set(ids).count == ids.count)
    }

    @Test func shortcutsAreUnique() {
        let shortcuts = CommandRegistry.standard.descriptors.compactMap(\.shortcut)
        #expect(Set(shortcuts).count == shortcuts.count)
    }

    @Test func lookup() {
        #expect(CommandRegistry.standard.descriptor(for: .fitToWindow)?.shortcut == KeyShortcut("0"))
    }
}

import ImageIO

@Suite struct UndoSnapshotTests {
    @Test func movesToDiskAndBack() throws {
        let texture = TileTexture.makeTexture()
        var px = [Float16](repeating: 0.25, count: TileGeometry.size * TileGeometry.size * 4)
        px[0] = 0.75
        px.withUnsafeBytes {
            texture.replace(region: MTLRegionMake2D(0, 0, TileGeometry.size, TileGeometry.size), mipmapLevel: 0,
                            withBytes: $0.baseAddress!, bytesPerRow: TileGeometry.bytesPerRow)
        }
        let layer = Layer(name: "Paint", content: .raster(TileGrid([TileCoord(1, 0): .texture(TileTexture(texture))])))
        var state = DocumentState(width: 600, height: 300, layers: [layer], activeLayerID: layer.id)
        state.selection = Selection.from(mask: [Float](repeating: 1, count: 600 * 300), rect: state.bounds)
        let dir = FileManager.default.temporaryDirectory.appending(path: "undo-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }

        var snapshot: UndoSnapshot? = UndoSnapshot(state)
        #expect(snapshot?.isOnDisk == false)
        try snapshot?.moveToDisk(in: dir)
        #expect(snapshot?.isOnDisk == true)
        let files = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        #expect(files.count == 1)

        let back = try #require(try snapshot?.state())
        #expect(back.width == 600 && back.layers.count == 1 && back.layers[0].id == layer.id)
        #expect(back.activeLayerID == layer.id && back.selection != nil)
        let tile = try #require(back.layers[0].tiles[TileCoord(1, 0)])
        let pixels = tile.pixels()
        #expect(pixels[0] == 0.75 && pixels[4] == 0.25)

        // Releasing the snapshot removes its file.
        snapshot = nil
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).isEmpty)
    }
}
