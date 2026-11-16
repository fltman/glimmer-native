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

    @Test func encodedLayerCacheStaysWithinItsByteBudget() throws {
        let cache = EncodedLayerCache(limit: 64, byteLimit: 200)
        var total = 0
        for i in 0..<20 {
            let grid = TileGrid([TileCoord(i, 0): .solid(SIMD4(Float(i) / 20, 0, 0, 1))])
            total += try cache.data(for: grid).count
            #expect(cache.byteCount <= 200)
        }
        #expect(total > 200, "the layers together are more than the budget")
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

@Suite struct DocumentLimitsTests {
    static let gb = 1_073_741_824

    @Test func aCanvasWhoseSingleLayerCantFitIsRefusedWithTheNumbers() {
        let mac16 = 16 * Self.gb
        #expect(DocumentLimits.maxCanvasPixels(memory: mac16) == 858_993_459)
        #expect(DocumentLimits.refusal(width: 12_000, height: 8_000, memory: mac16) == nil)
        #expect(DocumentLimits.refusal(width: 28_000, height: 28_000, memory: mac16) == nil)
        let message = DocumentLimits.refusal(width: 30_000, height: 30_000, memory: mac16) ?? ""
        #expect(message.contains("30000 × 30000") && message.contains("6.7 GB") && message.contains("16 GB") && message.contains("858 megapixels"), "\(message)")
        // The same canvas fits a bigger Mac and not a smaller one.
        #expect(DocumentLimits.refusal(width: 30_000, height: 30_000, memory: 32 * Self.gb) == nil)
        #expect(DocumentLimits.refusal(width: 20_000, height: 20_000, memory: 8 * Self.gb) == nil)
        #expect(DocumentLimits.refusal(width: 24_000, height: 20_000, memory: 8 * Self.gb) != nil)
        #expect(DocumentLimits.refusal(width: Int.max / 2, height: 4, memory: mac16) != nil, "an overflowing size is refused too")
    }

    @Test func aDocumentThatOutgrowsTheMacIsMentionedNotStopped() {
        let mac16 = 16 * Self.gb
        // The measured document: about 4,100 tiles and 5.5 GB.
        let measured = DocumentLimits.estimatedBytes(textureTiles: 4_100)
        #expect(abs(Double(measured) / Double(Self.gb) - 5.5) < 0.4, "\(measured)")
        #expect(DocumentLimits.comfortNotice(textureTiles: 4_100, memory: mac16) == nil, "5.5 GB of 16 is comfortable")
        let notice = DocumentLimits.comfortNotice(textureTiles: 8_000, memory: mac16) ?? ""
        #expect(notice.contains("16 GB") && notice.contains("Merging layers") && notice.contains("Image Size"), "\(notice)")
        #expect(DocumentLimits.comfortNotice(textureTiles: 4_100, memory: 8 * Self.gb) != nil, "the same document is too much for 8 GB")
    }
}

@Suite struct UndoSpillStoreTests {
    /// A layer of pixels that don't compress, so its file is well over the small-file limit.
    static func noiseLayer(_ name: String, seed: UInt32) -> Layer {
        var seed = seed
        let texture = (try! TileTexture.makeTexture())
        var px = [Float16](repeating: 0, count: TileGeometry.size * TileGeometry.size * 4)
        for j in px.indices { seed = seed &* 1_664_525 &+ 1_013_904_223; px[j] = Float16(Float(seed >> 8) / 16_777_216) }
        px.withUnsafeBytes {
            texture.replace(region: MTLRegionMake2D(0, 0, TileGeometry.size, TileGeometry.size), mipmapLevel: 0,
                            withBytes: $0.baseAddress!, bytesPerRow: TileGeometry.bytesPerRow)
        }
        return Layer(name: name, content: .raster(TileGrid([TileCoord(0, 0): .texture(TileTexture(texture))])))
    }

    static func folder() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appending(path: "spill-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func blobNames(_ dir: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: dir.appending(path: "blobs").path)) ?? []).sorted()
    }

    @Test func stepsThatShareALayerShareItsBytesAndABlobGoesWithItsLastStep() throws {
        let dir = try Self.folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let shared = Self.noiseLayer("Shared", seed: 1), a = Self.noiseLayer("A", seed: 2), b = Self.noiseLayer("B", seed: 3)
        var first: UndoSnapshot? = UndoSnapshot(DocumentState(width: 256, height: 256, layers: [shared, a], activeLayerID: a.id))
        var second: UndoSnapshot? = UndoSnapshot(DocumentState(width: 256, height: 256, layers: [shared, b], activeLayerID: b.id))
        try first?.moveToDisk(in: dir)
        try second?.moveToDisk(in: dir)
        // Three different layers in two documents of two layers each: three blobs, not four.
        let blobs = Self.blobNames(dir)
        #expect(blobs.count == 3, "\(blobs)")
        let counts = blobs.map { UndoSpillStore.linkCount(dir.appending(path: "blobs").appending(path: $0)) }.sorted()
        #expect(counts == [2, 2, 3], "the shared layer has three names: the store's and one per step; \(counts)")
        // Both read back whole.
        #expect(try first?.state().layers.map(\.name) == ["Shared", "A"])
        #expect(try second?.state().layers.map(\.name) == ["Shared", "B"])
        // The first step goes: its own layer's blob goes, the shared one stays for the second.
        first = nil
        #expect(Self.blobNames(dir).count == 2)
        #expect(try second?.state().layers.map(\.name) == ["Shared", "B"], "the remaining step is untouched")
        second = nil
        #expect(Self.blobNames(dir).isEmpty, "a blob is removed when its last step is")
        let left = (try FileManager.default.contentsOfDirectory(atPath: dir.path)).filter { $0 != "blobs" }
        #expect(left.isEmpty, "\(left)")
    }

    @Test func whatAnInterruptedWriteLeftIsNeverReadAndIsSweptAway() throws {
        let dir = try Self.folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fm = FileManager.default
        // A good step.
        let layer = Self.noiseLayer("Kept", seed: 4)
        let good = UndoSnapshot(DocumentState(width: 256, height: 256, layers: [layer], activeLayerID: layer.id))
        try good.moveToDisk(in: dir)
        // What a crash can leave: a blob written but not linked, a blob still under its temporary
        // name, and a package that never got its final name.
        let blobs = dir.appending(path: "blobs")
        try Data(repeating: 7, count: 40_000).write(to: blobs.appending(path: String(repeating: "ab", count: 32)))
        try Data(repeating: 8, count: 40_000).write(to: blobs.appending(path: String(repeating: "cd", count: 32) + ".tmp-X"))
        let partial = dir.appending(path: "DEAD.glimmer.partial")
        try fm.createDirectory(at: partial, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: partial.appending(path: "manifest.json"))
        // Nothing complete carries the unfinished package's name, so nothing reads it.
        #expect(!fm.fileExists(atPath: dir.appending(path: "DEAD.glimmer").path))
        UndoSpillStore.sweep(dir)
        #expect(!fm.fileExists(atPath: partial.path))
        #expect(Self.blobNames(dir).count == 1, "only the good step's blob is left: \(Self.blobNames(dir))")
        #expect(try good.state().layers.first?.name == "Kept", "the good step still reads back")
    }

    @Test func leftoverFoldersOfDeadProcessesAreRemovedAtLaunch() throws {
        let temp = try Self.folder()
        defer { try? FileManager.default.removeItem(at: temp) }
        let fm = FileManager.default
        let mine = temp.appending(path: UndoSpillStore.folderName())
        let dead = temp.appending(path: UndoSpillStore.folderName(pid: 99_999_990))
        let old = temp.appending(path: "undo-" + UUID().uuidString)       // the earlier naming, a week old
        let recent = temp.appending(path: "undo-" + UUID().uuidString)    // the earlier naming, just made
        let other = temp.appending(path: "keep-me")
        for url in [mine, dead, old, recent, other] { try fm.createDirectory(at: url, withIntermediateDirectories: true) }
        try fm.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -7 * 86_400)], ofItemAtPath: old.path)
        #expect(UndoSpillStore.isRunning(ProcessInfo.processInfo.processIdentifier))
        let removed = UndoSpillStore.removeOrphans(in: temp)
        #expect(removed == 2)
        #expect(fm.fileExists(atPath: mine.path) && fm.fileExists(atPath: recent.path) && fm.fileExists(atPath: other.path))
        #expect(!fm.fileExists(atPath: dead.path) && !fm.fileExists(atPath: old.path))
    }

    @Test func aStoreOnAnotherVolumeIsRefusedCleanly() throws {
        // Hard links can't cross volumes. This needs two volumes: the temporary folder and the
        // repository's (they differ on the build Mac; where they don't, there is nothing to test).
        let fm = FileManager.default
        let here = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let volume = { (u: URL) in (try? u.resourceValues(forKeys: [.volumeIdentifierKey]))?.volumeIdentifier as? NSObject }
        guard let a = volume(fm.temporaryDirectory), let b = volume(here), !a.isEqual(b) else { return }
        let store = try Self.folder()
        let elsewhere = here.appending(path: ".spill-volume-test-\(UUID().uuidString)")
        try fm.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: store); try? fm.removeItem(at: elsewhere) }
        let layer = Self.noiseLayer("L", seed: 5)
        let wrapper = try GlimmerPackage.fileWrapper(for: DocumentState(width: 256, height: 256, layers: [layer], activeLayerID: layer.id))
        #expect(throws: UndoSpillStore.SpillError.differentVolume) {
            _ = try UndoSpillStore.write(wrapper, to: elsewhere.appending(path: "step.glimmer"), store: store)
        }
        #expect(try fm.contentsOfDirectory(atPath: elsewhere.path).isEmpty, "nothing is left where the step would have been")
        #expect(Self.blobNames(store).isEmpty, "and no blob stays without a step")
    }
}

