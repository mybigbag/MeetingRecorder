import ApplicationServices
import Foundation
let pid = pid_t(Int(CommandLine.arguments[1])!)
let apps = AXUIElementCreateApplication(pid)
var windowsRef: CFTypeRef?
guard AXUIElementCopyAttributeValue(apps, kAXWindowsAttribute as CFString, &windowsRef) == .success,
      let windows = windowsRef as? [AXUIElement] else { exit(2) }
func text(_ el: AXUIElement) -> String {
    var t: CFTypeRef?; var v: CFTypeRef?
    _ = AXUIElementCopyAttributeValue(el, kAXTitleAttribute as CFString, &t)
    _ = AXUIElementCopyAttributeValue(el, kAXValueAttribute as CFString, &v)
    return [(t as? String), (v as? String)].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "/")
}
func walk(_ el: AXUIElement, depth: Int) {
    var roleRef: CFTypeRef?
    guard AXUIElementCopyAttributeValue(el, kAXRoleAttribute as CFString, &roleRef) == .success,
          let role = roleRef as? String else { return }
    if role.contains("Button") {
        var enRef: CFTypeRef?
        _ = AXUIElementCopyAttributeValue(el, kAXEnabledAttribute as CFString, &enRef)
        let en = (enRef as? Bool) ?? false
        var descRef: CFTypeRef?
        _ = AXUIElementCopyAttributeValue(el, kAXDescriptionAttribute as CFString, &descRef)
        let desc = (descRef as? String) ?? ""
        // 递归收子节点文字
        var chRef: CFTypeRef?
        var kids: [String] = []
        if AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &chRef) == .success,
           let ch = chRef as? [AXUIElement] {
            for c in ch { let s = text(c); if !s.isEmpty { kids.append(s) } }
        }
        let label = [desc, kids.joined(separator: "+")].filter { !$0.isEmpty }.joined(separator: " | ")
        if !label.isEmpty || !en {
            print("  role=\(role) enabled=\(en) 文案=『\(label)』 depth=\(depth)")
        }
    }
    var chRef: CFTypeRef?
    guard AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &chRef) == .success,
          let ch = chRef as? [AXUIElement] else { return }
    for c in ch { walk(c, depth: depth + 1) }
}
for w in windows { walk(w, depth: 0) }
