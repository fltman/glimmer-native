import CoreGraphics
import Foundation

/// An image another app (Flimmer, Jämmer) handed Glimmer to edit, Photoshop-link style:
/// the other app watches the file and picks up the change when Glimmer saves.
///
/// The image is never opened *as* a document: it becomes an untitled Glimmer document,
/// so autosave can't touch the file. Only an explicit Save writes it, flattened, in the
/// same format, into the same file (in place, so the other app's file watch keeps working).
public struct LinkedImage: Sendable, Equatable {
    public var url: URL
    public var format: ExportOptions.Format
    /// The app that asked, for display ("Flimmer").
    public var requester: String

    public init?(url: URL, requester: String) {
        guard let format = Self.format(for: url) else { return nil }
        self.url = url
        self.format = format
        self.requester = requester
    }

    public var fileName: String { url.lastPathComponent }

    /// The format a file is written back in, from its extension; nil for formats Glimmer
    /// can't write (such as PSD), which open as ordinary new documents instead.
    public static func format(for url: URL) -> ExportOptions.Format? {
        switch url.pathExtension.lowercased() {
        case "png": .png
        case "jpg", "jpeg": .jpeg
        case "heic", "heif": .heic
        case "tif", "tiff": .tiff
        case "webp": .webp
        default: nil
        }
    }

    /// Encodes `image` in the file's format and writes it into the same file, replacing
    /// its contents in place (no temporary file beside it, no package).
    public func write(_ image: CGImage, quality: Double = 0.92) throws {
        let data = try ImageExporter.encode(image, options: ExportOptions(format: format, quality: quality))
        var coordinationError: NSError?
        var writeError: Error?
        NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: url, options: [], error: &coordinationError) { target in
            do {
                let handle = try FileHandle(forWritingTo: target)
                defer { try? handle.close() }
                try handle.truncate(atOffset: 0)
                try handle.write(contentsOf: data)
                try handle.synchronize()
            } catch {
                writeError = error
            }
        }
        if let error = coordinationError ?? writeError { throw error }
    }
}
