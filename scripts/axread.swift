// Reads every element of every window of an app the way an assistive tool does: role,
// title, description, value, help and the element that titles it. A view that can't stand
// being read (the Assistant's messages crashed the app on 2026-11-16) shows up as the app
// being gone afterwards, which scripts/test-accessibility.sh checks.
//   axread <pid>   → prints every text it read, one per line, then "<elements> elements in <windows> windows"
import ApplicationServices
import Foundation

//   axread <pid> --press <role> <name>   → presses the first element of that role with that name (to open a menu to read)
let arguments = CommandLine.arguments
guard arguments.count == 2 || (arguments.count == 5 && arguments[2] == "--press"), let pid = pid_t(arguments[1]) else {
    print("usage: axread <pid> [--press <role> <name>]"); exit(2)
}
func attribute(_ element: AXUIElement, _ name: String) -> AnyObject? {
    var value: AnyObject?
    return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
}
var count = 0
func read(_ element: AXUIElement, depth: Int) {
    count += 1
    for name in [kAXRoleAttribute, kAXSubroleAttribute, kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute, kAXHelpAttribute,
                 kAXRoleDescriptionAttribute, kAXIdentifierAttribute, kAXEnabledAttribute] {
        let value = attribute(element, name as String)
        if [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute].contains(name), let text = value as? String, !text.isEmpty {
            print(text.replacingOccurrences(of: "\n", with: " "))
        }
    }
    if let title = attribute(element, kAXTitleUIElementAttribute as String) {
        _ = attribute(title as! AXUIElement, kAXValueAttribute as String)
    }
    guard depth < 60, let children = attribute(element, kAXChildrenAttribute as String) as? [AXUIElement] else { return }
    for child in children { read(child, depth: depth + 1) }
}
let app = AXUIElementCreateApplication(pid)
AXUIElementSetMessagingTimeout(app, 5)
let windows = attribute(app, kAXWindowsAttribute as String) as? [AXUIElement] ?? []
if arguments.count == 5 {
    func find(_ element: AXUIElement, depth: Int) -> AXUIElement? {
        if attribute(element, kAXRoleAttribute as String) as? String == arguments[3] {
            var names = [attribute(element, kAXDescriptionAttribute as String) as? String, attribute(element, kAXTitleAttribute as String) as? String]
            if let title = attribute(element, kAXTitleUIElementAttribute as String) {
                names.append(attribute(title as! AXUIElement, kAXValueAttribute as String) as? String)
            }
            if names.contains(arguments[4]) { return element }
        }
        guard depth < 60 else { return nil }
        for child in attribute(element, kAXChildrenAttribute as String) as? [AXUIElement] ?? [] {
            if let hit = find(child, depth: depth + 1) { return hit }
        }
        return nil
    }
    for window in windows {
        if let hit = find(window, depth: 0) {
            // A menu keeps the press from returning until it closes; the caller runs this in the background.
            _ = AXUIElementPerformAction(hit, kAXPressAction as CFString)
            print("pressed"); exit(0)
        }
    }
    print("no \(arguments[3]) named \(arguments[4])"); exit(1)
}
for window in windows { read(window, depth: 0) }
print("\(count) elements in \(windows.count) windows")
exit(windows.isEmpty ? 1 : 0)
