import CryptoKit
import Foundation
import Network
import Testing
@testable import GlimmerAI

/// The model download, against a sample server on this Mac's loopback with made-up files:
/// no test reaches the network. Each file is checked against the register (size, then SHA-256
/// or git blob id), and a file that differs stops the download with nothing installed.
@Suite(.serialized) struct ModelDownloadTests {
    /// Serves `files` (path → bytes) over HTTP on 127.0.0.1 and records the paths asked for.
    final class SampleServer: @unchecked Sendable {
        let listener: NWListener
        private let lock = NSLock()
        private var files: [String: Data]
        private var asked: [String] = []
        private(set) var port: UInt16 = 0

        init(files: [String: Data]) async throws {
            self.files = files
            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
            listener = try NWListener(using: parameters)
            listener.newConnectionHandler = { [weak self] connection in self?.serve(connection) }
            let once = Once()
            port = try await withCheckedThrowingContinuation { (done: CheckedContinuation<UInt16, Error>) in
                listener.stateUpdateHandler = { [weak listener] state in
                    switch state {
                    case .ready: if once.first() { done.resume(returning: listener?.port?.rawValue ?? 0) }
                    case .failed(let e): if once.first() { done.resume(throwing: e) }
                    default: break
                    }
                }
                listener.start(queue: .global())
            }
        }

        var base: URL { URL(string: "http://127.0.0.1:\(port)")! }
        var requests: [String] { lock.withLock { asked } }

        private func serve(_ connection: NWConnection) {
            connection.start(queue: .global())
            connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, _, _ in
                guard let self, let data, let head = String(data: data, encoding: .utf8) else { connection.cancel(); return }
                let path = head.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
                let body = self.lock.withLock { () -> Data? in
                    self.asked.append(path)
                    return self.files[path]
                }
                let status = body == nil ? "404 Not Found" : "200 OK"
                let payload = body ?? Data()
                let response = Data("HTTP/1.1 \(status)\r\nContent-Length: \(payload.count)\r\nConnection: close\r\n\r\n".utf8) + payload
                connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
            }
        }

