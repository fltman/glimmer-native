// Pictures of one app's own windows, and nothing else on the screen: every window of the
// given process (sheets and panels are windows of their own) is captured by its id.
//
//   build/window-shot <pid> <folder> <name>     → <folder>/<name>-1.png, -2.png … (largest first)
//
// The series' rule (2026-11-16): each new sheet, alert, panel or bar is looked at as a picture
// too; an accessibility read does not see a sheet wider than its window or a wrapped label.
import AppKit
import CoreGraphics

let args = CommandLine.arguments
guard args.count == 4, let pid = Int32(args[1]) else { print("usage: window-shot <pid> <folder> <name>"); exit(2) }
let list = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]) ?? []
var windows: [(id: Int, area: Double)] = []
for w in list where (w[kCGWindowOwnerPID as String] as? Int32) == pid && (0...8).contains((w[kCGWindowLayer as String] as? Int) ?? -1) {   // ordinary windows and floating panels; not menus or the Dock
    guard let id = w[kCGWindowNumber as String] as? Int, let b = w[kCGWindowBounds as String] as? [String: Double],
          let width = b["Width"], let height = b["Height"], width > 40, height > 40 else { continue }
    windows.append((id, width * height))
}
windows.sort { $0.area > $1.area }
try? FileManager.default.createDirectory(atPath: args[2], withIntermediateDirectories: true)
for (n, w) in windows.prefix(4).enumerated() {
    let path = "\(args[2])/\(args[3])-\(n + 1).png"
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    p.arguments = ["-x", "-o", "-l\(w.id)", path]
    try? p.run(); p.waitUntilExit()
    print(path)
}
if windows.isEmpty { print("no windows"); exit(1) }
