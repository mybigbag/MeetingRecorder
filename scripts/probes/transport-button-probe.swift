import ApplicationServices
import Foundation

// 点按钮：先按文案找到目标，再 AXPress。
// 记录按下前后该按钮的 enabled / 文案，用来证明点击是否真的生效。
let pid = pid_t(Int(CommandLine.arguments[1])!)
let targetText = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "两轨同时播放"
let apps = AXUIElementCreateApplication(pid)

var windowsRef: CFTypeRef?
guard AXUIElementCopyAttributeValue(apps, kAXWindowsAttribute as CFString, &windowsRef) == .success,
      let windows = windowsRef as? [AXUIElement] else { print("读窗口失败"); exit(2) }

func label(_ el: AXUIElement) -> String {
    var out: [String] = []
    var dRef: CFTypeRef?
    if AXUIElementCopyAttributeValue(el, kAXDescriptionAttribute as CFString, &dRef) == .success,
       let d = dRef as? String, !d.isEmpty { out.append(d) }
    var chRef: CFTypeRef?
    if AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &chRef) == .success,
       let ch = chRef as? [AXUIElement] {
        for c in ch {
            var t: CFTypeRef?; var v: CFTypeRef?
            _ = AXUIElementCopyAttributeValue(c, kAXTitleAttribute as CFString, &t)
            _ = AXUIElementCopyAttributeValue(c, kAXValueAttribute as CFString, &v)
            for s in [(t as? String), (v as? String)] {
                if let s = s, !s.isEmpty { out.append(s) }
            }
        }
    }
    return out.joined(separator: "|")
}

func find(_ el: AXUIElement, target: String) -> AXUIElement? {
    var roleRef: CFTypeRef?
    guard AXUIElementCopyAttributeValue(el, kAXRoleAttribute as CFString, &roleRef) == .success,
          let role = roleRef as? String else { return nil }
    if role.contains("Button") && label(el).contains(target) { return el }
    var chRef: CFTypeRef?
    guard AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &chRef) == .success,
          let ch = chRef as? [AXUIElement] else { return nil }
    for c in ch { if let f = find(c, target: target) { return f } }
    return nil
}

func enabled(_ el: AXUIElement) -> Bool {
    var r: CFTypeRef?
    _ = AXUIElementCopyAttributeValue(el, kAXEnabledAttribute as CFString, &r)
    return (r as? Bool) ?? false
}

var found: AXUIElement?
for w in windows { if let f = find(w, target: targetText) { found = f; break } }
guard let btn = found else { print("没找到含『\(targetText)』的按钮"); exit(3) }

print("按前: 文案=『\(label(btn))』 enabled=\(enabled(btn))")
var chRef: CFTypeRef?
_ = AXUIElementCopyAttributeValue(btn, kAXChildrenAttribute as CFString, &chRef)
// AXPress 需要元素有 press action
let err = AXUIElementPerformAction(btn, "AXPress" as CFString)
print("AXPress 返回: \(err.rawValue)")
if err != .success {
    // SwiftUI Button 常常没有 AXPress，退回用坐标点击
    var posRef: CFTypeRef?
    let e2 = AXUIElementCopyAttributeValue(btn, kAXPositionAttribute as CFString, &posRef)
    var sizeRef: CFTypeRef?
    let e3 = AXUIElementCopyAttributeValue(btn, kAXSizeAttribute as CFString, &sizeRef)
    print("取坐标: pos err=\(e2.rawValue) size err=\(e3.rawValue)")
    if e2 == .success, e3 == .success,
       let p = posRef as? [String: CGFloat], let s = sizeRef as? [String: CGFloat] {
        let x = (p["X"] ?? 0) + (s["Width"] ?? 0)/2
        let y = (p["Y"] ?? 0) + (s["Height"] ?? 0)/2
        print("按钮中心: (\(Int(x)), \(Int(y)))")
        let src = CGEventSource(stateID: .hidSystemState)
        CGEvent(mouseEventSource: src, mouseType: .mouseMoved, mouseCursorPosition: CGPoint(x: x, y: y), mouseButton: .left)?.post(tap: .cghidEventTap)
        usleep(100_000)
        CGEvent(mouseEventSource: src, mouseType: .leftMouseDown, mouseCursorPosition: CGPoint(x: x, y: y), mouseButton: .left)?.post(tap: .cghidEventTap)
        usleep(60_000)
        CGEvent(mouseEventSource: src, mouseType: .leftMouseUp, mouseCursorPosition: CGPoint(x: x, y: y), mouseButton: .left)?.post(tap: .cghidEventTap)
        print("已发送真实鼠标点击")
    }
}
Thread.sleep(forTimeInterval: 0.6)
var found2: AXUIElement?
for w in windows { if let f = find(w, target: "暂停") ?? nil { found2 = f; break } }
print(found2 != nil ? "按后找到『暂停』按钮 ✓" : "按后**没有**『暂停』按钮 ✗")
