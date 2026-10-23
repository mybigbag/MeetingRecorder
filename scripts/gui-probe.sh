#!/bin/bash
# MeetingRecorder GUI 探针（AX / SwiftUI）
#
# 为什么需要这个：MeetingRecorder 的主界面是 SwiftUI，
# 它在 Accessibility 树上的行为和 AppKit 控件不一样，踩过三个坑：
#
#   1. **控件没有 AXPosition / AXSize。**
#      SwiftUI 渲染出来的按钮在 AX 树上带描述，但位置属性读回来是 (0,0)，
#      所以「按元素点」这条路对普通 Button 是死的。
#      → 拿坐标只能靠 CGWindowList 给窗口矩形 + 截图量像素，本脚本不做这件事，
#        只负责把「有哪些控件、叫什么、是什么角色」列清楚。
#
#   2. **普通 Button 的 AXActions 是空的。**
#      `AXPress` 对 AXButton 返回 -25204 (kAXErrorCannotPerformAction)。
#      但 AXMenuButton 有 AXPress，按它能真的弹出菜单（本脚本 --press-menu 会试）。
#      → 想点普通按钮，只能用真实鼠标点击 `click at`，且**必须先把目标 app 置前**，
#        否则 `click at` 会落到当时前台的别的 app 上（实测点进了企业微信）。
#
#   3. **`entire contents` 会把探针拖到分钟级。**
#      整树遍历一个 SwiftUI 窗口 >2 分钟。别用。
#      → 本脚本限深（默认 10 层）并且只挑关心的角色。
#
# 用法：
#   ./gui-probe.shlist                # 列出所有窗口里可交互的控件 + 坐标
#   ./gui-probe.sh status             # 状态栏菜单的全部菜单项（含勾选标记）
#   ./gui-probe.sh help "单轨转写"      # 查某个控件的 role / enabled / help
#   ./gui-probe.sh press-menu "单轨转写"  # AXPress 一个菜单按钮（仅 AXMenuButton 可行）
#
# 前置：系统设置 → 隐私与安全性 → 辅助功能 勾选「WorkBuddy」。
# 注意 TCC **不追溯**：授权之后必须重启 WorkBuddy 进程，
# 否则旧进程仍然会报 -10004。这是最容易被误判成「权限没生效」的原因。

set -euo pipefail

BUNDLE_ID="com.pxing.mr"
BIN="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/.gui-probe-bin"
mkdir -p "$BIN"

# ---------------------------------------------------------------- Swift 探针
# 单独一个文件：swiftc 编译一次约1~2 秒，比每次走 osascript 遍历快一个量级，
# 也不会像 AppleScript 那样在AX 树偶发重排时抛「无效的索引」。
cat > "$BIN/probe.swift" <<'SWIFT'
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
SWIFT

swiftc -O "$BIN/probe.swift" -o "$BIN/probe" 2>/dev/null

case "${1:-list}" in
    list)       "$BIN/probe" list ;;
    help)       "$BIN/probe" help "${2:?用法: gui-probe.sh help <控件名>}" ;;
    press-menu) "$BIN/probe" press-menu "${2:?用法: gui-probe.sh press-menu <菜单名>}" ;;
    *) echo "用法: $0 {list|help <名字>|press-menu <名字>}" >&2; exit 64 ;;
esac