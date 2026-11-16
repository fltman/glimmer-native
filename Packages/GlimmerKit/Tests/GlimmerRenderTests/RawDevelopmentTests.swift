import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import GlimmerCore
@testable import GlimmerRender

/// Writes a small DNG (a Bayer mosaic in a TIFF with the DNG tags Apple's decoder asks for),
/// so the tests need no camera file. `scene` gives red, green and blue from 0 to 1 per pixel.
enum DNGTestWriter {
    static func le16(_ v: UInt16) -> Data { Data([UInt8(v & 0xFF), UInt8(v >> 8)]) }
    static func le32(_ v: UInt32) -> Data { le16(UInt16(v & 0xFFFF)) + le16(UInt16(v >> 16)) }
    struct Tag { let id: UInt16, type: UInt16, count: UInt32; let value: Data }
    static func short(_ id: UInt16, _ v: [UInt16]) -> Tag { Tag(id: id, type: 3, count: UInt32(v.count), value: v.reduce(Data()) { $0 + le16($1) }) }
    static func long(_ id: UInt16, _ v: [UInt32]) -> Tag { Tag(id: id, type: 4, count: UInt32(v.count), value: v.reduce(Data()) { $0 + le32($1) }) }
    static func byte(_ id: UInt16, _ v: [UInt8]) -> Tag { Tag(id: id, type: 1, count: UInt32(v.count), value: Data(v)) }
    static func ascii(_ id: UInt16, _ s: String) -> Tag { let d = Data(s.utf8) + Data([0]); return Tag(id: id, type: 2, count: UInt32(d.count), value: d) }
    static func rational(_ id: UInt16, _ v: [(UInt32, UInt32)]) -> Tag { Tag(id: id, type: 5, count: UInt32(v.count), value: v.reduce(Data()) { $0 + le32($1.0) + le32($1.1) }) }
    static func srational(_ id: UInt16, _ v: [(Int32, Int32)]) -> Tag { Tag(id: id, type: 10, count: UInt32(v.count), value: v.reduce(Data()) { $0 + le32(UInt32(bitPattern: $1.0)) + le32(UInt32(bitPattern: $1.1)) }) }

    static func data(width: Int = 640, height: Int = 480, scene: (Int, Int) -> (Double, Double, Double)) -> Data {
        var pixels = Data(capacity: width * height * 2)
        for y in 0..<height {
            for x in 0..<width {
                let (r, g, b) = scene(x, y)
                // The mosaic: red, green / green, blue.
                let v = (y % 2 == 0) ? (x % 2 == 0 ? r : g) : (x % 2 == 0 ? g : b)
                pixels += le16(UInt16((min(max(v, 0), 1) * 60_000).rounded()))
            }
        }
        let identity: [(Int32, Int32)] = [(10000, 10000), (0, 10000), (0, 10000), (0, 10000), (10000, 10000), (0, 10000), (0, 10000), (0, 10000), (10000, 10000)]
        var tags: [Tag] = [
            long(254, [0]), long(256, [UInt32(width)]), long(257, [UInt32(height)]), short(258, [16]), short(259, [1]), short(262, [32803]),
            ascii(271, "Glimmer Tests"), ascii(272, "Glimmer Test Camera"), long(273, [0]), short(274, [1]), short(277, [1]),
            long(278, [UInt32(height)]), long(279, [UInt32(pixels.count)]), short(284, [1]), ascii(305, "Glimmer tests"),
            short(33421, [2, 2]), byte(33422, [0, 1, 1, 2]),
            byte(50706, [1, 4, 0, 0]), byte(50707, [1, 1, 0, 0]), ascii(50708, "Glimmer Test Camera"), byte(50710, [0, 1, 2]), short(50711, [1]), short(50713, [1, 1]),
            rational(50714, [(0, 1)]), long(50717, [65535]), rational(50718, [(1, 1), (1, 1)]), rational(50719, [(0, 1), (0, 1)]),
            rational(50720, [(UInt32(width), 1), (UInt32(height), 1)]), srational(50721, identity), srational(50722, identity),
            rational(50727, [(1, 1), (1, 1), (1, 1)]), rational(50728, [(1, 1), (1, 1), (1, 1)]), srational(50730, [(0, 1)]), rational(50731, [(1, 1)]),
            rational(50732, [(1, 1)]), short(50778, [21]), short(50779, [21]), long(50829, [0, 0, UInt32(height), UInt32(width)]),
        ]
        tags.sort { $0.id < $1.id }
        let ifdOffset = 8, ifdSize = 2 + tags.count * 12 + 4
        var extra = Data(), entries = Data()
        var strip = 0
        for (i, tag) in tags.enumerated() {
            if tag.id == 273 { strip = i }
            entries += le16(tag.id) + le16(tag.type) + le32(tag.count)
            if tag.value.count <= 4 {
                entries += tag.value + Data(count: 4 - tag.value.count)
            } else {
                entries += le32(UInt32(ifdOffset + ifdSize + extra.count))
                extra += tag.value
                if tag.value.count % 2 == 1 { extra.append(0) }
            }
        }
        entries.replaceSubrange((strip * 12 + 8)..<(strip * 12 + 12), with: le32(UInt32(ifdOffset + ifdSize + extra.count)))
        return Data("II".utf8) + le16(42) + le32(UInt32(ifdOffset)) + le16(UInt16(tags.count)) + entries + le32(0) + extra + pixels
    }

