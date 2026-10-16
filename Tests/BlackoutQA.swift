import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

func get(_ e: AXUIElement, _ attr: String) -> CFTypeRef? {
    var value: CFTypeRef?
    let err = AXUIElementCopyAttributeValue(e, attr as CFString, &value)
    return err == .success ? value : nil
}
func text(_ e: AXUIElement, _ attr: String) -> String { (get(e, attr) as? String) ?? "" }
func children(_ e: AXUIElement) -> [AXUIElement] {
    var all = (get(e, kAXChildrenAttribute) as? [AXUIElement]) ?? []
    for a in ["AXExtrasMenuBar", kAXMenuBarAttribute, kAXWindowsAttribute] {
        if let v = get(e, a) {
            if CFGetTypeID(v) == AXUIElementGetTypeID() {
                all.append(unsafeBitCast(v, to: AXUIElement.self))
            } else if let values = v as? [AXUIElement] {
                all.append(contentsOf: values)
            }
        }
    }
    return all
}
func walk(_ root: AXUIElement, _ depth: Int = 0, _ body: (AXUIElement, Int) -> Void) {
    guard depth < 12 else { return }
    body(root, depth)
    for child in children(root) { walk(child, depth + 1, body) }
}
let args = CommandLine.arguments
if args.count > 1 && args[1] == "displays" {
    var ids = [CGDirectDisplayID](repeating: 0, count: 32)
    var n: UInt32 = 0
    let error = CGGetOnlineDisplayList(32, &ids, &n)
    guard error == .success else {
        fputs("enumeration failed\n", stderr)
        exit(1)
    }
    let items = ids.prefix(Int(n)).map { id -> [String: Any] in
        let b = CGDisplayBounds(id)
        return [
            "id": id, "active": CGDisplayIsActive(id) != 0, "main": CGDisplayIsMain(id) != 0,
            "x": b.origin.x, "y": b.origin.y, "width": b.width, "height": b.height,
        ]
    }
    print(String(data: try JSONSerialization.data(withJSONObject: items, options: [.sortedKeys]), encoding: .utf8)!)
    exit(0)
}
if args.count > 2 && args[1] == "key" {
    let key = CGKeyCode(args[2])!
    var flags: CGEventFlags = []
    for m in args.dropFirst(3) {
        if m == "control" { flags.insert(.maskControl) }
        if m == "option" { flags.insert(.maskAlternate) }
        if m == "command" { flags.insert(.maskCommand) }
        if m == "shift" { flags.insert(.maskShift) }
    }
    guard AXIsProcessTrusted() else {
        fputs("Accessibility not available\n", stderr)
        exit(1)
    }
    let src = CGEventSource(stateID: .hidSystemState)!
    let down = CGEvent(keyboardEventSource: src, virtualKey: key, keyDown: true)!
    let up = CGEvent(keyboardEventSource: src, virtualKey: key, keyDown: false)!
    down.flags = flags
    up.flags = flags
    down.post(tap: .cghidEventTap)
    usleep(80000)
    up.post(tap: .cghidEventTap)
    print("key posted")
    exit(0)
}
guard args.count >= 3, let pid = pid_t(args[2]), AXIsProcessTrusted() else {
    fputs(
        "Usage: blackout-qa displays | key KEYCODE [control option command shift] | dump PID | press PID LABEL | set PID IDENTIFIER VALUE\n",
        stderr)
    exit(2)
}
let root = AXUIElementCreateApplication(pid)
AXUIElementSetMessagingTimeout(root, 2)
if args[1] == "dump" {
    var rows = [[String: Any]]()
    walk(root) { e, depth in
        var actions: CFArray?
        AXUIElementCopyActionNames(e, &actions)
        rows.append([
            "depth": depth, "role": text(e, kAXRoleAttribute), "title": text(e, kAXTitleAttribute),
            "description": text(e, kAXDescriptionAttribute), "identifier": text(e, kAXIdentifierAttribute),
            "value": get(e, kAXValueAttribute).map { String(describing: $0) } ?? "",
            "actions": actions as? [String] ?? [],
        ])
    }
    print(
        String(
            data: try JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys]),
            encoding: .utf8)!)
} else if args[1] == "press" || args[1] == "set" {
    guard args.count >= 4 else { exit(2) }
    let target = args[3]
    var match: AXUIElement?
    walk(root) { e, _ in
        if match == nil
            && [text(e, kAXIdentifierAttribute), text(e, kAXTitleAttribute), text(e, kAXDescriptionAttribute)].contains(
                target)
        {
            var actions: CFArray?
            AXUIElementCopyActionNames(e, &actions)
            if args[1] == "set" || ((actions as? [String]) ?? []).contains(kAXPressAction) { match = e }
        }
    }
    guard let e = match else {
        fputs("target not found\n", stderr)
        exit(1)
    }
    var err: AXError
    if args[1] == "set" {
        guard args.count >= 5 else { exit(2) }
        err = AXUIElementSetAttributeValue(e, kAXValueAttribute as CFString, args[4] as CFString)
    } else {
        err = AXUIElementPerformAction(e, kAXPressAction as CFString)
    }
    print("AX result \(err.rawValue)")
    exit(err == .success ? 0 : 1)
} else {
    exit(2)
}
