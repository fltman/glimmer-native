import Foundation
import Metal

public enum RenderError: Error {
    case noMetalDevice
    case libraryUnavailable(String)
    case resourceCreationFailed(String)
}

/// Shared Metal device, queue and shader library.
///
/// `@unchecked Sendable`: all stored properties are immutable after init, and
/// Metal devices, queues, libraries and pipeline states are thread-safe.
public final class MetalContext: @unchecked Sendable {
    public let device: MTLDevice
    public let commandQueue: MTLCommandQueue
    public let library: MTLLibrary

    public static let shared: MetalContext? = try? MetalContext()

    public init(device: MTLDevice? = MTLCreateSystemDefaultDevice()) throws {
        guard let device else { throw RenderError.noMetalDevice }
        guard let queue = device.makeCommandQueue() else {
            throw RenderError.resourceCreationFailed("command queue")
        }
        self.device = device
        self.commandQueue = queue
        self.library = try Self.loadLibrary(device: device)
    }

    private static func loadLibrary(device: MTLDevice) throws -> MTLLibrary {
        // Xcode compiles the package's .metal files into default.metallib.
        if let library = try? device.makeDefaultLibrary(bundle: .module) {
            return library
        }
        // `swift build` copies them as source instead; compile at runtime.
        let urls = Bundle.module.urls(forResourcesWithExtension: "metal", subdirectory: nil) ?? []
        guard !urls.isEmpty else {
            throw RenderError.libraryUnavailable("no default.metallib and no .metal sources in bundle")
        }
        let source = try urls
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .map { try String(contentsOf: $0, encoding: .utf8) }
            .joined(separator: "\n")
        do {
            return try device.makeLibrary(source: source, options: nil)
        } catch {
            throw RenderError.libraryUnavailable(String(describing: error))
        }
    }
}
