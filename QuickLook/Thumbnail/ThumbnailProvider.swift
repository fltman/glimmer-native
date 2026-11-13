import AppKit
import QuickLookThumbnailing

/// Finder thumbnails for .glimmer packages: draws the PNG the app saves inside
/// the package (QuickLook/Thumbnail.png), so no rendering happens here.
final class ThumbnailProvider: QLThumbnailProvider {
    override func provideThumbnail(for request: QLFileThumbnailRequest,
                                   _ handler: @escaping (QLThumbnailReply?, Error?) -> Void) {
        let url = request.fileURL.appending(path: "QuickLook/Thumbnail.png")
        guard let image = NSImage(contentsOf: url), image.size.width > 0, image.size.height > 0 else {
            handler(nil, CocoaError(.fileReadNoSuchFile))
            return
        }
        let max = request.maximumSize
        let scale = min(max.width / image.size.width, max.height / image.size.height, 1)
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        handler(QLThumbnailReply(contextSize: size, currentContextDrawing: {
            image.draw(in: CGRect(origin: .zero, size: size))
            return true
        }), nil)
    }
}