@Suite struct UndoSnapshotTests {
    @Test func aFullDiskMakesTheHistoryShorterNotTheDiskFuller() {
        let gb = 1_073_741_824
        // Room for the snapshot and the reserve: spill. Not enough: don't.
        #expect(UndoSpillPolicy.canSpill(bytes: 2 * gb, free: 4 * gb))
        #expect(!UndoSpillPolicy.canSpill(bytes: 2 * gb, free: 2 * gb + gb / 2), "the reserve stays free")
        #expect(!UndoSpillPolicy.canSpill(bytes: gb, free: gb / 2))
        #expect(UndoSpillPolicy.canSpill(bytes: gb, free: nil), "unknown free space: try, and handle the failure")
        // Oldest first, until the rest fits; steps on disk (cost 0) don't help; the newest stays.
        #expect(UndoSpillPolicy.stepsToForget(costs: [500, 500, 500, 500], budget: 1000) == 2)
        #expect(UndoSpillPolicy.stepsToForget(costs: [0, 0, 900, 900], budget: 1000) == 3)
        #expect(UndoSpillPolicy.stepsToForget(costs: [100, 100], budget: 1000) == 0)
        #expect(UndoSpillPolicy.stepsToForget(costs: [5000], budget: 1000) == 0, "the newest step is always kept")
        #expect(UndoSpillPolicy.stepsToForget(costs: [], budget: 0) == 0)
        #expect((UndoSpillPolicy.freeBytes(at: FileManager.default.temporaryDirectory.appending(path: "not-there/yet")) ?? 0) > 0)
    }

