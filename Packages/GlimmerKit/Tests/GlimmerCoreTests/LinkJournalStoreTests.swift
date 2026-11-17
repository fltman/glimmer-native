import Foundation
import Metal
import Testing
@testable import GlimmerCore

/// The link journal's writer (SIBLINGS.md §6.6): an entry on disk is always a whole one, a step writes only what
/// it changed, and a step that does not fit touches nothing.
@Suite struct LinkJournalStoreTests {
    /// A layer of pixels that don't compress, so its file has a size worth measuring.
    static func noise(_ name: String, seed start: UInt32, tiles count: Int) -> Layer {
        var tiles: [TileCoord: Tile] = [:]
        var seed = start
        for i in 0..<count {
            let texture = (try! TileTexture.makeTexture())
            var px = [Float16](repeating: 0, count: TileGeometry.size * TileGeometry.size * 4)
            for j in px.indices { seed = seed &* 1_664_525 &+ 1_013_904_223; px[j] = Float16(Float(seed >> 8) / 16_777_216) }
            px.withUnsafeBytes {
                texture.replace(region: MTLRegionMake2D(0, 0, TileGeometry.size, TileGeometry.size), mipmapLevel: 0,
                                withBytes: $0.baseAddress!, bytesPerRow: TileGeometry.bytesPerRow)
            }
            tiles[TileCoord(i % 4, i / 4)] = .texture(TileTexture(texture))
        }
        return Layer(name: name, content: .raster(TileGrid(tiles)))
    }

    static func entryFolder(in root: URL = FileManager.default.temporaryDirectory) -> URL {
        root.appending(path: "journal-test-\(UUID().uuidString)", directoryHint: .isDirectory)
    }

    static func record(_ id: String = "E1", waiting steps: Int) -> LinkJournalRecord {
        LinkJournalRecord(id: id, link: DocumentLink(bookmark: nil, path: "/tmp/photo.png", requester: "Flimmer"), fileName: "photo.png",
                          unreturned: steps > 0, unreturnedSteps: steps, linkedAt: Date(timeIntervalSince1970: 1_800_000_000), writtenAt: Date())
    }

    /// The entry as a launch would read it.
    static func onDisk(_ folder: URL) throws -> (state: DocumentState, record: LinkJournalRecord, files: [String: Data]) {
        let package = folder.appending(path: LinkJournalWriter.workCopyName)
        let state = try GlimmerPackage.state(from: FileWrapper(url: package, options: .immediate))
        let record = try LinkJournalRecord.decoder.decode(LinkJournalRecord.self, from: Data(contentsOf: folder.appending(path: LinkJournalWriter.recordName)))
        var files: [String: Data] = [:]
        for name in try FileManager.default.subpathsOfDirectory(atPath: package.path) {
            var isDirectory: ObjCBool = false
            let url = package.appending(path: name)
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue { files[name] = try Data(contentsOf: url) }
        }
        return (state, record, files)
    }

    static func twoStates() -> (before: DocumentState, after: DocumentState) {
        let a = noise("A", seed: 1, tiles: 4), b = noise("B", seed: 2, tiles: 4), c = noise("C", seed: 3, tiles: 4)
        let before = DocumentState(width: 1024, height: 256, layers: [a, b, c], activeLayerID: c.id)
        let d = noise("D", seed: 4, tiles: 1)
        let after = DocumentState(width: 1024, height: 256, layers: [a, b, c, d], activeLayerID: d.id)
        return (before, after)
    }

    @Test func aStepWritesOnlyWhatItChangedAndTheRestAreTheSameFilesOnDisk() async throws {
        let folder = Self.entryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let (before, after) = Self.twoStates()
        let writer = LinkJournalWriter(folder: folder)
        let first = try await writer.write(record: Self.record(waiting: 0), state: before)
        let old = try Self.onDisk(folder)
        #expect(old.state.layers.count == 3 && old.record.unreturned == false)
        func fileNumbers() throws -> [String: Int] {
            var numbers: [String: Int] = [:]
            for name in old.files.keys {
                numbers[name] = try FileManager.default.attributesOfItem(atPath: folder.appending(path: LinkJournalWriter.workCopyName).appending(path: name).path)[.systemFileNumber] as? Int
            }
            return numbers
        }
        let numbersBefore = try fileNumbers()
        let second = try await writer.write(record: Self.record(waiting: 1), state: after)
        let new = try Self.onDisk(folder)
        #expect(new.state.layers.count == 4 && new.record.unreturned && new.record.unreturnedSteps == 1)
        #expect(second.bytesWritten * 3 < first.bytesWritten, "the step wrote \(second.bytesWritten) bytes, the whole entry was \(first.bytesWritten)")
        // The three layers the step left alone are the very same files (hard links), not copies.
        let numbersAfter = try fileNumbers()
        let same = numbersBefore.filter { numbersAfter[$0.key] == $0.value }.count
        #expect(same >= 3, "\(same) of \(numbersBefore.count) files are the same files on disk as before the step")
        #expect(!FileManager.default.fileExists(atPath: folder.appending(path: LinkJournalWriter.stagingName).path))
        // A writer that starts again (a relaunch) reads what is there, and does not write every layer again.
        let again = LinkJournalWriter(folder: folder)
        let third = try await again.write(record: Self.record(waiting: 1), state: after)
        #expect(third.bytesWritten < 4096, "a write with nothing changed after a relaunch wrote \(third.bytesWritten) bytes")
    }