    /// A grey ramp from dark on the left to light on the right, with a warm patch in the lower right quarter.
    static let ramp = data { x, y in
        let v = 0.05 + 0.6 * Double(x) / 640
        return x > 400 && y > 300 ? (v * 1.2, v * 0.9, v * 0.6) : (v, v, v)
    }
}

/// RAW development through Apple's decoder, on a DNG the tests write themselves.
@Suite struct RawDevelopmentTests {
    /// The mean red, green and blue (0…255, sRGB) of a small square of a developed picture.
    static func colour(_ image: CGImage, x: Int, y: Int, size: Int = 12) -> (r: Double, g: Double, b: Double) {
        var bytes = [UInt8](repeating: 0, count: size * size * 4)
        bytes.withUnsafeMutableBytes { raw in
            let ctx = CGContext(data: raw.baseAddress, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
            // The square's top-left at (x, y) from the picture's top-left; Core Graphics counts from the bottom.
            ctx.draw(image, in: CGRect(x: -x, y: -(image.height - y - size), width: image.width, height: image.height))
        }
        var r = 0.0, g = 0.0, b = 0.0
        for i in 0..<(size * size) { r += Double(bytes[i * 4]); g += Double(bytes[i * 4 + 1]); b += Double(bytes[i * 4 + 2]) }
        let n = Double(size * size)
        return (r / n, g / n, b / n)
    }

    @Test func theHeaderSaysWhatTheFileIsBeforeAnythingIsDeveloped() throws {
        let info = try RawDevelopment.info(DNGTestWriter.ramp)
        #expect(info.width == 640 && info.height == 480 && !info.processes.isEmpty)
        #expect(info.temperature > 2_000 && info.temperature < 50_000)
        print("RAW test file: processes \(info.processes), as shot \(Int(info.temperature)) K tint \(Int(info.tint)); supports lens \(info.supportsLensCorrection), highlight recovery \(info.supportsHighlightRecovery), noise \(info.supportsLuminanceNoise)/\(info.supportsColorNoise), sharpness \(info.supportsSharpness), contrast \(info.supportsContrast)")
        // Larger than this Mac handles: refused from the header, before any decode.
        #expect(throws: RawDevelopment.Problem.self) { _ = try RawDevelopment.info(DNGTestWriter.ramp, maxPixels: 1_000) }
    }

    @Test func developingGivesThePictureAndExposureAndWhiteBalanceChangeIt() throws {
        let (image, applied) = try RawDevelopment.develop(DNGTestWriter.ramp, settings: RawSettings())
        #expect(image.width == 640 && image.height == 480 && image.bitsPerComponent == 16)
        let left = Self.colour(image, x: 40, y: 100), right = Self.colour(image, x: 580, y: 100)
        #expect(right.g > left.g + 40, "a ramp from dark to light: \(left) \(right)")
        #expect(abs(left.r - left.b) < 6 && abs(right.r - right.b) < 6, "grey stays grey")
        #expect(applied.process == (try RawDevelopment.info(DNGTestWriter.ramp)).processes.last)
        // Exposure.
        var brighter = RawSettings(); brighter.exposure = 1
        var darker = RawSettings(); darker.exposure = -1
        let middle = Self.colour(image, x: 300, y: 100).g
        let up = Self.colour(try RawDevelopment.develop(DNGTestWriter.ramp, settings: brighter).image, x: 300, y: 100).g
        let down = Self.colour(try RawDevelopment.develop(DNGTestWriter.ramp, settings: darker).image, x: 300, y: 100).g
        print("RAW exposure on the test file, middle grey: −1 stop \(down), as shot \(middle), +1 stop \(up)")
        #expect(up > middle + 15 && down < middle - 15)
        // White balance: a lower temperature setting cools the picture, a higher one warms it.
        var cool = RawSettings(); cool.temperature = 3_000
        var warm = RawSettings(); warm.temperature = 12_000
        let c = Self.colour(try RawDevelopment.develop(DNGTestWriter.ramp, settings: cool).image, x: 300, y: 100)
        let w = Self.colour(try RawDevelopment.develop(DNGTestWriter.ramp, settings: warm).image, x: 300, y: 100)
        print("RAW white balance on the test file, middle grey: 3000 K \(c), 12000 K \(w)")
        #expect(c.b - c.r > 10 && w.r - w.b > 10)
    }

    @Test func clickingOnSomethingThatShouldBeGreyGivesItsWhiteBalance() throws {
        let data = DNGTestWriter.ramp
        let before = Self.colour(try RawDevelopment.develop(data, settings: RawSettings()).image, x: 500, y: 380)
        let balance = try RawDevelopment.whiteBalance(for: data, settings: RawSettings(), neutralAt: CGPoint(x: 506, y: 386))
        var settings = RawSettings()
        settings.temperature = balance.temperature; settings.tint = balance.tint
        let after = Self.colour(try RawDevelopment.develop(data, settings: settings).image, x: 500, y: 380)
        print("RAW white balance by clicking on the warm patch: \(Int(balance.temperature)) K tint \(Int(balance.tint)); the patch before \(before), after \(after)")
        #expect(abs(after.r - after.b) < abs(before.r - before.b) / 2, "the clicked patch is much nearer grey")
    }

    /// A document remembers the process it was developed with: the same picture again, and words when the system no longer has it.
    @Test func theProcessIsKeptAndAMissingOneIsSaid() throws {
        let data = DNGTestWriter.ramp
        let (first, applied) = try RawDevelopment.develop(data, settings: RawSettings())
        #expect(applied.process != nil)
        let saved = try JSONDecoder().decode(RawSettings.self, from: JSONEncoder().encode(applied))
        #expect(saved == applied)
        let (again, sameSettings) = try RawDevelopment.develop(data, settings: saved)
        #expect(sameSettings == saved)
        let a = Self.colour(first, x: 300, y: 200), b = Self.colour(again, x: 300, y: 200)
        #expect(a.r == b.r && a.g == b.g && a.b == b.b)
        // An older process the system still offers is used when it is the stored one.
        let processes = try RawDevelopment.info(data).processes
        if let oldest = processes.first, oldest != applied.process {
            var old = RawSettings(); old.process = oldest
            #expect(try RawDevelopment.develop(data, settings: old).applied.process == oldest)
        }
        var gone = RawSettings(); gone.process = "1.gone"
        #expect { _ = try RawDevelopment.develop(data, settings: gone) } throws: {
            ($0 as? RawDevelopment.Problem)?.message.contains("process 1.gone, which this version of macOS no longer offers") == true
        }
    }