    /// The document forgets steps by lowering the undo manager's limit: pin that it drops the oldest at once.
    @MainActor @Test func loweringTheUndoLimitDropsTheOldestSteps() {
        @MainActor final class Target { var value = 0 }
        let target = Target()
        let undo = UndoManager()
        undo.groupsByEvent = false
        for i in 1...5 {
            undo.beginUndoGrouping()
            let old = target.value
            undo.registerUndo(withTarget: target) { t in MainActor.assumeIsolated { t.value = old } }
            target.value = i
            undo.endUndoGrouping()
        }
        undo.levelsOfUndo = 2
        var undone = 0
        while undo.canUndo { undo.undo(); undone += 1 }
        #expect(undone == 2 && target.value == 3, "only the two newest steps are left: \(undone) undone, value \(target.value)")
    }

    @Test func savingWritesTheWholePackageAndReplacesAnEarlierOne() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "save-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(path: "doc.glimmer")
        var state = DocumentState.new(width: 300, height: 200, background: .white)
        try DocumentSaver.write(GlimmerPackage.fileWrapper(for: state), to: url)
        #expect(try GlimmerPackage.state(from: FileWrapper(url: url)).width == 300)
        state.width = 400
        try DocumentSaver.write(GlimmerPackage.fileWrapper(for: state), to: url)
        #expect(try GlimmerPackage.state(from: FileWrapper(url: url)).width == 400, "an earlier version is replaced")
        #expect(DocumentSaver.byteCount(of: try GlimmerPackage.fileWrapper(for: state)) > 100)
        let message = DocumentSaveError.diskFull(needed: 50_000_000, free: 3_000_000, volume: "Photos").errorDescription ?? ""
        #expect(message.contains("“Photos”") && message.contains("50") && message.contains("3"))
    }

    /// Run by scripts/test-disk-full.sh with a small, nearly full disk image mounted.
    @Test func savingToAFullDiskSaysSoAndLeavesNoHalfDocument() throws {
        guard let path = ProcessInfo.processInfo.environment["GLIMMER_FULL_DISK"], !path.isEmpty else { return }
        let root = URL(fileURLWithPath: path, isDirectory: true)
        // An earlier, small version saved while there was still room.
        let url = root.appending(path: "doc.glimmer")
        let small = DocumentState.new(width: 300, height: 200, background: .white)
        try DocumentSaver.write(GlimmerPackage.fileWrapper(for: small), to: url)
        // A layer that can't fit (random pixels don't compress).
        var tiles: [TileCoord: Tile] = [:]
        var seed: UInt32 = 5
        for i in 0..<40 {
            let texture = (try! TileTexture.makeTexture())
            var px = [Float16](repeating: 0, count: TileGeometry.size * TileGeometry.size * 4)
            for j in px.indices { seed = seed &* 1_664_525 &+ 1_013_904_223; px[j] = Float16(Float(seed >> 8) / 16_777_216) }
            px.withUnsafeBytes {
                texture.replace(region: MTLRegionMake2D(0, 0, TileGeometry.size, TileGeometry.size), mipmapLevel: 0,
                                withBytes: $0.baseAddress!, bytesPerRow: TileGeometry.bytesPerRow)
            }
            tiles[TileCoord(i % 8, i / 8)] = .texture(TileTexture(texture))
        }
        let layer = Layer(name: "Noise", content: .raster(TileGrid(tiles)))
        let big = DocumentState(width: 2048, height: 1280, layers: [layer], activeLayerID: layer.id)
        let wrapper = try GlimmerPackage.fileWrapper(for: big)
        // Over the earlier version: refused before writing, and the earlier version is intact.
        #expect(throws: DocumentSaveError.self) { try DocumentSaver.write(wrapper, to: url) }
        #expect(try GlimmerPackage.state(from: FileWrapper(url: url)).width == 300, "the earlier saved version is untouched")
        // As a new document: refused, and nothing is left where it would have been.
        let fresh = root.appending(path: "new.glimmer")
        #expect(throws: DocumentSaveError.self) { try DocumentSaver.write(wrapper, to: fresh) }
        #expect(!FileManager.default.fileExists(atPath: fresh.path), "no empty or half document is left behind")
        // The system makes the package's folder first; an empty one must not survive the failure.
        let made = root.appending(path: "made.glimmer")
        try FileManager.default.createDirectory(at: made, withIntermediateDirectories: false)
        #expect(throws: DocumentSaveError.self) { try DocumentSaver.write(wrapper, to: made) }
        #expect(!FileManager.default.fileExists(atPath: made.path), "the empty folder is removed")
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        #expect(names.filter { $0.contains("new") }.isEmpty, "\(names)")
    }

    /// Run by scripts/test-disk-full.sh with a small, nearly full disk image mounted.
    @Test func aSnapshotThatDoesntFitLeavesNothingBehindAndStaysInMemory() throws {
        guard let path = ProcessInfo.processInfo.environment["GLIMMER_FULL_DISK"], !path.isEmpty else { return }
        let dir = URL(fileURLWithPath: path, isDirectory: true).appending(path: "undo")
        // About 40 MB of pixels that don't compress.
        var tiles: [TileCoord: Tile] = [:]
        var seed: UInt32 = 3
        for i in 0..<80 {
            let texture = (try! TileTexture.makeTexture())
            var px = [Float16](repeating: 0, count: TileGeometry.size * TileGeometry.size * 4)
            for j in px.indices { seed = seed &* 1_664_525 &+ 1_013_904_223; px[j] = Float16(Float(seed >> 8) / 16_777_216) }
            px.withUnsafeBytes {
                texture.replace(region: MTLRegionMake2D(0, 0, TileGeometry.size, TileGeometry.size), mipmapLevel: 0,
                                withBytes: $0.baseAddress!, bytesPerRow: TileGeometry.bytesPerRow)
            }
            tiles[TileCoord(i % 10, i / 10)] = .texture(TileTexture(texture))
        }
        let layer = Layer(name: "Noise", content: .raster(TileGrid(tiles)))
        let state = DocumentState(width: 2560, height: 2048, layers: [layer], activeLayerID: layer.id)
        let snapshot = UndoSnapshot(state)
        let free = try #require(UndoSpillPolicy.freeBytes(at: dir))
        #expect(free < snapshot.diskBytesUpperBound, "the test disk must be too small: \(free) free")
        #expect(!UndoSpillPolicy.canSpill(bytes: snapshot.diskBytesUpperBound, free: free))
        // Forced anyway (as when the disk fills while writing): it fails cleanly.
        #expect(throws: (any Error).self) { try snapshot.moveToDisk(in: dir) }
        #expect(!snapshot.isOnDisk)
        let left = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        #expect(left.filter { $0.hasSuffix(".glimmer") }.isEmpty, "nothing half-written is left: \(left)")
        #expect(try snapshot.state().layers.first?.tiles.tileBounds == state.layers.first?.tiles.tileBounds, "the step is still in memory")
    }

    @Test func movesToDiskAndBack() throws {
        let texture = (try! TileTexture.makeTexture())
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
        let files = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0 != "blobs" }
        #expect(files.count == 1)

        let back = try #require(try snapshot?.state())
        #expect(back.width == 600 && back.layers.count == 1 && back.layers[0].id == layer.id)
        #expect(back.activeLayerID == layer.id && back.selection != nil)
        let tile = try #require(back.layers[0].tiles[TileCoord(1, 0)])
        let pixels = tile.pixels()
        #expect(pixels[0] == 0.75 && pixels[4] == 0.25)

        // Releasing the snapshot removes its file.
        snapshot = nil
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0 != "blobs" }.isEmpty)
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: dir.appending(path: "blobs").path)) ?? []).isEmpty)
    }
}

