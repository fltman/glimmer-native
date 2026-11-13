import Foundation
import ImageIO
import QuickLookUI
import UniformTypeIdentifiers

/// Space-bar previews for .glimmer packages, from the flattened preview the app
/// saves inside the package (QuickLook/Preview.png).
final class PreviewProvider: QLPreviewProvider, QLPreviewingController {
    func providePreview(for request: QLFilePreviewRequest) async throws -> QLPreviewReply {
        let url = request.fileURL.appending(path: "QuickLook/Preview.png")
        let data = try Data(contentsOf: url)
        var size = CGSize(width: 800, height: 600)
        if let source = CGImageSourceCreateWithData(data as CFData, nil),
           let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           let w = props[kCGImagePropertyPixelWidth] as? CGFloat, let h = props[kCGImagePropertyPixelHeight] as? CGFloat {
            size = CGSize(width: w, height: h)
        }
        return QLPreviewReply(dataOfContentType: .png, contentSize: size) { _ in data }
    }
}