    /// A stop between two files of a step, or with the new copy complete but not yet in place: what a launch reads is
    /// the state before the step, whole, byte for byte.
    @Test(arguments: [LinkJournalWriter.StopPoint.afterFiles(1), .beforeSwap])
    func aStopBeforeTheNewCopyIsInPlaceLeavesTheOldStateWhole(_ point: LinkJournalWriter.StopPoint) async throws {
        let folder = Self.entryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let (before, after) = Self.twoStates()
        let writer = LinkJournalWriter(folder: folder)
        _ = try await writer.write(record: Self.record(waiting: 0), state: before)
        let old = try Self.onDisk(folder)
        await writer.stopNextWrite(at: point)
        await #expect(throws: LinkJournalWriter.Stopped.self) { try await writer.write(record: Self.record(waiting: 1), state: after) }
        let found = try Self.onDisk(folder)
        #expect(found.state.layers.count == 3 && found.state.layers.map(\.name) == ["A", "B", "C"])
        #expect(found.files == old.files, "every file of the work copy is as it was before the step")
        // The record was written first: the entry says something waits, so the launch opens it rather than dropping it.
        #expect(found.record.unreturned && found.record.unreturnedSteps == 1)
        // The next write (after a relaunch: a new writer) clears away what the stop left and completes.
        let next = LinkJournalWriter(folder: folder)
        _ = try await next.write(record: Self.record(waiting: 1), state: after)
        #expect(try Self.onDisk(folder).state.layers.count == 4)
        #expect(!FileManager.default.fileExists(atPath: folder.appending(path: LinkJournalWriter.stagingName).path))
    }

    /// A stop with the new copy in place, before the record is written again: the state after the step, whole.
    @Test func aStopAfterTheNewCopyIsInPlaceLeavesTheNewStateWhole() async throws {
        let folder = Self.entryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let (before, after) = Self.twoStates()
        let writer = LinkJournalWriter(folder: folder)
        _ = try await writer.write(record: Self.record(waiting: 0), state: before)
        await writer.stopNextWrite(at: .beforeRecord)
        await #expect(throws: LinkJournalWriter.Stopped.self) { try await writer.write(record: Self.record(waiting: 1), state: after) }
        let found = try Self.onDisk(folder)
        #expect(found.state.layers.map(\.name) == ["A", "B", "C", "D"])
        #expect(found.record.unreturned && found.record.unreturnedSteps == 1)
    }

    @Test func theSizeOfAnEntryCountsEachFileOnce() async throws {
        let folder = Self.entryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let (before, _) = Self.twoStates()
        let outcome = try await LinkJournalWriter(folder: folder).write(record: Self.record(waiting: 0), state: before)
        let size = LinkJournalWriter.bytes(of: folder)
        #expect(abs(size - outcome.bytes) < 4096, "\(size) on disk, \(outcome.bytes) reported")
    }

    /// Run by scripts/test-disk-full.sh with a small, nearly full disk image mounted: a step that does not fit is
    /// refused before anything is written, says how much it needed, and the entry kept before is whole.
    @Test func aStepThatDoesNotFitTouchesNothingAndSaysSo() async throws {
        guard let path = ProcessInfo.processInfo.environment["GLIMMER_FULL_DISK"], !path.isEmpty else { return }
        let folder = Self.entryFolder(in: URL(fileURLWithPath: path, isDirectory: true))
        defer { try? FileManager.default.removeItem(at: folder) }
        let small = DocumentState.new(width: 300, height: 200, background: .white)
        let writer = LinkJournalWriter(folder: folder)
        _ = try await writer.write(record: Self.record(waiting: 0), state: small)
        let old = try Self.onDisk(folder)
        var big = small
        big.layers.append(Self.noise("Too much", seed: 9, tiles: 40))
        do {
            _ = try await writer.write(record: Self.record(waiting: 1), state: big)
            Issue.record("a step of about 20 MB was written to a disk with about 3 MB free")
        } catch let failure as LinkJournalWriter.Failure {
            guard case .noRoom(let needed, let free) = failure else { return }
            #expect(needed > free && needed > 5_000_000, "needed \(needed), free \(free)")
            #expect(failure.errorDescription?.contains("isn't enough room") == true)
        }
        let found = try Self.onDisk(folder)
        #expect(found.files == old.files && found.state.layers.count == old.state.layers.count, "the entry kept before is whole")
        #expect(found.record.unreturned == false, "nothing of the entry was touched, the record included")
        #expect(!FileManager.default.fileExists(atPath: folder.appending(path: LinkJournalWriter.stagingName).path), "nothing half-built is left")
        // A small step still fits.
        var little = small
        little.layers.append(Layer(name: "Note", content: .raster(TileGrid([:]))))
        _ = try await writer.write(record: Self.record(waiting: 1), state: little)
        #expect(try Self.onDisk(folder).state.layers.count == old.state.layers.count + 1)
    }
}