@Suite struct TileCodecSpeedTests {
    /// A full 6000 × 4000 layer of pixels that don't compress (384 tiles, 192 MB): the worst case for saving.
    @Test func encodingAndDecodingABigLayer() throws {
        var tiles: [TileCoord: Tile] = [:]
        var seed: UInt32 = 11
        var px = [Float16](repeating: 0, count: TileGeometry.size * TileGeometry.size * 4)
        for i in 0..<384 {
            for j in stride(from: 0, to: px.count, by: 7) { seed = seed &* 1_664_525 &+ 1_013_904_223; px[j] = Float16(Float(seed >> 8) / 16_777_216) }
            let texture = (try! TileTexture.makeTexture())
            px.withUnsafeBytes {
                texture.replace(region: MTLRegionMake2D(0, 0, TileGeometry.size, TileGeometry.size), mipmapLevel: 0,
                                withBytes: $0.baseAddress!, bytesPerRow: TileGeometry.bytesPerRow)
            }
            tiles[TileCoord(i % 24, i / 24)] = .texture(TileTexture(texture))
        }
        let grid = TileGrid(tiles)
        var start = Date()
        let data = try TileCodec.encode(grid)
        let encode = Date().timeIntervalSince(start)
        start = Date()
        let back = try TileCodec.decode(data)
        let decode = Date().timeIntervalSince(start)
        print(String(format: "TileCodec 384 tiles: encode %.2f s, decode %.2f s, %d MB", encode, decode, data.count / 1_048_576))
        #expect(back.count == 384)
        #expect(back[TileCoord(5, 7)]?.pixels() == grid[TileCoord(5, 7)]?.pixels(), "the pixels come back exactly")
        #expect(try TileCodec.encode(back) == data, "encoding is deterministic")
    }
}

