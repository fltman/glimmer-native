import Foundation
import UniformTypeIdentifiers

/// The images a batch takes from what was dropped or chosen: image files, `.glimmer` documents, and the
/// images directly inside a folder (sorted by name, not its subfolders). Pure file work, so it can run off
/// the main thread: a folder of a hundred thousand pictures must not stop the window while it is read.
public enum BatchFiles {
    /// The images among `urls`, in the order given, a folder's images sorted by name.
    public static func images(in urls: [URL]) -> [URL] {
        var found: [URL] = []
        for url in urls {
            if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true, url.pathExtension.lowercased() != "glimmer" {
                let items = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.contentTypeKey],
                                                                          options: [.skipsHiddenFiles])) ?? []
                found += items.filter(isImage).sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            } else if isImage(url) {
                found.append(url)
            }
        }
        return found
    }

    /// `existing` followed by the files of `new` that are in neither, each once. A set, not a scan of the
    /// list per file: adding a second large folder to a large list stays quick.
    public static func merge(_ existing: [URL], with new: [URL]) -> [URL] {
        var known = Set(existing)
        return existing + new.filter { known.insert($0).inserted }
    }

    public static func isImage(_ url: URL) -> Bool {
        if url.pathExtension.lowercased() == "glimmer" { return true }
        let type = (try? url.resourceValues(forKeys: [.contentTypeKey]).contentType) ?? UTType(filenameExtension: url.pathExtension)
        return type?.conforms(to: .image) == true
    }
}
