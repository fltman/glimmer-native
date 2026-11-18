import Foundation
import Testing
@testable import GlimmerCore

@Suite struct BatchFilesTests {
    /// A folder with images (one in a subfolder), a text file and a hidden image; removed afterwards.
    private func folder() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appending(path: "batch-files-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir.appending(path: "inner"), withIntermediateDirectories: true)
        for name in ["b10.jpg", "b2.png", "a.heic", "notes.txt", ".hidden.jpg", "inner/deep.jpg"] {
            try Data([0]).write(to: dir.appending(path: name))
        }
        return dir
    }

    @Test func aFolderGivesTheImagesDirectlyInsideItSortedByName() throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(BatchFiles.images(in: [dir]).map(\.lastPathComponent) == ["a.heic", "b2.png", "b10.jpg"])
    }

    @Test func filesKeepTheirOrderAndOnlyImagesCount() throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let picked = [dir.appending(path: "b2.png"), dir.appending(path: "notes.txt"), dir.appending(path: "a.heic")]
        #expect(BatchFiles.images(in: picked).map(\.lastPathComponent) == ["b2.png", "a.heic"])
    }

    @Test func mergeAddsEachFileOnceAfterWhatIsThere() {
        let a = URL(fileURLWithPath: "/x/a.jpg"), b = URL(fileURLWithPath: "/x/b.jpg"), c = URL(fileURLWithPath: "/x/c.jpg")
        #expect(BatchFiles.merge([a, b], with: [b, c, c, a]) == [a, b, c])
    }

    @Test func mergeOfTwoLargeListsKeepsEveryFileOnce() {
        // A hundred thousand files added to a hundred thousand, half of them already there.
        let first = (0..<100_000).map { URL(fileURLWithPath: "/x/\($0).jpg") }
        let second = (50_000..<150_000).map { URL(fileURLWithPath: "/x/\($0).jpg") }
        let merged = BatchFiles.merge(first, with: second)
        #expect(merged.count == 150_000)
        #expect(merged.last == URL(fileURLWithPath: "/x/149999.jpg"))
    }
}