        func stop() { listener.cancel() }
    }

    /// True the first time only (a continuation is resumed once).
    final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false
        func first() -> Bool { lock.withLock { defer { done = true }; return !done } }
    }

    static func sha256(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    static func gitBlob(_ data: Data) -> String {
        Insecure.SHA1.hash(data: Data("blob \(data.count)\u{0}".utf8) + data).map { String(format: "%02x", $0) }.joined()
    }

    func folder() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "glimmer-download-test-\(UUID().uuidString)")
    }

    @Test func gitBlobIdIsGitsOwn() throws {
        // `printf 'hello\n' | git hash-object --stdin`
        let url = folder()
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("hello\n".utf8).write(to: url)
        #expect(try FileChecksum.gitBlob(of: url, size: 6) == "ce013625030ba8dba906f756967f9e9ca394464a")
    }

    @Test func matchingFilesArriveAndAreChecked() async throws {
        let manifest = Data(#"{"fileFormatVersion": "1.0.0"}"#.utf8)
        let weights = Data((0..<300_000).map { UInt8($0 % 251) })
        let server = try await SampleServer(files: ["/repo/resolve/abc123/Pkg.mlpackage/Manifest.json": manifest,
                                                    "/repo/resolve/abc123/Pkg.mlpackage/weights.bin": weights])
        defer { server.stop() }
        let files = [Requirement.File(path: "Pkg.mlpackage/Manifest.json", size: manifest.count, sha256: nil, gitBlob: Self.gitBlob(manifest)),
                     Requirement.File(path: "Pkg.mlpackage/weights.bin", size: weights.count, sha256: Self.sha256(weights), gitBlob: nil)]
        let staging = folder()
        defer { try? FileManager.default.removeItem(at: staging) }
        let seen = Progress()
        try await ModelStore.fetchVerified(files, from: server.base.appending(path: "repo/resolve/abc123"), into: staging,
                                           model: "Sample", progress: { seen.completedUnitCount = Int64($0 * 100) })
        #expect(try Data(contentsOf: staging.appending(path: "Pkg.mlpackage/weights.bin")) == weights)
        #expect(seen.completedUnitCount == 100)
        #expect(server.requests == ["/repo/resolve/abc123/Pkg.mlpackage/Manifest.json", "/repo/resolve/abc123/Pkg.mlpackage/weights.bin"])
    }

    @Test func aFileWithTheWrongChecksumStopsTheDownload() async throws {
        let weights = Data(repeating: 7, count: 4096)
        let tampered = Data(repeating: 8, count: 4096)  // same size, other bytes
        let server = try await SampleServer(files: ["/r/a.bin": tampered, "/r/b.bin": weights])
        defer { server.stop() }
        let files = [Requirement.File(path: "a.bin", size: weights.count, sha256: Self.sha256(weights), gitBlob: nil),
                     Requirement.File(path: "b.bin", size: weights.count, sha256: Self.sha256(weights), gitBlob: nil)]
        let staging = folder()
        defer { try? FileManager.default.removeItem(at: staging) }
        await #expect(throws: ModelChecksumError.self) {
            try await ModelStore.fetchVerified(files, from: server.base.appending(path: "r"), into: staging, model: "Sample", progress: nil)
        }
        #expect(server.requests == ["/r/a.bin"], "nothing more is fetched after a file that doesn't match")
    }

    @Test func aWrongManifestBlobOrSizeStopsTheDownload() async throws {
        let manifest = Data("{}".utf8)
        let server = try await SampleServer(files: ["/r/Manifest.json": Data("{ }".utf8), "/r/short.bin": Data(count: 10)])
        defer { server.stop() }
        let staging = folder()
        defer { try? FileManager.default.removeItem(at: staging) }
        let blob = [Requirement.File(path: "Manifest.json", size: 3, sha256: nil, gitBlob: Self.gitBlob(manifest))]
        do {
            try await ModelStore.fetchVerified(blob, from: server.base.appending(path: "r"), into: staging, model: "Sample", progress: nil)
            Issue.record("a wrong blob id was accepted")
        } catch let e as ModelChecksumError {
            #expect(e.reason.hasPrefix("git blob"))
        }
        let size = [Requirement.File(path: "short.bin", size: 11, sha256: String(repeating: "0", count: 64), gitBlob: nil)]
        do {
            try await ModelStore.fetchVerified(size, from: server.base.appending(path: "r"), into: staging, model: "Sample", progress: nil)
            Issue.record("a file of the wrong size was accepted")
        } catch let e as ModelChecksumError {
            #expect(e.reason == "10 bytes, not 11")
        }
    }

    /// The real download path against the sample server: it asks for the pinned commit, never
    /// `main`, and made-up files leave nothing installed and nothing in the staging folder.
    @Test func aDownloadOfMadeUpFilesInstallsNothing() async throws {
        let model = OnDeviceModel.depth
        let commit = try #require(model.requirement.source.commit)
        var files: [String: Data] = [:]
        for f in model.requirement.files { files["/\(model.repository)/resolve/\(commit)/\(f.path)"] = Data(count: f.size) }
        let server = try await SampleServer(files: files)
        defer { server.stop() }
        let root = folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ModelStore(root: root, source: server.base)
        await #expect(throws: ModelChecksumError.self) { try await store.download(model) }
        #expect(!store.isInstalled(model))
        #expect(server.requests.count == 1)
        #expect(server.requests.allSatisfy { $0.contains("/resolve/\(commit)/") && !$0.contains("/resolve/main/") })
        let left = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        #expect(left.isEmpty, "nothing installed: \(left)")
    }

    /// Loading a model that isn't on the Mac asks nothing of any server: it says what is missing.
    @Test func loadingAMissingModelNeverDownloads() async throws {
        let server = try await SampleServer(files: [:])
        defer { server.stop() }
        let root = folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ModelStore(root: root, source: server.base)
        do {
            _ = try await store.load(OnDeviceModel.segmentAnything.packages[0], of: .segmentAnything)
            Issue.record("a missing model loaded")
        } catch let e as ModelMissingError {
            #expect(e.missing == [.segmentAnything])
        }
        #expect(server.requests.isEmpty)
        #expect(store.missing(OnDeviceModel.allCases) == OnDeviceModel.allCases)
    }

    // MARK: Receipts and installs from 0.3.0

    /// A model "installed" as compiled folders, the way 0.3.0 left it: no receipt.
    func earlierInstall(_ model: OnDeviceModel, in root: URL) throws {
        for package in model.packages {
            try FileManager.default.createDirectory(at: root.appending(path: package.replacingOccurrences(of: ".mlpackage", with: ".mlmodelc")), withIntermediateDirectories: true)
        }
    }

    @Test func anInstallWithoutAReceiptIsUnverifiedAndKeepsWorking() async throws {
        let root = folder(), downloads = folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let server = try await SampleServer(files: [:])
        defer { server.stop() }
        let store = ModelStore(root: root, source: server.base, earlierDownloads: downloads)
        #expect(store.verification(.depth) == .notInstalled)
        try earlierInstall(.depth, in: root)
        #expect(store.isInstalled(.depth), "it still counts as installed: nothing stops working")
        #expect(store.verification(.depth) == .unverified)
        #expect(store.needsDownload(.depth))
        // 0.3.0's downloaded files are gone: it stays unverified, and nothing is fetched.
        #expect(await store.checkEarlierInstall(.depth) == .unverified)
        #expect(server.requests.isEmpty)
        #expect(ModelVerification.unverified.json as? Bool == false)
        #expect(ModelVerification.notInstalled.json is NSNull)
    }

    @Test func aReceiptVouchesOnlyForWhatTheRegisterListsNow() throws {
        let root = folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ModelStore(root: root)
        try earlierInstall(.segmentAnything, in: root)
        let good = ModelReceipt(Requirement.segmentAnything, how: "download")
        try JSONEncoder().encode(good).write(to: store.receiptURL(.segmentAnything))
        #expect(store.verification(.segmentAnything) == .verified)
        #expect(!store.needsDownload(.segmentAnything))
        // A receipt for another commit (or other files) vouches for nothing.
        var text = try String(contentsOf: store.receiptURL(.segmentAnything), encoding: .utf8)
        text = text.replacingOccurrences(of: Requirement.segmentAnything.source.commit!, with: String(repeating: "0", count: 40))
        try text.write(to: store.receiptURL(.segmentAnything), atomically: true, encoding: .utf8)
        #expect(store.verification(.segmentAnything) == .unverified)
    }

    @Test func removingAModelRemovesItsReceipt() async throws {
        let root = folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ModelStore(root: root)
        try earlierInstall(.depth, in: root)
        try JSONEncoder().encode(ModelReceipt(Requirement.depthAnything, how: "download")).write(to: store.receiptURL(.depth))
        try await store.remove(.depth)
        #expect(store.verification(.depth) == .notInstalled)
        #expect(!FileManager.default.fileExists(atPath: store.receiptURL(.depth).path))
    }

    /// 0.3.0's staging folders: a package whose files all match is found; a tampered one isn't.
    @Test func earlierDownloadedFilesAreCheckedBeforeTheyCount() throws {
        let downloads = folder()
        defer { try? FileManager.default.removeItem(at: downloads) }
        let manifest = Data("{}".utf8), weights = Data(repeating: 3, count: 2048)
        let files = [Requirement.File(path: "P.mlpackage/Manifest.json", size: manifest.count, sha256: nil, gitBlob: Self.gitBlob(manifest)),
                     Requirement.File(path: "P.mlpackage/w.bin", size: weights.count, sha256: Self.sha256(weights), gitBlob: nil)]
        func stage(_ name: String, weights w: Data) throws {
            let dir = downloads.appending(path: name).appending(path: "P.mlpackage")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try manifest.write(to: dir.appending(path: "Manifest.json"))
            try w.write(to: dir.appending(path: "w.bin"))
        }
        try stage("A", weights: Data(repeating: 4, count: 2048))
        #expect(ModelStore.earlierCopy(of: "P.mlpackage", files: files, in: downloads) == nil)
        try stage("B", weights: weights)
        #expect(ModelStore.earlierCopy(of: "P.mlpackage", files: files, in: downloads)?.lastPathComponent == "B")
    }

    @Test func requirementsSayWhetherAModelIsVerified() {
        #expect(Requirement.depthAnything.json(installed: true, installedVersion: nil, verified: false)["verified"] as? Bool == false)
        #expect(Requirement.depthAnything.json(installed: false, installedVersion: nil)["verified"] is NSNull)
    }
}