    @Test func aDraftIsSmallerAndWhatIsNotARawFileIsRefusedWithWords() throws {
        let draft = try RawDevelopment.develop(DNGTestWriter.ramp, settings: RawSettings(), scale: 0.25).image
        #expect(draft.width <= 330 && draft.width >= 150, "\(draft.width)")
        #expect(throws: RawDevelopment.notRaw) { _ = try RawDevelopment.info(Data()) }
        #expect(throws: RawDevelopment.notRaw) { _ = try RawDevelopment.info(Data(count: 10_000)) }
        #expect(throws: RawDevelopment.notRaw) { _ = try RawDevelopment.info(Data("II*\u{0}not a picture at all, just words that go on for a while longer than sixty-four bytes".utf8)) }
        // Cut short at many lengths: a refusal or a picture, never a crash.
        let good = DNGTestWriter.ramp
        var developed = 0
        for length in stride(from: 0, to: good.count, by: good.count / 37) {
            if (try? RawDevelopment.develop(good.prefix(length), settings: RawSettings(), scale: 0.1)) != nil { developed += 1 }
        }
        print("RAW test file cut at 37 lengths: developed \(developed) times, refused the rest")
        #expect(RawDevelopment.cameras.count > 100)
    }
}

/// A layer that keeps its RAW file: made, saved, read back and developed again.
@Suite struct RawLayerTests {
    @Test func aRawLayerKeepsItsFileThroughSavingAndCanBeDevelopedAgain() throws {
        let data = DNGTestWriter.ramp
        let (layer, width, height) = try RawLayer.make(from: data, fileName: "ramp.dng")
        #expect(width == 640 && height == 480 && layer.name == "ramp" && layer.raw?.data == data && layer.raw?.settings.process != nil)
        #expect(RawLayer.pixelsAreAsDeveloped(layer))
        var state = DocumentState(width: width, height: height)
        state.layers = [layer]
        let before = try ImageExporter.flattenedSRGB(state, context: try context())
        // Saved and read back: the file's bytes, its name and its settings are there, and the picture is the same.
        let read = try GlimmerPackage.state(from: GlimmerPackage.fileWrapper(for: state))
        let back = try #require(read.layers.first)
        #expect(back.raw?.data == data && back.raw?.fileName == "ramp.dng" && back.raw?.settings == layer.raw?.settings && RawLayer.pixelsAreAsDeveloped(back))
        let after = try ImageExporter.flattenedSRGB(read, context: try context())
        #expect(RawDevelopmentTests.colour(before, x: 300, y: 100) == RawDevelopmentTests.colour(after, x: 300, y: 100))
        // Developed again, brighter: new pixels, the same file, and the layer's own settings stay.
        var masked = back
        masked.opacity = 0.5; masked.blendMode = .multiply; masked.mask = LayerMask(defaultValue: 0.5)
        var brighter = try #require(masked.raw?.settings)
        brighter.exposure = 1
        let again = try RawLayer.developed(masked, with: brighter)
        #expect(again.raw?.data == data && again.raw?.settings.exposure == 1 && again.raw?.settings.process == layer.raw?.settings.process)
        #expect(again.opacity == 0.5 && again.blendMode == .multiply && again.mask?.defaultValue == 0.5 && again.id == masked.id)
        var bright = read
        var plain = again; plain.opacity = 1; plain.blendMode = .normal; plain.mask = nil
        bright.layers = [plain]
        let brightPicture = try ImageExporter.flattenedSRGB(bright, context: try context())
        #expect(RawDevelopmentTests.colour(brightPicture, x: 300, y: 100).g > RawDevelopmentTests.colour(after, x: 300, y: 100).g + 15)
    }

