import Foundation
import Testing
import ImageIO
import UniformTypeIdentifiers
@testable import GlimmerCore
@testable import GlimmerRender

@Suite(.enabled(if: ProcessInfo.processInfo.environment["GLIMMER_PSD_DUMP"] != nil), .serialized)
struct ZZPSDDump {
    @Test func dump() throws {
        let env = ProcessInfo.processInfo.environment
        let out = URL(fileURLWithPath: env["GLIMMER_PSD_DUMP_OUT"] ?? NSTemporaryDirectory())
        for path in env["GLIMMER_PSD_DUMP"]!.split(separator: ":").map(String.init) {
            let url = URL(fileURLWithPath: path), data = try Data(contentsOf: url)
            print("DUMP == \(url.lastPathComponent) \(data.count) bytes")
            do {
                let file = try PSDFile(data)
                print("DUMP header \(file.header) composite planes \(file.composite.count)")
                for l in file.layers {
                    print("DUMP layer “\(l.name)” rect \(l.rect) blend '\(l.blendKey)' op \(l.opacity) vis \(l.isVisible) clip \(l.isClipped) group \(l.group) planes \(l.planes.mapValues(\.count).sorted { $0.key < $1.key }) mask \(l.mask.map { "\($0.rect) default \($0.defaultColor) disabled \($0.isDisabled) pixels \($0.pixels?.count ?? -1)" } ?? "-") keys \(l.extraKeys.joined(separator: " "))")
                    if let v = l.blocks["vmsk"] ?? l.blocks["vsms"] {
                        let bytes = [UInt8](v)
                        print("DUMP   vmsk \(v.count) bytes, version+flags: \(bytes.prefix(8)), selectors: \(stride(from: 8, to: min(bytes.count, 8 + 26 * 14), by: 26).map { Int(bytes[$0]) << 8 | Int(bytes[$0 + 1]) })")
                        print("DUMP   subpaths: \(PSDPath.subpaths(v.dropFirst(8), width: file.header.width, height: file.header.height).map { "\($0.isClosed ? "closed" : "open") \($0.anchors.map { "(\(Int($0.point.x)),\(Int($0.point.y)))" }.joined()) " })")
                    }
                    if let c = l.blocks["curv"] { print("DUMP   curv \(c.count) bytes: \([UInt8](c.prefix(48)))") }
                    if let c = l.blocks["SoCo"] { var r = PSDBytes(c); try? r.skip(4); var b = 1000; print("DUMP   SoCo: \((try? PSDDescriptor.read(&r, budget: &b)).map { "\($0)" } ?? "unreadable")".prefix(300)) }
                }
            } catch { print("DUMP PSDFile error: \(error)") }
            if let (state, _) = try? PSDImport.document(from: data), let ours = try? ImageExporter.flattenedSRGB(state, context: try context()), let theirs = try? ImageImporter.image(from: data) {
                for (name, image) in [("ours", ours), ("theirs", theirs)] {
                    let dest = out.appending(path: "\(url.deletingPathExtension().lastPathComponent)-\(name).png")
                    if let d = CGImageDestinationCreateWithURL(dest as CFURL, UTType.png.identifier as CFString, 1, nil) { CGImageDestinationAddImage(d, image, nil); CGImageDestinationFinalize(d) }
                }
            }
        }
    }
}
