import CoreGraphics
import Foundation
import GlimmerCore
import ImageIO
@testable import GlimmerRender
import Testing
import UniformTypeIdentifiers

/// "Edit in Glimmer" from Flimmer: the file keeps its format and its place, and a
/// Glimmer document never becomes an image file (or an image a package).
@Suite struct LinkedImageTests {
    static func image(alpha: Bool = false) -> CGImage {
        let ctx = CGContext(data: nil, width: 64, height: 48, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(srgbRed: 0.8, green: 0.2, blue: 0.4, alpha: alpha ? 0.5 : 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 64, height: 48))
        return ctx.makeImage()!
    }

    static func tempFile(_ name: String, contents: Data = Data([0])) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appending(path: "linked-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appending(path: name)
        try contents.write(to: url)
        return url
    }

    static func inode(_ url: URL) throws -> Int {
        try (FileManager.default.attributesOfItem(atPath: url.path)[.systemFileNumber] as? Int) ?? -1
    }

    @Test func formatsFollowTheExtension() {
        #expect(LinkedImage.format(for: URL(fileURLWithPath: "/a/photo.PNG")) == .png)
        #expect(LinkedImage.format(for: URL(fileURLWithPath: "/a/photo.jpeg")) == .jpeg)
        #expect(LinkedImage.format(for: URL(fileURLWithPath: "/a/photo.jpg")) == .jpeg)
        #expect(LinkedImage.format(for: URL(fileURLWithPath: "/a/photo.psd")) == nil, "PSD opens as a new document instead")
        #expect(LinkedImage(url: URL(fileURLWithPath: "/a/clip.mov"), requester: "Flimmer") == nil)
    }

    @Test func pngStaysPngInTheSameFile() throws {
        let url = try Self.tempFile("photo.png", contents: try ImageExporter.encode(Self.image(), options: ExportOptions(format: .png)))
        let before = try Self.inode(url)
        let link = try #require(LinkedImage(url: url, requester: "Flimmer"))
        try link.write(Self.image(alpha: true))
        let data = try Data(contentsOf: url)
        #expect(Array(data.prefix(8)) == [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A], "a PNG")
        #expect(try Self.inode(url) == before, "written in place, so the other app's file watch keeps working")
        var isDir: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && !isDir.boolValue, "never a package")
        let src = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        #expect(CGImageSourceGetType(src) as String? == UTType.png.identifier)
        #expect(try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path) == ["photo.png"],
                "nothing written beside it")
    }

    @Test func jpegStaysJpegAndShrinksTheFileProperly() throws {
        // Start with a bigger file than the result: an in-place write must truncate.
        let url = try Self.tempFile("frame.jpg", contents: Data(repeating: 0xAB, count: 2_000_000))
        let link = try #require(LinkedImage(url: url, requester: "Flimmer"))
        try link.write(Self.image())
        let data = try Data(contentsOf: url)
        #expect(Array(data.prefix(3)) == [0xFF, 0xD8, 0xFF], "a JPEG")
        #expect(data.count < 100_000)
        let src = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        #expect(CGImageSourceGetType(src) as String? == UTType.jpeg.identifier)
        #expect(CGImageSourceCreateImageAtIndex(src, 0, nil)?.width == 64)
    }

    @Test func aGlimmerDocumentOnlyEverReadsAndWritesGlimmerFiles() {
        // Autosave writes the document's own type; with an image type here it could turn
        // a handed-over JPEG into a package, which happened once.
        #expect(UTType.glimmerDocumentTypes == [.glimmerDocument])
        for type in [UTType.image, .png, .jpeg, .heic, .tiff] {
            #expect(!UTType.glimmerDocumentTypes.contains { $0.conforms(to: type) }, "\(type)")
        }
    }
}
