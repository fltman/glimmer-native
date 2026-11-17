// Reads every element of every window of an app the way an assistive tool does: role,
// title, description, value, help and the element that titles it. A view that can't stand
// being read (the Assistant's messages crashed the app on 2026-11-16) shows up as the app
// being gone afterwards, which scripts/test-accessibility.sh checks.
//   axread <pid>   → prints every text it read, one per line, then "<elements> elements in <windows> windows"
import ApplicationServices
import Foundation

//   axread <pid> --press <role> <name>   → presses the first element of that role with that name (to open a menu to read)
//   axread <pid> --show <role> <text>    → scrolls the first element with that name, or a text that contains it, into view (before a picture is taken)
//   axread <pid> --enabled <role> <name> → prints "enabled" or "disabled" for that element (a button that must be grey)
//   axread <pid> --titles                → prints "menu<TAB>title" for every item of every menu and "button<TAB>title" for every button in the windows (scripts/check-title-case.py)
//   axread <pid> --frame <role> <name>   → prints that element's place on screen as "x y width height" (points), for the-apps/tools/safepointer
let arguments = CommandLine.arguments
guard arguments.count == 2 || (arguments.count == 3 && arguments[2] == "--titles") || (arguments.count == 5 && ["--press", "--frame", "--show", "--enabled"].contains(arguments[2])), let pid = pid_t(arguments[1]) else {
    print("usage: axread <pid> [--press <role> <name> | --frame <role> <name> | --show <role> <text> | --enabled <role> <name>]"); exit(2)
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
    // What a slider or stepper says its value is ("0.25 stops"): the words VoiceOver speaks for it.
    if let spoken = attribute(element, kAXValueDescriptionAttribute as String) as? String, !spoken.isEmpty {
        print(spoken.replacingOccurrences(of: "\n", with: " "))
    }
    guard depth < 60, let children = attribute(element, kAXChildrenAttribute as String) as? [AXUIElement] else { return }
    for child in children { read(child, depth: depth + 1) }
}
let app = AXUIElementCreateApplication(pid)
AXUIElementSetMessagingTimeout(app, 5)
let windows = attribute(app, kAXWindowsAttribute as String) as? [AXUIElement] ?? []
if arguments.count == 3 {
    func titles(_ element: AXUIElement, depth: Int, menu: Bool) {
        let role = attribute(element, kAXRoleAttribute as String) as? String ?? ""
        // A SwiftUI button says its title as its description.
        let said = [kAXTitleAttribute, kAXDescriptionAttribute].compactMap { attribute(element, $0 as String) as? String }.first { !$0.isEmpty }
        if let title = said {
            if menu, role == kAXMenuItemRole as String || role == kAXMenuBarItemRole as String { print("menu\t\(title)") }
            if !menu, [kAXButtonRole as String, kAXMenuButtonRole as String].contains(role) { print("button\t\(title)") }
        }
        // Not Glimmer's own titles: the Apple menu, the files the person opened lately, the system's services.
        if menu, let said, ["Apple", "Open Recent", "Services"].contains(said) { return }
        guard depth < 60, let children = attribute(element, kAXChildrenAttribute as String) as? [AXUIElement] else { return }
        for child in children { titles(child, depth: depth + 1, menu: menu) }
    }
    if let bar = attribute(app, kAXMenuBarAttribute as String) { titles(bar as! AXUIElement, depth: 0, menu: true) }
    for window in windows { titles(window, depth: 0, menu: false) }
    exit(0)
}
if arguments.count == 5 {
    func find(_ element: AXUIElement, depth: Int) -> AXUIElement? {
        if arguments[3] == "any" || attribute(element, kAXRoleAttribute as String) as? String == arguments[3] {   // "any": whatever its role
            var names = [attribute(element, kAXDescriptionAttribute as String) as? String, attribute(element, kAXTitleAttribute as String) as? String]
            if let title = attribute(element, kAXTitleUIElementAttribute as String) {
                names.append(attribute(title as! AXUIElement, kAXValueAttribute as String) as? String)
            }
            // A pop-up can also be named by what it shows now: two pop-ups with the same label are told apart so.
            if attribute(element, kAXRoleAttribute as String) as? String == "AXPopUpButton" { names.append(attribute(element, kAXValueAttribute as String) as? String) }
            if names.contains(arguments[4]) { return element }
            // To bring something into view, a text that contains the words is enough.
            if arguments[2] == "--show", let value = attribute(element, kAXValueAttribute as String) as? String, value.contains(arguments[4]) { return element }
        }
        guard depth < 60 else { return nil }
        for child in attribute(element, kAXChildrenAttribute as String) as? [AXUIElement] ?? [] {
            if let hit = find(child, depth: depth + 1) { return hit }
        }
        return nil
    }
    for window in windows {
        if let hit = find(window, depth: 0) {
            if arguments[2] == "--show" {
                // Brought into view through the scroll bar of the scroll area it sits in: the element's own
                // "scroll to visible" does nothing for SwiftUI's lists and forms.
                func frame(_ e: AXUIElement) -> CGRect? {
                    var point = CGPoint.zero, size = CGSize.zero
                    guard let p = attribute(e, kAXPositionAttribute as String), let z = attribute(e, kAXSizeAttribute as String),
                          AXValueGetValue(p as! AXValue, .cgPoint, &point), AXValueGetValue(z as! AXValue, .cgSize, &size) else { return nil }
                    return CGRect(origin: point, size: size)
                }
                var area: AXUIElement? = hit
                while let current = area, attribute(current, kAXRoleAttribute as String) as? String != "AXScrollArea" {
                    area = attribute(current, kAXParentAttribute as String).map { $0 as! AXUIElement }
                }
                guard let area, let bar = attribute(area, kAXVerticalScrollBarAttribute as String), let view = frame(area) else { print("in view (nothing to scroll)"); exit(0) }
                func inView() -> Bool { frame(hit).map { $0.minY >= view.minY && $0.maxY <= view.maxY } ?? false }
                if inView() { print("in view"); exit(0) }
                for step in 0...20 {
                    AXUIElementSetAttributeValue(bar as! AXUIElement, kAXValueAttribute as CFString, NSNumber(value: Double(step) / 20))
                    usleep(120_000)
                    if inView() { print("shown"); exit(0) }
                }
                print("found, but it could not be scrolled into view"); exit(1)
            }
            if arguments[2] == "--enabled" {
                print((attribute(hit, kAXEnabledAttribute as String) as? Bool) == false ? "disabled" : "enabled"); exit(0)
            }
            if arguments[2] == "--frame" {
                var point = CGPoint.zero, size = CGSize.zero
                guard let p = attribute(hit, kAXPositionAttribute as String), let z = attribute(hit, kAXSizeAttribute as String),
                      AXValueGetValue(p as! AXValue, .cgPoint, &point), AXValueGetValue(z as! AXValue, .cgSize, &size) else { print("no frame"); exit(1) }
                print("\(Int(point.x)) \(Int(point.y)) \(Int(size.width)) \(Int(size.height))"); exit(0)
            }
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