    @Test func pixelsChangedAfterDevelopingAreNoticedAlsoAfterSaving() throws {
        let (layer, width, height) = try RawLayer.make(from: DNGTestWriter.ramp, fileName: "ramp.dng")
        var painted = layer
        painted.content = .raster(TileGrid.solid(SIMD4(1, 0, 0, 1), covering: PixelRect(x: 0, y: 0, width: 256, height: 256)))
        #expect(!RawLayer.pixelsAreAsDeveloped(painted))
        var state = DocumentState(width: width, height: height)
        state.layers = [painted]
        let back = try #require(try GlimmerPackage.state(from: GlimmerPackage.fileWrapper(for: state)).layers.first)
        #expect(back.raw != nil && !RawLayer.pixelsAreAsDeveloped(back))
        // A layer without a RAW file can't be developed, and says so.
        #expect(throws: RawDevelopment.Problem.self) { _ = try RawLayer.developed(Layer(name: "Plain", content: .raster(TileGrid())), with: RawSettings()) }
    }

    @Test func aPackageWithoutItsRawFileStillOpensWithThePixels() throws {
        let (layer, width, height) = try RawLayer.make(from: DNGTestWriter.ramp, fileName: "ramp.dng")
        var state = DocumentState(width: width, height: height)
        state.layers = [layer]
        let wrapper = try GlimmerPackage.fileWrapper(for: state)
        // The RAW file goes missing from the package, or is cut short: the layer opens as pixels, without it.
        let layers = try #require(wrapper.fileWrappers?["layers"])
        let name = "\(layer.id.uuidString).raw"
        let file = try #require(layers.fileWrappers?[name])
        layers.removeFileWrapper(file)
        let without = try #require(try GlimmerPackage.state(from: wrapper).layers.first)
        #expect(without.raw == nil && !without.content.isEmptyRaster)
        let cut = FileWrapper(regularFileWithContents: Data(count: 100))
        cut.preferredFilename = name
        layers.addFileWrapper(cut)
        #expect(try GlimmerPackage.state(from: wrapper).layers.first?.raw == nil)
    }
}

private extension LayerContent {
    var isEmptyRaster: Bool { if case .raster(let grid) = self { grid.isEmpty } else { true } }
}