extension TileCodecSpeedTests {
    /// Four layers of 20 tiles of fully random pixels (about 35 MB on disk): where does saving and opening spend its time?
    @Test func savingAndOpeningAPackage() throws {
        var seed: UInt32 = 17
        var px = [Float16](repeating: 0, count: TileGeometry.size * TileGeometry.size * 4)
        var layers: [Layer] = []
        for l in 0..<4 {
            var tiles: [TileCoord: Tile] = [:]
            for i in 0..<20 {
                for j in px.indices { seed = seed &* 1_664_525 &+ 1_013_904_223; px[j] = Float16(Float(seed >> 8) / 16_777_216) }
                let texture = (try! TileTexture.makeTexture())
                px.withUnsafeBytes {
                    texture.replace(region: MTLRegionMake2D(0, 0, TileGeometry.size, TileGeometry.size), mipmapLevel: 0,
                                    withBytes: $0.baseAddress!, bytesPerRow: TileGeometry.bytesPerRow)
                }
                tiles[TileCoord(i % 8, i / 8)] = .texture(TileTexture(texture))
            }
            layers.append(Layer(name: "L\(l)", content: .raster(TileGrid(tiles))))
        }
        let state = DocumentState(width: 2048, height: 1280, layers: layers, activeLayerID: layers[0].id)
        let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: ".speed-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(path: "doc.glimmer")
        var t = Date()
        let wrapper = try GlimmerPackage.fileWrapper(for: state)
        let encode = Date().timeIntervalSince(t); t = Date()
        try DocumentSaver.write(wrapper, to: url)
        let write = Date().timeIntervalSince(t); t = Date()
        let read = try FileWrapper(url: url, options: [])
        let bytes = DocumentSaver.byteCount(of: read)
        let load = Date().timeIntervalSince(t); t = Date()
        let back = try GlimmerPackage.state(from: read)
        let decode = Date().timeIntervalSince(t)
        print(String(format: "Package 80 tiles, %d MB: encode %.2f s, write %.2f s, read file %.2f s, decode %.2f s", bytes / 1_048_576, encode, write, load, decode))
        #expect(back.layers.count == 4)
    }
}

