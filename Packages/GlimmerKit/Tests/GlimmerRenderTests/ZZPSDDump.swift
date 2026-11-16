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
                    if let m = l.mask, let px = m.pixels, env["GLIMMER_PSD_DUMP_MASK"] != nil {
                        let mw = m.rect.right - m.rect.left, b = [UInt8](px)
                        func at(_ x: Int, _ y: Int) -> Int { let i = (y - m.rect.top) * mw + (x - m.rect.left); return i >= 0 && i < b.count ? Int(b[i]) : -1 }
                        print("DUMP   mask row 0, x 120...126: \((120...126).map { at($0, 0) }); row 1: \((120...126).map { at($0, 1) }); column 199, y 40...44: \((40...44).map { at(199, $0) }); column 198: \((40...44).map { at(198, $0) }); row 199: \((120...124).map { at($0, 199) })")
                    }
                    if let al = l.planes[-1], l.rect.right - l.rect.left > 0, env["GLIMMER_PSD_DUMP_MASK"] != nil {
                        let lw = l.rect.right - l.rect.left, b = [UInt8](al)
                        func at(_ x: Int, _ y: Int) -> Int { let i = (y - l.rect.top) * lw + (x - l.rect.left); return i >= 0 && i < b.count ? Int(b[i]) : -1 }
                        print("DUMP   alpha row 0, x 120...126: \((120...126).map { at($0, 0) }); row 1: \((120...126).map { at($0, 1) }); column 199: \((40...44).map { at(199, $0) }); column 198: \((40...44).map { at(198, $0) }); row 199: \((120...124).map { at($0, 199) }); row -2: \((120...124).map { at($0, -2) })")
                    }
                    if let c = l.blocks["curv"] { print("DUMP   curv \(c.count) bytes: \([UInt8](c.prefix(48)))") }
                    if let c = l.blocks["SoCo"] { var r = PSDBytes(c); try? r.skip(4); var b = 1000; print("DUMP   SoCo: \((try? PSDDescriptor.read(&r, budget: &b)).map { "\($0)" } ?? "unreadable")".prefix(300)) }
                }
            } catch { print("DUMP PSDFile error: \(error)") }
            // Where the two pictures differ, and by how much.
            if let (state, _) = try? PSDImport.document(from: data), let o = try? ImageExporter.flattenedSRGB(state, context: try context()),
               let t = PSDAppearance.flattenedPicture(in: data), let a = PSDAppearance.onWhite(o), let b = PSDAppearance.onWhite(t), a.count == b.count {
                let w = state.width
                var shown = 0, worst = 0, count = 0, minX = Int.max, maxX = 0, minY = Int.max, maxY = 0
                for i in stride(from: 0, to: a.count, by: 4) {
                    let d = max(abs(Int(a[i]) - Int(b[i])), abs(Int(a[i+1]) - Int(b[i+1])), abs(Int(a[i+2]) - Int(b[i+2])))
                    if d > 0 { worst = max(worst, d) }
                    if d > 4 {
                        count += 1; let x = (i / 4) % w, y = (i / 4) / w
                        minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
                        if shown < 14, count % 23 == 1 { shown += 1; print("DUMP   differs at (\(x),\(y)): ours \(a[i]),\(a[i+1]),\(a[i+2])  file \(b[i]),\(b[i+1]),\(b[i+2])") }
                    }
                }
                print("DUMP   \(count) pixels differ by more than 4; worst \(worst); box x \(minX)...\(maxX) y \(minY)...\(maxY) of \(w) wide")
            }
            if let (state, _) = try? PSDImport.document(from: data), let ours = try? ImageExporter.flattenedSRGB(state, context: try context()), let theirs = try? ImageImporter.image(from: data) {
                for (name, image) in [("ours", ours), ("theirs", theirs)] {
                    let dest = out.appending(path: "\(url.deletingPathExtension().lastPathComponent)-\(name).png")
                    if let d = CGImageDestinationCreateWithURL(dest as CFURL, UTType.png.identifier as CFString, 1, nil) { CGImageDestinationAddImage(d, image, nil); CGImageDestinationFinalize(d) }
                }
            }
        }
    }
}
