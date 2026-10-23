import AppKit
import ApplicationServices

func attrVal(_ e: AXUIElement, _ key: String) -> AnyObject? {
    var v: CFTypeRef?
    return AXUIElementCopyAttributeValue(e, key as CFString, &v) == .success
        ? (v as AnyObject?) : nil
}
func aStr(_ e: AXUIElement, _ key: String) -> String {
    (attrVal(e, key) as? String) ?? ""
}
func ptOf(_ e: AXUIElement) -> CGPoint {
    var pt = CGPoint.zero
    if let ref = attrVal(e, kAXPositionAttribute) {
        _ = AXValueGetValue(unsafeBitCast(ref, to: AXValue.self), .cgPoint, &pt)
    }
    return pt
}
func actions(_ e: AXUIElement) -> [String] {
    (attrVal(e, "AXActions") as? [String]) ?? []
}

let argCount = CommandLine.arguments.count
let mode = argCount > 1 ? CommandLine.arguments[1] : "list"
let needle = argCount > 2 ? CommandLine.arguments[2] : ""

guard let app = NSWorkspace.shared.runningApplications
        .first(where: { $0.bundleIdentifier == "com.pxing.mr" }) else {
    FileHandle.standardError.write("MeetingRecorder 未在运行\n".data(using: .utf8)!)
    exit(1)
}
let appEl = AXUIElementCreateApplication(app.processIdentifier)
guard let wins = attrVal(appEl, kAXWindowsAttribute) as? [AXUIElement] else { exit(1) }

let interactive: Set<String> = [
    kAXButtonRole as String, kAXMenuButtonRole as String,
    kAXPopUpButtonRole as String, kAXCheckBoxRole as String,
    kAXTextFieldRole as String, kAXStaticTextRole as String, kAXMenuItemRole as String,
]

func walk(_ e: AXUIElement, _ d: Int, _ maxD: Int, _ out: inout [String]) {
    guard d < maxD else { return }
    let role = aStr(e, kAXRoleAttribute)
    let desc = aStr(e, kAXDescriptionAttribute)
    let tit = aStr(e, kAXTitleAttribute)
    let val = attrVal(e, kAXValueAttribute).map { "\($0)" } ?? ""
    if interactive.contains(role) {
        let label = desc.isEmpty ? (tit.isEmpty ? val : tit) : desc
        if !label.isEmpty {
            let en = (attrVal(e, kAXEnabledAttribute).map { "\($0)" }) ?? "?"
            let p = ptOf(e)
            let acts = actions(e).joined(separator: ",")
            out.append(String(format: "%@[\(label)] role=\(role) en=\(en) acts=[\(acts)] @(\(Int(p.x)),\(Int(p.y)))",
                              String(repeating: "  ", count: d)))
            let help = aStr(e, kAXHelpAttribute)
            if !help.isEmpty && !needle.isEmpty {
                out.append(String(format: "%@    help=%@", String(repeating: "  ", count: d),
                                  help.replacingOccurrences(of: "\n", with: " ⏎ ")))
            }
        }
    }
    if let kids = attrVal(e, kAXChildrenAttribute) as? [AXUIElement] {
        for k in kids { walk(k, d + 1, maxD, &out) }
    }
}

var found: [String] = []
for (i, w) in wins.enumerated() {
    found.append("── win[\(i)] \(aStr(w, kAXTitleAttribute)) subrole=\(aStr(w, kAXSubroleAttribute))")
    walk(w, 1, 10, &found)
}

switch mode {
case "list":
    print(found.joined(separator: "\n"))

case "help":
    let hits = found.filter { $0.contains(needle) }
    print(hits.isEmpty ? "NOT_FOUND \(needle)" : hits.joined(separator: "\n"))

case "press-menu":
    var pressed = false
    func press(_ e: AXUIElement) {
        if pressed { return }
        if aStr(e, kAXRoleAttribute) == (kAXMenuButtonRole as String)
            && aStr(e, kAXTitleAttribute) == needle {
            let r = AXUIElementPerformAction(e, kAXPressAction as CFString)
            print("AXPress(\(needle)) -> \(r.rawValue)")
            pressed = true
            return
        }
        if let kids = attrVal(e, kAXChildrenAttribute) as? [AXUIElement] {
            for k in kids { press(k) }
        }
    }
    for w in wins { press(w) }
    if !pressed { print("MENU_BUTTON_NOT_FOUND \(needle)"); exit(2) }

default:
    FileHandle.standardError.write("未知模式 \(mode)\n".data(using: .utf8)!)
    exit(64)
}
