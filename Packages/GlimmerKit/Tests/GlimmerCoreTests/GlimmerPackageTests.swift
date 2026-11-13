import Foundation
import Testing
@testable import GlimmerCore

@Suite struct GlimmerPackageTests {
    @Test func roundTrip() throws {
        let manifest = DocumentManifest(width: 4000, height: 3000, colorSpace: .displayP3, blendSpace: .gamma)
        let wrapper = try GlimmerPackage.fileWrapper(for: manifest)
        #expect(wrapper.isDirectory)
        #expect(try GlimmerPackage.manifest(from: wrapper) == manifest)
    }

    @Test func roundTripThroughDisk() throws {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "roundtrip-\(UUID().uuidString).glimmer")
        defer { try? FileManager.default.removeItem(at: url) }

        try GlimmerPackage.fileWrapper(for: .defaultNewDocument).write(to: url, options: .atomic, originalContentsURL: nil)
        let read = try FileWrapper(url: url)
        #expect(try GlimmerPackage.manifest(from: read) == .defaultNewDocument)
    }

    @Test func rejectsNewerFormat() throws {
        let json = #"{"formatVersion": 99, "width": 10, "height": 10, "colorSpace": "sRGB", "blendSpace": "linear"}"#
        #expect(throws: GlimmerPackageError.unsupportedFormatVersion(99)) {
            try GlimmerPackage.decodeManifest(Data(json.utf8))
        }
    }

    @Test(arguments: [
        #"{"width": 10}"#,
        #"{"formatVersion": 1, "width": 0, "height": 10, "colorSpace": "sRGB", "blendSpace": "linear"}"#,
        #"{"formatVersion": 1, "width": 10, "height": 10, "colorSpace": "cmyk", "blendSpace": "linear"}"#,
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
            try GlimmerPackage.manifest(from: FileWrapper(directoryWithFileWrappers: [:]))
        }
        #expect(throws: GlimmerPackageError.notAPackage) {
            try GlimmerPackage.manifest(from: FileWrapper(regularFileWithContents: Data()))
        }
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
        #expect(CommandRegistry.standard.descriptors(in: .view).count == 7)
    }
}