/// Camera files (fetched with Anders's yes, kept outside the repository): GLIMMER_RAW_SAMPLES=<folder>.
/// Each is developed as shot and with a few settings changed; previews go to GLIMMER_RAW_OUT for a person to look at.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["GLIMMER_RAW_SAMPLES"] != nil), .serialized)
struct RawRealFiles {
    static func writePreview(_ image: CGImage, to url: URL, maxSide: Int = 1600) {
        let scale = min(1, Double(maxSide) / Double(max(image.width, image.height)))
        let w = max(1, Int(Double(image.width) * scale)), h = max(1, Int(Double(image.height) * scale))
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let small = ctx.makeImage(), let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(dest, small, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        CGImageDestinationFinalize(dest)
    }

    @Test func everyCameraFileDevelops() throws {
        let env = ProcessInfo.processInfo.environment
        let folder = URL(fileURLWithPath: env["GLIMMER_RAW_SAMPLES"]!)
        let out = env["GLIMMER_RAW_OUT"].map { URL(fileURLWithPath: $0) }
        if let out { try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true) }
        let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { !["txt", "md"].contains($0.pathExtension.lowercased()) && !$0.lastPathComponent.hasPrefix(".") }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        #expect(!files.isEmpty)
        for url in files {
            let name = url.deletingPathExtension().lastPathComponent
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            do {
                var start = Date()
                let info = try RawDevelopment.info(data)
                let headerTime = Date().timeIntervalSince(start)
                print("RAWREAL \(url.lastPathComponent) | \(data.count / 1_048_576) MB | \(info.width)×\(info.height) | header \(String(format: "%.2f", headerTime)) s | processes \(info.processes.joined(separator: ",")) | as shot \(Int(info.temperature)) K tint \(Int(info.tint)) | lens \(info.supportsLensCorrection) (on: \(info.lensCorrection)) highlights \(info.supportsHighlightRecovery) noise \(info.supportsLuminanceNoise)/\(info.supportsColorNoise) sharp \(info.supportsSharpness) contrast \(info.supportsContrast)")
                start = Date()
                let draft = try RawDevelopment.develop(data, settings: RawSettings(), scale: 0.25)
                let draftTime = Date().timeIntervalSince(start)
                start = Date()
                let (full, applied) = try RawDevelopment.develop(data, settings: RawSettings())
                let fullTime = Date().timeIntervalSince(start)
                let centre = RawDevelopmentTests.colour(full, x: full.width / 2, y: full.height / 2, size: 16)
                print("RAWREAL    developed \(full.width)×\(full.height) in \(String(format: "%.2f", fullTime)) s (draft \(draft.image.width)×\(draft.image.height) in \(String(format: "%.2f", draftTime)) s), process \(applied.process ?? "-"), centre \(Int(centre.r)),\(Int(centre.g)),\(Int(centre.b))")
                if let out { Self.writePreview(full, to: out.appending(path: "\(name) - 1 as shot.jpg")) }
                var variants: [(String, RawSettings)] = []
                var s = RawSettings(); s.exposure = 1; variants.append(("2 exposure +1", s))
                s = RawSettings(); s.exposure = -1; variants.append(("3 exposure -1", s))
                s = RawSettings(); s.temperature = info.temperature * 0.7; variants.append(("4 cooler (\(Int(info.temperature * 0.7)) K)", s))
                s = RawSettings(); s.temperature = info.temperature * 1.4; variants.append(("5 warmer (\(Int(info.temperature * 1.4)) K)", s))
                s = RawSettings(); s.shadows = 1.8; variants.append(("6 shadows lifted (1.8)", s))
                if info.supportsLensCorrection { s = RawSettings(); s.lensCorrection = !info.lensCorrection; variants.append(("7 lens correction \(info.lensCorrection ? "off" : "on")", s)) }
                for (label, settings) in variants {
                    let image = try RawDevelopment.develop(data, settings: settings, scale: 0.5).image
                    let c = RawDevelopmentTests.colour(image, x: image.width / 2, y: image.height / 2, size: 16)
                    print("RAWREAL    \(label): centre \(Int(c.r)),\(Int(c.g)),\(Int(c.b))")
                    if let out { Self.writePreview(image, to: out.appending(path: "\(name) - \(label).jpg")) }
                }
                // The layer: made, and its picture the same after saving and reading back.
                start = Date()
                let made = try RawLayer.make(from: data, fileName: url.lastPathComponent)
                print("RAWREAL    as a layer in \(String(format: "%.2f", Date().timeIntervalSince(start))) s; cut short at 5 lengths: \([0.1, 0.3, 0.5, 0.7, 0.9].map { (try? RawDevelopment.info(data.prefix(Int(Double(data.count) * $0)))) == nil ? "refused" : "header read" })")
                #expect(made.width == info.width && made.height == info.height)
            } catch {
                print("RAWREAL \(url.lastPathComponent) | REFUSED: \((error as? LocalizedError)?.errorDescription ?? "\(error)")")
            }
        }
    }
}