/// A linked edit keeps its link in the document, so a restored window is linked again.
@Suite struct DocumentLinkTests {
    @Test func theLinkTravelsWithTheDocument() throws {
        var state = DocumentState(width: 64, height: 48)
        state.link = DocumentLink(bookmark: Data([1, 2, 3]), path: "/tmp/photo.png", requester: "Flimmer")
        let back = try GlimmerPackage.state(from: GlimmerPackage.fileWrapper(for: state))
        #expect(back.link == state.link)
        #expect(back.link?.fileName == "photo.png")
    }

    @Test func anOrdinaryDocumentHasNoLinkInItsManifest() throws {
        let wrapper = try GlimmerPackage.fileWrapper(for: DocumentState(width: 64, height: 48))
        let manifest = try #require(wrapper.fileWrappers?[GlimmerPackage.manifestFilename]?.regularFileContents)
        #expect(!String(decoding: manifest, as: UTF8.self).contains("\"link\""))
        #expect(try GlimmerPackage.state(from: wrapper).link == nil)
    }

    /// A build from before the link reads a linked document as an ordinary one: the key is optional and unknown keys are skipped.
    @Test func aManifestWithoutTheKeyStillReads() throws {
        var state = DocumentState(width: 64, height: 48)
        state.link = DocumentLink(bookmark: nil, path: "/tmp/a.jpg", requester: "Jämmer")
        let wrapper = try GlimmerPackage.fileWrapper(for: state)
        let data = try #require(wrapper.fileWrappers?[GlimmerPackage.manifestFilename]?.regularFileContents)
        var json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["link"] != nil)
        json["link"] = nil
        #expect(throws: Never.self) { try JSONDecoder().decode(DocumentManifest.self, from: try JSONSerialization.data(withJSONObject: json)) }
    }
}
